import Foundation
import Observation

/// Adaptive poll cadence: poll fast (`fast`) while something is likely to change soon —
/// a CI run is in flight or a change was seen recently — otherwise fall back to the
/// user's configured `idle` interval. Pure for testability.
func adaptiveInterval(anyPending: Bool, recentlyChanged: Bool, idle: Int, fast: Int = 15) -> TimeInterval {
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

    let settings: AppSettings

    private var timer: Timer?
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

    /// A PR I authored (vs. one I'm only reviewing / watching) — matched per provider.
    func isMine(_ pr: PullRequest) -> Bool {
        guard let me = viewerLogins[pr.provider], !me.isEmpty else { return false }
        return pr.author == me
    }

    func start() {
        Task { await refresh() }
    }

    func restartTimer() { scheduleNextPoll() }

    private func scheduleNextPoll() {
        timer?.invalidate()
        let anyPending = pullRequests.contains { $0.ciState == .pending || $0.ciState == .expected }
        let recentlyChanged = lastChangeAt.map { Date().timeIntervalSince($0) < recentChangeWindow } ?? false
        let interval = adaptiveInterval(anyPending: anyPending, recentlyChanged: recentlyChanged, idle: settings.pollInterval)
        nextPollDate = Date().addingTimeInterval(interval)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    private struct Loaded { let prs: [PullRequest]; let status: ProviderStatus }

    func refresh() async {
        guard !isRefreshing else { return }
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
                    repoFilters: settings.repoFilters, customPRs: settings.customPRs).fetch()
            case .gitlab:
                result = try await GitLabClient(
                    authored: settings.watchAuthored, reviewRequested: settings.watchReviewRequested,
                    repoFilters: settings.repoFilters, host: settings.gitlabHost).fetch()
            }
            return Loaded(prs: result.prs, status: ProviderStatus(
                enabled: true, source: result.source, user: result.viewerLogin, error: nil))
        } catch {
            let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            // Preserve last-known source/user so the status line stays informative.
            var status = providerStatus[provider] ?? ProviderStatus(enabled: true, source: .none, user: nil, error: nil)
            status.enabled = true
            status.user = viewerLogins[provider]
            status.error = msg
            return Loaded(prs: [], status: status)
        }
    }

    func clearActivity() {
        activity = []
        saveActivity()
    }

    private func diffAndNotify(_ prs: [PullRequest]) {
        let triggers = Triggers(ci: settings.notifyCI, review: settings.notifyReview, conflicts: settings.notifyConflicts)
        if didInitialFetch {
            var events: [ActivityEvent] = []
            for pr in prs {
                for kind in transitions(for: pr, previous: snapshot[pr.id]) {
                    events.append(ActivityEvent(
                        date: Date(), prId: pr.id, repo: pr.repo,
                        number: pr.number, ref: pr.ref, title: pr.title, url: pr.url, kind: kind))
                    if isEnabled(kind, triggers) {
                        let n = notification(for: kind, pr: pr)
                        Notifier.notify(title: n.title, body: n.body, url: pr.url)
                    }
                }
            }
            if !events.isEmpty {
                activity.insert(contentsOf: events.reversed(), at: 0)
                if activity.count > maxActivity { activity = Array(activity.prefix(maxActivity)) }
                lastChangeAt = Date()   // keep polling fast for a bit after any change
            }
        }
        saveActivity()
        snapshot = Dictionary(uniqueKeysWithValues: prs.map { pr in
            let mergeable = resolvedMergeable(pr.mergeable, previous: snapshot[pr.id]?.mergeable)
            return (pr.id, SnapshotState(ciState: pr.ciState, reviewDecision: pr.reviewDecision, mergeable: mergeable))
        })
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
