import Foundation
import Observation

/// Owns the PR list, the polling timer, the diff→notify pipeline, and the activity feed.
@MainActor
@Observable
final class PRStore {
    private(set) var pullRequests: [PullRequest] = []
    private(set) var activity: [ActivityEvent] = []
    private(set) var viewerLogin = ""
    private(set) var lastError: String?
    private(set) var lastUpdated: Date?
    private(set) var nextPollDate: Date?
    private(set) var isRefreshing = false

    let settings: AppSettings

    private var timer: Timer?
    private var snapshot: [String: SnapshotState] = [:]
    private var didInitialFetch = false
    private let snapshotKey = "prSnapshot"
    private let maxActivity = 200

    init(settings: AppSettings) {
        self.settings = settings
        snapshot = Self.decode([String: SnapshotState].self, key: snapshotKey) ?? [:]
        activity = ActivityStore.load()
        viewerLogin = UserDefaults.standard.string(forKey: "viewerLogin") ?? ""
        didInitialFetch = !snapshot.isEmpty   // a persisted snapshot means we can notify immediately
    }

    /// A PR I authored (vs. one I'm only reviewing / watching).
    func isMine(_ pr: PullRequest) -> Bool {
        !viewerLogin.isEmpty && pr.author == viewerLogin
    }

    func start() {
        Task { await refresh() }   // refresh() arms the next poll
    }

    /// Re-arm the timer using the current poll interval (call after Settings changes).
    func restartTimer() { scheduleNextPoll() }

    private func scheduleNextPoll() {
        timer?.invalidate()
        let interval = TimeInterval(max(15, settings.pollInterval))
        nextPollDate = Date().addingTimeInterval(interval)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer {
            isRefreshing = false
            scheduleNextPoll()
        }

        let client = GitHubClient(
            authored: settings.watchAuthored,
            reviewRequested: settings.watchReviewRequested,
            repoFilter: settings.repoFilter,
            customPRs: settings.customPRs
        )
        do {
            let result = try await client.fetch()
            lastError = nil
            lastUpdated = Date()
            if let login = result.viewerLogin, !login.isEmpty {
                viewerLogin = login
                UserDefaults.standard.set(login, forKey: "viewerLogin")
            }
            diffAndNotify(result.prs)
            pullRequests = result.prs.sorted { $0.repo == $1.repo ? $0.number > $1.number : $0.repo < $1.repo }
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
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
                        number: pr.number, title: pr.title, url: pr.url, kind: kind
                    ))
                    if isEnabled(kind, triggers) {
                        let n = notification(for: kind, pr: pr)
                        Notifier.notify(title: n.title, body: n.body, url: pr.url)
                    }
                }
            }
            if !events.isEmpty {
                activity.insert(contentsOf: events.reversed(), at: 0)   // newest first
                if activity.count > maxActivity { activity = Array(activity.prefix(maxActivity)) }
            }
        }
        saveActivity()   // keep the on-disk log current (and present) every refresh
        snapshot = Dictionary(uniqueKeysWithValues: prs.map { ($0.id, SnapshotState($0)) })
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
