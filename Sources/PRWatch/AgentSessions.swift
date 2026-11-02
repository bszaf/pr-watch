import Foundation

/// What a Claude Code session is doing, inferred from its transcript.
enum AgentState: Int, Comparable, Sendable, CaseIterable {
    // Raw values order the Agents list: what needs you first.
    case waiting, idle, working, inactive

    static func < (l: AgentState, r: AgentState) -> Bool { l.rawValue < r.rawValue }

    var label: String {
        switch self {
        case .waiting: "May need you"
        case .idle: "Finished"
        case .working: "Working"
        case .inactive: "Inactive"
        }
    }

    var symbol: String {
        switch self {
        case .waiting: "hand.raised.fill"
        case .idle: "checkmark.circle.fill"
        case .working: "gearshape.2.fill"
        case .inactive: "moon.zzz.fill"
        }
    }

    var help: String {
        switch self {
        case .waiting: "No output for a while after a tool call — usually a permission prompt, sometimes a long-running command."
        case .idle: "The agent finished its turn — your move."
        case .working: "The agent is running."
        case .inactive: "No activity for a long time mid-turn — the session was probably closed or killed."
        }
    }
}

/// Where the current turn stands, from the last phase-relevant transcript entry.
enum TurnPhase: Sendable, Equatable {
    case awaitingModel   // a prompt / tool result was sent; the model is thinking
    case toolRunning     // the model asked for a tool and no result came back yet
    case turnEnded       // the model finished, or the user interrupted
}

struct PRLink: Sendable, Equatable, Hashable {
    let repo: String
    let number: Int
    let url: String
}

/// Everything PR Watch extracts from one transcript, accumulated line by line so a growing
/// file can be read incrementally.
struct TranscriptSummary: Sendable, Equatable {
    var sessionId: String?
    var title: String?
    var lastPrompt: String?
    var cwd: String?
    var branch: String?
    var prLinks: [PRLink] = []
    var phase: TurnPhase?
    var bypassPermissions = false

    mutating func ingest(_ line: Data) {
        guard let e = try? JSONDecoder().decode(TranscriptLine.self, from: line) else { return }
        if let id = e.sessionId { sessionId = id }
        if let c = e.cwd { cwd = c }
        if let b = e.gitBranch { branch = b.isEmpty || b == "HEAD" ? nil : b }   // HEAD = detached
        switch e.type {
        case "ai-title": title = e.aiTitle ?? title
        case "last-prompt": lastPrompt = e.lastPrompt ?? lastPrompt
        case "permission-mode": bypassPermissions = e.permissionMode == "bypassPermissions"
        case "pr-link":
            if let repo = e.prRepository, let n = e.prNumber, let url = e.prUrl {
                let link = PRLink(repo: repo, number: n, url: url)
                if !prLinks.contains(link) { prLinks.append(link) }
            }
        default: break
        }
        // Subagent and meta entries don't move the main conversation's turn.
        guard e.isSidechain != true, e.isMeta != true else { return }
        switch e.type {
        case "system" where e.subtype == "turn_duration":
            phase = .turnEnded
        case "assistant":
            switch e.message?.stopReason {
            case "tool_use": phase = .toolRunning
            case nil: break
            default: phase = .turnEnded
            }
        case "user":
            let text = e.message?.text ?? ""
            if text.hasPrefix("[Request interrupted by user") {
                phase = .turnEnded
            } else if !(text.hasPrefix("<local-command-") || text.hasPrefix("<command-name>")) {
                // Local slash commands (/model, /effort) never reach the model.
                phase = .awaitingModel
            }
        default: break
        }
    }
}

private struct TranscriptLine: Decodable {
    let type: String?
    let subtype: String?
    let sessionId: String?
    let cwd: String?
    let gitBranch: String?
    let isSidechain: Bool?
    let isMeta: Bool?
    let aiTitle: String?
    let lastPrompt: String?
    let permissionMode: String?
    let prRepository: String?
    let prNumber: Int?
    let prUrl: String?
    let message: Message?

    struct Message: Decodable {
        let stopReason: String?
        let text: String?

        enum CodingKeys: String, CodingKey { case stop_reason, content }
        private struct Block: Decodable { let type: String?; let text: String? }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            stopReason = try c.decodeIfPresent(String.self, forKey: .stop_reason)
            if let s = try? c.decode(String.self, forKey: .content) {
                text = s
            } else if let blocks = try? c.decode([Block].self, forKey: .content) {
                text = blocks.first { $0.type == "text" }?.text
            } else {
                text = nil
            }
        }
    }
}

/// Map a turn phase and the time since the transcript last grew to a state.
func agentState(phase: TurnPhase?, quietFor quiet: TimeInterval, bypassPermissions: Bool) -> AgentState {
    let stale: TimeInterval = 30 * 60
    switch phase {
    case .turnEnded: return .idle
    case .toolRunning:
        if quiet > stale { return .inactive }
        // Tool calls normally log their result within seconds; silence means a prompt.
        return quiet < 15 || bypassPermissions ? .working : .waiting
    case .awaitingModel:
        return quiet > 5 * 60 ? .inactive : .working
    case nil:
        return .inactive
    }
}

struct AgentSession: Identifiable, Sendable, Equatable {
    let id: String
    let title: String?
    let lastPrompt: String?
    let cwd: String
    let branch: String?
    let repo: String?        // owner/repo of the cwd's origin remote
    let prLinks: [PRLink]
    let lastActivity: Date
    let state: AgentState
    var tty: String? = nil   // terminal of a running `claude` process in this cwd

    var folder: String { (cwd as NSString).lastPathComponent }
    var terminalHelp: String {
        tty == nil ? "Open a terminal in \(cwd)" : "Switch to the terminal running this session (\(tty!))"
    }
    var displayTitle: String { title ?? lastPrompt ?? folder }

    /// Whether this session belongs to one of `filters` (owner/repo, case-insensitive) via its
    /// cwd's repo or a linked PR. No filters = everything; a session outside any repo never matches.
    func matches(repoFilters filters: [String]) -> Bool {
        let wanted = Set(filters.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty })
        guard !wanted.isEmpty else { return true }
        return ([repo].compactMap { $0 } + prLinks.map(\.repo)).contains { wanted.contains($0.lowercased()) }
    }

    /// Whether this session works on `pr`: the session opened/linked it, or it sits on the
    /// PR's head branch in the same repo.
    func works(on pr: PullRequest) -> Bool {
        if prLinks.contains(where: { $0.repo == pr.repo && $0.number == pr.number && pr.provider == .github }) {
            return true
        }
        guard let branch, let repo else { return false }
        return repo == pr.repo && branch == pr.headBranch
    }
}

/// Banner for a state change seen live; nil when the change isn't worth interrupting for.
func agentNotification(from old: AgentState?, to new: AgentState, session: AgentSession) -> PendingNotification? {
    let body = [session.folder, session.branch].compactMap { $0 }.joined(separator: " · ")
    switch (old, new) {
    case (.working, .waiting):
        return PendingNotification(title: "✋ Agent may need you — \(session.displayTitle)", body: body)
    case (.working, .idle), (.waiting, .idle):
        return PendingNotification(title: "✅ Agent finished — \(session.displayTitle)", body: body)
    default:
        return nil
    }
}

// MARK: - Scanning ~/.claude/projects

/// Per-transcript read state: how far the file was consumed and what it said so far.
struct TranscriptFile: Sendable {
    var offset: UInt64 = 0
    var modified: Date = .distantPast
    var summary = TranscriptSummary()
}

enum TranscriptScanner {
    static var defaultRoot: String { NSHomeDirectory() + "/.claude/projects" }

    /// Transcripts untouched for this long aren't listed.
    static let window: TimeInterval = 24 * 3600

    /// Re-read only what each recently-modified top-level transcript appended since `cache`.
    /// Subagent transcripts live in nested directories and are skipped.
    static func scan(root: String, cache: [String: TranscriptFile], now: Date) -> [String: TranscriptFile] {
        let fm = FileManager.default
        var out: [String: TranscriptFile] = [:]
        for dir in (try? fm.contentsOfDirectory(atPath: root)) ?? [] {
            let dirPath = root + "/" + dir
            for name in (try? fm.contentsOfDirectory(atPath: dirPath)) ?? [] where name.hasSuffix(".jsonl") {
                let path = dirPath + "/" + name
                guard let attrs = try? fm.attributesOfItem(atPath: path),
                      let modified = attrs[.modificationDate] as? Date,
                      let size = (attrs[.size] as? NSNumber)?.uint64Value,
                      now.timeIntervalSince(modified) < window else { continue }
                var file = cache[path] ?? TranscriptFile()
                if size < file.offset { file = TranscriptFile() }   // truncated / rewritten
                if size > file.offset { read(path, into: &file) }
                file.modified = modified
                out[path] = file
            }
        }
        return out
    }

    /// Consume complete lines from `file.offset`; a trailing partial line waits for the next scan.
    static func read(_ path: String, into file: inout TranscriptFile) {
        guard let h = FileHandle(forReadingAtPath: path) else { return }
        defer { try? h.close() }
        guard (try? h.seek(toOffset: file.offset)) != nil,
              let data = try? h.readToEnd(), !data.isEmpty,
              let lastNewline = data.lastIndex(of: 0x0A) else { return }
        for line in data[data.startIndex..<lastNewline].split(separator: 0x0A) {
            file.summary.ingest(Data(line))
        }
        file.offset += UInt64(lastNewline - data.startIndex + 1)
    }

    /// `owner/repo` of a directory's origin remote, for branch-based PR matching.
    static func repo(at cwd: String) -> String? {
        runCapturing("/usr/bin/git", ["-C", cwd, "config", "--get", "remote.origin.url"])
            .flatMap(ProjectScanner.normalizeRepo)
    }
}

// MARK: - Running `claude` processes

/// Maps sessions to the terminal running them, via each `claude` CLI process's tty and cwd.
enum ClaudeProcesses {
    struct Proc: Equatable, Sendable { let pid: Int; let tty: String; var cwd: String? = nil }

    /// `ps -axo pid=,tty=,comm=` → `claude` processes attached to a terminal.
    static func parsePS(_ out: String) -> [Proc] {
        out.split(separator: "\n").compactMap { line in
            let f = line.split(separator: " ", omittingEmptySubsequences: true)
            guard f.count >= 3, let pid = Int(f[0]), f[1] != "??",
                  (f[2...].joined(separator: " ") as NSString).lastPathComponent == "claude" else { return nil }
            return Proc(pid: pid, tty: "/dev/" + f[1])
        }
    }

    /// `lsof -Fpn` output (`p<pid>` then `n<path>` lines) → pid → cwd.
    static func parseLsof(_ out: String) -> [Int: String] {
        var result: [Int: String] = [:]
        var pid: Int?
        for line in out.split(separator: "\n") {
            if line.hasPrefix("p") { pid = Int(line.dropFirst()) }
            else if line.hasPrefix("n"), let p = pid { result[p] = String(line.dropFirst()) }
        }
        return result
    }

    /// The tty of the process whose cwd is `cwd`, else of the deepest one containing it.
    static func tty(for cwd: String, in procs: [Proc]) -> String? {
        if let exact = procs.first(where: { $0.cwd == cwd }) { return exact.tty }
        return procs
            .filter { p in p.cwd.map { cwd.hasPrefix($0 + "/") } ?? false }
            .max { ($0.cwd?.count ?? 0) < ($1.cwd?.count ?? 0) }?.tty
    }

    static func running() -> [Proc] {
        guard let ps = runCapturing("/bin/ps", ["-axo", "pid=,tty=,comm="]) else { return [] }
        var procs = parsePS(ps)
        guard !procs.isEmpty else { return [] }
        // lsof exits 1 if a pid vanished meanwhile; the rest of its output is still valid.
        let cwds = runCapturing("/usr/sbin/lsof", ["-a", "-d", "cwd", "-Fpn", "-p",
                                                   procs.map { String($0.pid) }.joined(separator: ",")],
                                requireSuccess: false).map(parseLsof) ?? [:]
        for i in procs.indices { procs[i].cwd = cwds[procs[i].pid] }
        return procs
    }
}
