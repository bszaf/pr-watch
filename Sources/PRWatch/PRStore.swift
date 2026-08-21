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

    func start() {
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
        var interval = adaptiveInterval(anyPending: anyPending, recentlyChanged: recentlyChanged, idle: settings.pollInterval)
        // Back off until the GitHub rate limit resets rather than hammering the exhausted quota.
        if let until = rateLimitedUntil, until > Date() {
            interval = max(interval, until.timeIntervalSinceNow + 30)
        }
        nextPollDate = Date().addingTimeInterval(interval)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    private struct Loaded { let prs: [PullRequest]; let status: ProviderStatus }

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
        for provider in Provider.allCases {
            if let loaded = results[provider] ?? nil {
                statuses[provider] = loaded.status
                merged += loaded.prs
                if let user = loaded.status.user, !user.isEmpty { viewerLogins[provider] = user }
                if let err = loaded.status.error { errors.append("\(provider.label): \(err)") }
            } else {
                // Disabled — keep last known identity for the status line.
                statuses[provider] = ProviderStatus(
                    enabled: false, source: providerStatus[provider]?.source ?? .none,
                    user: viewerLogins[provider], error: nil)
            }
        }

        providerStatus = statuses
        UserDefaults.standard.set(try? JSONEncoder().encode(viewerLogins), forKey: viewersKey)
        lastUpdated = Date()
        lastError = merged.isEmpty && !errors.isEmpty ? errors.joined(separator: "\n") : nil

        diffAndNotify(merged)
        pullRequests = merged.sorted {
            $0.repo == $1.repo ? $0.number > $1.number : $0.repo < $1.repo
        }
    }

    /// Fetch one provider, translating success/failure into a `Loaded` (never throws).
    private func load(_ provider: Provider) async -> Loaded {
        do {
            let result: ProviderResult
            switch provider {
            case .github:
                result = try await GitHubClient(
                    authored: settings.watchAuthored, reviewRequested: settings.watchReviewRequested,
                    mentioned: settings.watchMentions,
                    repoFilters: settings.repoFilters, customPRs: settings.customPRs).fetch()
            case .gitlab:
                result = try await GitLabClient(
                    authored: settings.watchAuthored, reviewRequested: settings.watchReviewRequested,
                    repoFilters: settings.repoFilters, host: settings.gitlabHost).fetch()
            }
            lastPRs[provider] = result.prs
            // Proactive backoff: pause before the quota hits zero.
            if provider == .github {
                if let rem = result.rateLimitRemaining, rem < 100, let reset = result.rateLimitResetAt {
                    rateLimitedUntil = reset
                } else {
                    rateLimitedUntil = nil
                }
            }
            return Loaded(prs: result.prs, status: ProviderStatus(
                enabled: true, source: result.source, user: result.viewerLogin, error: nil))
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
        pullRequests = DemoData.pullRequests.sorted {
            $0.repo == $1.repo ? $0.number > $1.number : $0.repo < $1.repo
        }
    }

    func clearActivity() {
        activity = []
        saveActivity()
    }

    private func diffAndNotify(_ prs: [PullRequest]) {
        let triggers = Triggers(ci: settings.notifyCI, review: settings.notifyReview,
                                conflicts: settings.notifyConflicts, comments: settings.notifyComments)
        if didInitialFetch {
            var events: [ActivityEvent] = []
            for pr in prs {
                for kind in transitions(for: pr, previous: snapshot[pr.id]) {
                    // Use the PR's real update time (approx) so events caught after
                    // downtime show when they happened, not "now".
                    events.append(ActivityEvent(
                        date: eventDate(for: pr), prId: pr.id, repo: pr.repo,
                        number: pr.number, ref: pr.ref, title: pr.title, url: pr.url, kind: kind))
                    if isEnabled(kind, triggers) {
                        let n = notification(for: kind, pr: pr)
                        Notifier.notify(title: n.title, body: n.body, url: pr.url)
                    }
                }
            }
            if !events.isEmpty {
                activity.append(contentsOf: events)
                activity.sort { $0.date > $1.date }   // newest first, by real event time
                if activity.count > maxActivity { activity = Array(activity.prefix(maxActivity)) }
                lastChangeAt = Date()   // keep polling fast for a bit after any change
            }
        }
        saveActivity()
        snapshot = Dictionary(uniqueKeysWithValues: prs.map { pr in
            let mergeable = resolvedMergeable(pr.mergeable, previous: snapshot[pr.id]?.mergeable)
            return (pr.id, SnapshotState(ciState: pr.ciState, reviewDecision: pr.reviewDecision,
                                         mergeable: mergeable, awaitingReply: pr.awaitingMyReply))
        })
        UserDefaults.standard.set(try? JSONEncoder().encode(snapshot), forKey: snapshotKey)
        didInitialFetch = true
    }

    private func saveActivity() {
        ActivityStore.save(activity)
    }

    /// Best-effort real timestamp for an event, from the PR's ISO8601 updatedAt.
    private func eventDate(for pr: PullRequest) -> Date {
        pr.updatedAt.flatMap(Self.parseISO) ?? Date()
    }

    private static let iso = ISO8601DateFormatter()
    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static func parseISO(_ s: String) -> Date? {
        iso.date(from: s) ?? isoFractional.date(from: s)
    }

    private static func decode<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
