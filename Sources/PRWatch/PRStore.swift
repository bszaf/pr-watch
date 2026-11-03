import Foundation
import Observation
import AppKit

/// Adaptive poll cadence: poll fast (`fast`) while something is likely to change soon —
/// a CI run is in flight or a change was seen recently — otherwise fall back to the
/// user's configured `idle` interval. Pure for testability.
func adaptiveInterval(anyPending: Bool, recentlyChanged: Bool, idle: Int, fast: Int = 30) -> TimeInterval {
    (anyPending || recentlyChanged) ? TimeInterval(fast) : TimeInterval(max(fast, idle))
}

/// Owns the merged PR list (across providers), the polling timer, the diff→notify
/// pipeline, per-provider auth status, and the activity feed.
@MainActor
@Observable
final class PRStore {
    private(set) var pullRequests: [PullRequest] = []
    private(set) var activity: [ActivityEvent] = []
    private(set) var viewerLogins: [Provider: String] = [:]
    private(set) var providerStatus: [Provider: ProviderStatus] = [:]
    private(set) var lastError: String?
    private(set) var lastUpdated: Date?
    private(set) var nextPollDate: Date?
    private(set) var isRefreshing = false
    private(set) var rateLimitedUntil: Date?   // GitHub rate limit; next poll waits until this

    let settings: AppSettings

    private var timer: Timer?
    private var lastPRs: [Provider: [PullRequest]] = [:]   // keep last good results per provider
    private var githubThreadCache: [String: CachedReview] = [:]   // per-PR review cache; only re-fetched when a PR changes
    private var githubChecksCache: [String: CachedChecks] = [:]
    private var reported: [PullRequest] = []   // as fetched, before ignored checks are applied
    private var snapshot: [String: SnapshotState] = [:]
    private var lastChangeAt: Date?
    private let recentChangeWindow: TimeInterval = 120
    private var didInitialFetch = false
    private let snapshotKey = "prSnapshot"
    private let viewersKey = "viewerLogins"
    private let maxActivity = 200

    init(settings: AppSettings) {
        self.settings = settings
        snapshot = Self.decode([String: SnapshotState].self, key: snapshotKey) ?? [:]
        activity = ActivityStore.load()
        viewerLogins = Self.decode([Provider: String].self, key: viewersKey) ?? [:]
        didInitialFetch = !snapshot.isEmpty
    }

    /// A PR I authored (vs. one I'm only reviewing / watching).
    func isMine(_ pr: PullRequest) -> Bool { pr.isMine }

    private var started = false

    func start() {
        // Idempotent — the window's `.task` re-runs on every reopen; don't stack observers.
        guard !started else { return }
        started = true
        // Catch up immediately on wake — timers don't fire while the machine sleeps.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        Task { await refresh() }
    }

    func restartTimer() { scheduleNextPoll() }

    private func scheduleNextPoll() {
        timer?.invalidate()
        let anyPending = pullRequests.contains { $0.ciState == .pending || $0.ciState == .expected }
        let recentlyChanged = lastChangeAt.map { Date().timeIntervalSince($0) < recentChangeWindow } ?? false
        // A GitHub rate limit doesn't slow the timer — `load(.github)` skips the fetch
        // (reusing last results) until the reset, so GitLab keeps polling normally.
        let interval = adaptiveInterval(anyPending: anyPending, recentlyChanged: recentlyChanged, idle: settings.pollInterval)
        nextPollDate = Date().addingTimeInterval(interval)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    private struct Loaded {
        let prs: [PullRequest]
        let status: ProviderStatus
        var closed: [ClosedPR] = []
        var unresolvedVanished: Set<String> = []
    }

    func refresh() async {
        guard !isRefreshing else { return }
        if settings.demoMode { loadDemo(); return }
        isRefreshing = true
        defer {
            isRefreshing = false
            scheduleNextPoll()
        }

        // Fetch enabled providers concurrently.
        async let gh: Loaded? = settings.watchGitHub ? load(.github) : nil
        async let gl: Loaded? = settings.watchGitLab ? load(.gitlab) : nil
        let results: [Provider: Loaded?] = [.github: await gh, .gitlab: await gl]

        var merged: [PullRequest] = []
        var statuses: [Provider: ProviderStatus] = [:]
        var errors: [String] = []
        var failed: Set<Provider> = []
        var closed: [ClosedPR] = []
        var retained: Set<String> = []
        for provider in Provider.allCases {
            if let loaded = results[provider] ?? nil {
                statuses[provider] = loaded.status
                merged += loaded.prs
                closed += loaded.closed
                retained.formUnion(loaded.unresolvedVanished)
                if let user = loaded.status.user, !user.isEmpty { viewerLogins[provider] = user }
                if let err = loaded.status.error {
                    errors.append("\(provider.label): \(err)")
                    failed.insert(provider)
                }
            } else {
                // Disabled — keep last known identity for the status line.
                statuses[provider] = ProviderStatus(
                    enabled: false, source: providerStatus[provider]?.source ?? .none,
                    user: viewerLogins[provider], error: nil)
                if provider == .github { rateLimitedUntil = nil }
            }
        }

        providerStatus = statuses
        UserDefaults.standard.set(try? JSONEncoder().encode(viewerLogins), forKey: viewersKey)
        lastUpdated = Date()
        lastError = merged.isEmpty && !errors.isEmpty ? errors.joined(separator: "\n") : nil

        reported = merged
        let applied = applyingIgnoredChecks(merged)
        diffAndNotify(applied, closed: closed, failed: failed, retaining: retained)
        pullRequests = applied
    }

    private func applyingIgnoredChecks(_ prs: [PullRequest]) -> [PullRequest] {
        prs.map { pr in
            let demo = settings.demoMode ? DemoData.ignoredChecks[pr.repo] ?? [] : []
            return pr.applyingIgnoredChecks(settings.ignoredChecks(in: pr.repo).union(demo))
        }
            .sorted { $0.repo == $1.repo ? $0.number > $1.number : $0.repo < $1.repo }
    }

    /// Ignore (or stop ignoring) check `name` in `repo`, taking effect immediately. The snapshot
    /// takes the new CI state silently: a settings change isn't a CI event to notify about.
    func setCheck(_ name: String, ignored: Bool, in repo: String) {
        settings.setCheck(name, ignored: ignored, in: repo)
        pullRequests = applyingIgnoredChecks(settings.demoMode ? DemoData.pullRequests : reported)
        snapshot = adoptingCIStates(pullRequests, into: snapshot)
        UserDefaults.standard.set(try? JSONEncoder().encode(snapshot), forKey: snapshotKey)
    }

    /// Fetch one provider, translating success/failure into a `Loaded` (never throws).
    private func load(_ provider: Provider) async -> Loaded {
        // While rate-limited, skip GitHub entirely (reuse last results) — polling an
        // exhausted quota just burns the reset window. GitLab is unaffected.
        if provider == .github, let until = rateLimitedUntil, until > Date() {
            var status = providerStatus[.github]
                ?? ProviderStatus(enabled: true, source: .none, user: viewerLogins[.github], error: nil)
            status.enabled = true
            status.error = GitHubError.rateLimited(until).errorDescription
            return Loaded(prs: lastPRs[.github] ?? [], status: status)
        }
        do {
            let result: ProviderResult
            switch provider {
            case .github:
                result = try await GitHubClient(
                    authored: settings.watchAuthored, reviewRequested: settings.watchReviewRequested,
                    mentioned: settings.watchMentions,
                    repoFilters: settings.repoFilters, customPRs: settings.customPRs)
                    .fetch(cache: githubThreadCache, checksCache: githubChecksCache, known: Set(snapshot.keys.filter { $0.hasPrefix("github:") }))
            case .gitlab:
                result = try await GitLabClient(
                    authored: settings.watchAuthored, reviewRequested: settings.watchReviewRequested,
                    repoFilters: settings.repoFilters, host: settings.gitlabHost).fetch()
            }
            lastPRs[provider] = result.prs
            // Proactive backoff: pause before the quota hits zero.
            if provider == .github {
                if let tc = result.threadCache { githubThreadCache = tc }
                if let cc = result.checksCache { githubChecksCache = cc }
                if let rem = result.rateLimitRemaining, rem < 100, let reset = result.rateLimitResetAt {
                    rateLimitedUntil = reset
                } else {
                    rateLimitedUntil = nil
                }
            }
            return Loaded(prs: result.prs, status: ProviderStatus(
                enabled: true, source: result.source, user: result.viewerLogin, error: nil),
                closed: result.closed, unresolvedVanished: result.unresolvedVanished)
        } catch {
            if case let GitHubError.rateLimited(reset) = error {
                rateLimitedUntil = reset ?? Date().addingTimeInterval(600)
            }
            let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            // Preserve last-known source/user AND last results, so a transient failure
            // (rate limit, network) doesn't blank the list.
            var status = providerStatus[provider] ?? ProviderStatus(enabled: true, source: .none, user: nil, error: nil)
            status.enabled = true
            status.user = viewerLogins[provider]
            status.error = msg
            return Loaded(prs: lastPRs[provider] ?? [], status: status)
        }
    }

    /// Populate the stores from `DemoData` — no network, no diff, no notifications.
    /// Stops polling; turning demo mode off and refreshing restores real fetching.
    private func loadDemo() {
        timer?.invalidate()
        nextPollDate = nil
        isRefreshing = false
        viewerLogins = DemoData.viewerLogins
        providerStatus = DemoData.providerStatus
        activity = DemoData.activity
        lastError = nil
        lastUpdated = Date()
        pullRequests = applyingIgnoredChecks(DemoData.pullRequests)
    }

    func clearActivity() {
        activity = []
        saveActivity()
    }

    private func diffAndNotify(_ prs: [PullRequest], closed: [ClosedPR], failed: Set<Provider>,
                               retaining retained: Set<String>) {
        let triggers = Triggers(ci: settings.notifyCI, review: settings.notifyReview,
                                conflicts: settings.notifyConflicts, comments: settings.notifyComments,
                                merged: settings.notifyMerged)
        if didInitialFetch {
            var events: [ActivityEvent] = []
            for pr in prs {
                for kind in transitions(for: pr, previous: snapshot[pr.id]) {
                    events.append(ActivityEvent(
                        date: eventDate(for: kind, updatedAt: pr.updatedAt, now: Date()), prId: pr.id, repo: pr.repo,
                        number: pr.number, ref: pr.ref, title: pr.title, url: pr.url, kind: kind,
                        mine: pr.isMine))
                    if isEnabled(kind, triggers) {
                        let n = notification(for: kind, pr: pr)
                        Notifier.notify(title: n.title, body: n.body, url: pr.url)
                    }
                }
            }
            for c in closed {
                let kind: ActivityKind = c.merged ? .merged : .closed
                let mine = !c.author.isEmpty && c.author == viewerLogins[.github]
                events.append(ActivityEvent(
                    date: c.date, prId: c.id, repo: c.repo, number: c.number, ref: "#\(c.number)",
                    title: c.title, url: c.url, kind: kind, mine: mine))
                if mine && isEnabled(kind, triggers) {
                    let n = closedNotification(c)
                    Notifier.notify(title: n.title, body: n.body, url: c.url)
                }
            }
            if !events.isEmpty {
                activity.append(contentsOf: events)
                activity.sort { $0.date > $1.date }   // newest first, by real event time
                if activity.count > maxActivity { activity = Array(activity.prefix(maxActivity)) }
                lastChangeAt = Date()   // keep polling fast for a bit after any change
                saveActivity()          // only rewrite the file when something was added
            }
        }
        snapshot = nextSnapshot(prs, previous: snapshot, keeping: failed, retaining: retained)
        UserDefaults.standard.set(try? JSONEncoder().encode(snapshot), forKey: snapshotKey)
        didInitialFetch = true
    }

    private func saveActivity() {
        ActivityStore.save(activity)
    }

    private static func decode<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
