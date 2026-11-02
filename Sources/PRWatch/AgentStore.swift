import Foundation
import Observation

/// Live Claude Code sessions, read (never written) from their transcripts under
/// `~/.claude/projects`. Re-scanned every few seconds; only appended bytes are parsed.
@MainActor
@Observable
final class AgentStore {
    private(set) var sessions: [AgentSession] = []
    let settings: AppSettings

    private var files: [String: TranscriptFile] = [:]
    private var repoByCwd: [String: String?] = [:]
    private var timer: Timer?
    private var isScanning = false
    private var didInitialScan = false
    private let root: String

    init(settings: AppSettings, root: String = TranscriptScanner.defaultRoot) {
        self.settings = settings
        self.root = root
    }

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.scan() }
        }
        Task { await scan() }
    }

    /// The most pressing session working on `pr`, if any.
    func session(for pr: PullRequest) -> AgentSession? {
        sessions.first { $0.works(on: pr) }
    }

    func scan() async {
        if settings.demoMode { sessions = DemoData.agentSessions; return }
        guard settings.watchAgents else {
            sessions = []; files = [:]; didInitialScan = false
            return
        }
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }

        let (root, cache, knownRepos) = (self.root, files, repoByCwd)
        let now = Date()
        let (scanned, repos, procs) = await runBlocking { () -> ([String: TranscriptFile], [String: String?], [ClaudeProcesses.Proc]) in
            let scanned = TranscriptScanner.scan(root: root, cache: cache, now: now)
            let procs = ClaudeProcesses.running()
            var repos = knownRepos
            for cwd in Set(scanned.values.compactMap(\.summary.cwd)) where repos[cwd] == nil {
                repos[cwd] = .some(TranscriptScanner.repo(at: cwd))
            }
            return (scanned, repos, procs)
        }
        files = scanned
        repoByCwd = repos

        let next = scanned.compactMap { path, file -> AgentSession? in
            let s = file.summary
            guard let cwd = s.cwd, s.phase != nil else { return nil }   // never had a turn
            return AgentSession(
                id: s.sessionId ?? path, title: s.title, lastPrompt: s.lastPrompt, cwd: cwd,
                branch: s.branch, repo: repos[cwd] ?? nil, prLinks: s.prLinks,
                lastActivity: file.modified,
                state: agentState(phase: s.phase, quietFor: now.timeIntervalSince(file.modified),
                                  bypassPermissions: s.bypassPermissions),
                tty: ClaudeProcesses.tty(for: cwd, in: procs))
        }
        .filter { $0.matches(repoFilters: settings.repoFilters) }
        .sorted { ($0.state, $1.lastActivity) < ($1.state, $0.lastActivity) }

        if didInitialScan && settings.notifyAgents {
            let previous = Dictionary(sessions.map { ($0.id, $0.state) }, uniquingKeysWith: { a, _ in a })
            for s in next {
                if let n = agentNotification(from: previous[s.id], to: s.state, session: s) {
                    Notifier.notify(title: n.title, body: n.body)
                }
            }
        }
        sessions = next
        didInitialScan = true
    }
}
