import Testing
import Foundation
@testable import PRWatch

private func summary(_ lines: [String]) -> TranscriptSummary {
    var s = TranscriptSummary()
    lines.forEach { s.ingest(Data($0.utf8)) }
    return s
}

private let prompt = #"{"type":"user","sessionId":"s1","cwd":"/w/app","gitBranch":"feat/x","message":{"role":"user","content":"fix CI"}}"#
private let toolUse = #"{"type":"assistant","message":{"stop_reason":"tool_use","content":[{"type":"tool_use","name":"Bash"}]}}"#
private let toolResult = #"{"type":"user","message":{"content":[{"type":"tool_result","content":"ok"}]}}"#
private let endTurn = #"{"type":"assistant","message":{"stop_reason":"end_turn","content":[{"type":"text","text":"Done"}]}}"#
private let turnDuration = #"{"type":"system","subtype":"turn_duration","durationMs":10}"#

private func session(repo: String?, branch: String?, links: [PRLink] = []) -> AgentSession {
    AgentSession(id: "s", title: "T", lastPrompt: nil, cwd: "/w/app", branch: branch, repo: repo,
                 prLinks: links, lastActivity: .distantPast, state: .working)
}

private func pr(_ repo: String, _ number: Int, head: String?, provider: Provider = .github) -> PullRequest {
    PullRequest(
        id: "\(provider.rawValue):\(repo)#\(number)", provider: provider, number: number, title: "T",
        url: "https://example.com", isDraft: false, repo: repo, author: "me", headBranch: head,
        reviewDecision: nil, mergeable: .mergeable, ciState: nil, approvers: [], changeRequesters: [],
        pendingReviewers: [], baseBranch: nil, additions: nil, deletions: nil,
        labels: [], comments: nil, updatedAt: nil
    )
}

@Suite struct TranscriptSummaryTests {
    @Test func phaseFollowsTheTurn() {
        #expect(summary([prompt]).phase == .awaitingModel)
        #expect(summary([prompt, toolUse]).phase == .toolRunning)
        #expect(summary([prompt, toolUse, toolResult]).phase == .awaitingModel)
        #expect(summary([prompt, toolUse, toolResult, endTurn]).phase == .turnEnded)
        #expect(summary([prompt, toolUse, turnDuration]).phase == .turnEnded)
    }

    @Test func interruptEndsTheTurn() {
        let interrupt = #"{"type":"user","message":{"content":[{"type":"text","text":"[Request interrupted by user for tool use]"}]}}"#
        #expect(summary([prompt, toolUse, interrupt]).phase == .turnEnded)
    }

    @Test func localCommandsSidechainAndMetaEntriesDontMoveThePhase() {
        let command = #"{"type":"user","message":{"content":"<command-name>/model</command-name>"}}"#
        let stdout = #"{"type":"user","message":{"content":"<local-command-stdout>Set model</local-command-stdout>"}}"#
        let meta = #"{"type":"user","isMeta":true,"message":{"content":"Caveat"}}"#
        let sidechain = #"{"type":"assistant","isSidechain":true,"message":{"stop_reason":"tool_use","content":[]}}"#
        #expect(summary([endTurn, command, stdout, meta, sidechain]).phase == .turnEnded)
    }

    @Test func collectsMetadataAndDedupesPRLinks() {
        let title = #"{"type":"ai-title","aiTitle":"CI fix","sessionId":"s1"}"#
        let link = #"{"type":"pr-link","prNumber":7,"prUrl":"https://github.com/o/r/pull/7","prRepository":"o/r"}"#
        let mode = #"{"type":"permission-mode","permissionMode":"bypassPermissions"}"#
        let s = summary([prompt, title, link, link, mode])
        #expect(s.sessionId == "s1")
        #expect(s.cwd == "/w/app")
        #expect(s.branch == "feat/x")
        #expect(s.title == "CI fix")
        #expect(s.prLinks == [PRLink(repo: "o/r", number: 7, url: "https://github.com/o/r/pull/7")])
        #expect(s.bypassPermissions)
        #expect(summary([prompt, #"{"type":"user","gitBranch":"HEAD"}"#]).branch == nil)
    }
}

@Suite struct AgentStateTests {
    @Test func toolSilenceMeansWaitingUnlessPermissionsAreBypassed() {
        #expect(agentState(phase: .toolRunning, quietFor: 5, bypassPermissions: false) == .working)
        #expect(agentState(phase: .toolRunning, quietFor: 60, bypassPermissions: false) == .waiting)
        #expect(agentState(phase: .toolRunning, quietFor: 60, bypassPermissions: true) == .working)
        #expect(agentState(phase: .toolRunning, quietFor: 31 * 60, bypassPermissions: false) == .inactive)
    }

    @Test func midTurnSilenceGoesInactiveButAFinishedTurnStaysIdle() {
        #expect(agentState(phase: .awaitingModel, quietFor: 60, bypassPermissions: false) == .working)
        #expect(agentState(phase: .awaitingModel, quietFor: 6 * 60, bypassPermissions: false) == .inactive)
        #expect(agentState(phase: .turnEnded, quietFor: 10 * 3600, bypassPermissions: false) == .idle)
    }

    @Test func notifiesOnlyOnLiveTransitionsThatNeedTheUser() {
        let s = session(repo: "o/r", branch: "feat/x")
        #expect(agentNotification(from: .working, to: .waiting, session: s)?.title == "✋ Agent may need you — T")
        #expect(agentNotification(from: .waiting, to: .idle, session: s)?.title == "✅ Agent finished — T")
        #expect(agentNotification(from: .working, to: .idle, session: s)?.body == "app · feat/x")
        #expect(agentNotification(from: nil, to: .waiting, session: s) == nil)
        #expect(agentNotification(from: .inactive, to: .idle, session: s) == nil)
        #expect(agentNotification(from: .idle, to: .idle, session: s) == nil)
    }
}

@Suite struct AgentPRMatchingTests {
    @Test func matchesByPRLinkOrByHeadBranchInTheSameRepo() {
        let linked = session(repo: nil, branch: nil, links: [PRLink(repo: "o/r", number: 7, url: "u")])
        #expect(linked.works(on: pr("o/r", 7, head: "other")))
        #expect(!linked.works(on: pr("o/r", 8, head: "other")))
        #expect(!linked.works(on: pr("o/r", 7, head: "other", provider: .gitlab)))

        let onBranch = session(repo: "o/r", branch: "feat/x")
        #expect(onBranch.works(on: pr("o/r", 1, head: "feat/x")))
        #expect(!onBranch.works(on: pr("o/other", 2, head: "feat/x")))
        #expect(!onBranch.works(on: pr("o/r", 3, head: "feat/y")))
    }
}

@Suite struct TranscriptScannerTests {
    private func makeRoot() throws -> (root: String, file: String) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PRWatchAgents-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: root + "/proj/s1/subagents", withIntermediateDirectories: true)
        return (root, root + "/proj/s1.jsonl")
    }

    private func append(_ path: String, _ text: String) throws {
        if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
        let h = try #require(FileHandle(forWritingAtPath: path))
        try h.seekToEnd()
        try h.write(contentsOf: Data(text.utf8))
        try h.close()
    }

    @Test func readsOnlyCompleteLinesAndResumesFromTheOffset() throws {
        let (root, file) = try makeRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try append(file, prompt + "\n" + String(toolUse.prefix(20)))

        let first = TranscriptScanner.scan(root: root, cache: [:], now: Date())
        #expect(first[file]?.summary.phase == .awaitingModel)
        #expect(first[file]?.offset == UInt64(prompt.utf8.count + 1))

        try append(file, String(toolUse.dropFirst(20)) + "\n")
        let second = TranscriptScanner.scan(root: root, cache: first, now: Date())
        #expect(second[file]?.summary.phase == .toolRunning)
        #expect(second[file]?.summary.cwd == "/w/app")
    }

    @Test func skipsSubagentTranscriptsAndFilesOutsideTheWindow() throws {
        let (root, file) = try makeRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let old = root + "/proj/old.jsonl"
        try append(file, prompt + "\n")
        try append(root + "/proj/s1/subagents/agent-a.jsonl", prompt + "\n")
        try append(old, prompt + "\n")
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-TranscriptScanner.window - 60)], ofItemAtPath: old)

        #expect(Set(TranscriptScanner.scan(root: root, cache: [:], now: Date()).keys) == [file])
    }
}

@Suite struct AgentRepoFilterTests {
    @Test func filtersByCwdRepoOrLinkedPRCaseInsensitively() {
        let s = session(repo: "Acme/App", branch: "x", links: [PRLink(repo: "acme/other", number: 1, url: "u")])
        #expect(s.matches(repoFilters: []))
        #expect(s.matches(repoFilters: [" acme/app "]))
        #expect(s.matches(repoFilters: ["acme/other"]))
        #expect(!s.matches(repoFilters: ["acme/unrelated"]))
        #expect(!session(repo: nil, branch: nil).matches(repoFilters: ["acme/app"]))
    }
}

@Suite struct ClaudeProcessesTests {
    @Test func parsesTerminalClaudeProcessesOnly() {
        let ps = """
          86702 ttys000  claude
          98842 ??       /bin/zsh
          97655 ttys003  /opt/homebrew/bin/claude
          12345 ttys004  claude-helper
        """
        #expect(ClaudeProcesses.parsePS(ps) == [
            .init(pid: 86702, tty: "/dev/ttys000"), .init(pid: 97655, tty: "/dev/ttys003"),
        ])
        #expect(ClaudeProcesses.parseLsof("p86702\nfcwd\nn/w/app\np97655\nfcwd\nn/w/app2\n")
                == [86702: "/w/app", 97655: "/w/app2"])
    }

    private typealias C = ClaudeProcesses.Candidate
    private func at(_ minsAgo: Double) -> Date { Date(timeIntervalSince1970: 1_000_000 - minsAgo * 60) }

    @Test func sessionFilesMapEachProcessToItsOwnSessionInASharedFolder() {
        let sessions = [C(id: "a", cwd: "/w/app", lastActivity: at(1)),
                        C(id: "b", cwd: "/w/app", lastActivity: at(2)),
                        C(id: "old", cwd: "/w/app", lastActivity: at(0))]
        let procs: [ClaudeProcesses.Proc] = [
            .init(pid: 1, tty: "/dev/ttys001", cwd: "/w/app", sessionId: "b"),
            .init(pid: 2, tty: "/dev/ttys002", cwd: "/w/app", sessionId: "a"),
        ]
        #expect(ClaudeProcesses.ttys(for: sessions, procs: procs) == ["a": "/dev/ttys002", "b": "/dev/ttys001"])
    }

    @Test func aProcessWithoutASessionFileTakesTheNewestUnclaimedSessionInItsFolder() {
        let sessions = [C(id: "claimed", cwd: "/w/app", lastActivity: at(0)),
                        C(id: "newer", cwd: "/w/app", lastActivity: at(1)),
                        C(id: "older", cwd: "/w/app", lastActivity: at(5)),
                        C(id: "sub", cwd: "/w/lib/sub", lastActivity: at(1))]
        let procs: [ClaudeProcesses.Proc] = [
            .init(pid: 1, tty: "/dev/ttys001", cwd: "/w/app", sessionId: "claimed"),
            .init(pid: 2, tty: "/dev/ttys002", cwd: "/w/app"),
            .init(pid: 3, tty: "/dev/ttys003", cwd: "/w"),
            .init(pid: 4, tty: "/dev/ttys004", cwd: "/w/lib"),
            .init(pid: 5, tty: "/dev/ttys005", cwd: "/elsewhere"),
        ]
        #expect(ClaudeProcesses.ttys(for: sessions, procs: procs) == [
            "claimed": "/dev/ttys001", "newer": "/dev/ttys002", "older": "/dev/ttys003", "sub": "/dev/ttys004",
        ])
    }

    @Test func readsSessionIdsFromPidFilesSkippingOthers() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PRWatchSessions-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try #"{"pid":42,"sessionId":"s-42","cwd":"/w","status":"idle"}"#.write(toFile: dir + "/42.json", atomically: true, encoding: .utf8)
        try "not json".write(toFile: dir + "/43.json", atomically: true, encoding: .utf8)
        try "k".write(toFile: dir + "/42.abc.key", atomically: true, encoding: .utf8)
        #expect(ClaudeProcesses.sessionIds(in: dir) == [42: "s-42"])
    }
}

@Suite struct ShellTests {
    private final class Box: @unchecked Sendable { var out: String? }

    @Test func capturesOutputLargerThanThePipeBuffer() {
        // A deadlock blocks the thread for good, so wait with a deadline instead of inline.
        let box = Box(), done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            box.out = runCapturing("/bin/sh", ["-c", "head -c 200000 /dev/zero"])
            done.signal()
        }
        #expect(done.wait(timeout: .now() + 10) == .success)
        #expect(box.out?.count == 200_000)
    }
}
