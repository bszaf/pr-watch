import Testing
import Foundation
@testable import PRWatch

private func pr(
    provider: Provider = .github, number: Int = 12, ci: CheckState? = nil,
    review: ReviewDecision? = nil, mergeable: Mergeable = .mergeable, awaiting: Int = 0,
    draft: Bool = false, mine: Bool = true
) -> PullRequest {
    var p = PullRequest(
        id: "\(provider.rawValue):o/r#\(number)", provider: provider, number: number, title: "T",
        url: "https://example.com/o/r/pull/\(number)", isDraft: draft, repo: "o/r", author: "me",
        headBranch: "feat/x", reviewDecision: review, mergeable: mergeable, ciState: ci,
        approvers: [], changeRequesters: [], pendingReviewers: [], baseBranch: "main",
        additions: nil, deletions: nil, labels: [], comments: nil, updatedAt: nil, awaitingMyReply: awaiting
    )
    p.relations = mine ? [.authored] : [.reviewDirect]
    return p
}

@Suite struct AgentPromptTests {
    @Test func listsEveryProblemOnOneLine() {
        let prompt = agentPrompt(for: pr(ci: .failure, review: .changesRequested, mergeable: .conflicting))
        #expect(prompt == "PR https://example.com/o/r/pull/12 (o/r #12, branch feat/x): "
            + "CI is failing — find the failing checks with `gh pr checks 12` and their logs, and fix them; "
            + "it conflicts with main — rebase onto origin/main and resolve the conflicts; "
            + "address the unresolved review comments (`gh pr view 12 --comments` and the review threads) and reply to each. "
            + "Commit and push when done.")
        #expect(!prompt.contains("\n"))
    }

    @Test func usesGlabOnGitLabAndFallsBackWhenNothingIsWrong() {
        #expect(agentPrompt(for: pr(provider: .gitlab, ci: .error)).contains("`glab ci status`"))
        #expect(agentPrompt(for: pr(provider: .gitlab, awaiting: 1)).contains("`glab mr view 12 --comments`"))
        #expect(agentPrompt(for: pr()).contains(": check its status and continue the work."))
    }

    @Test func needsAgentOnlyForActionableState() {
        #expect(!pr().needsAgent)
        #expect(!pr(ci: .pending, review: .reviewRequired).needsAgent)
        #expect(pr(ci: .failure).needsAgent)
        #expect(pr(mergeable: .conflicting).needsAgent)
        #expect(pr(review: .changesRequested).needsAgent)
        #expect(pr(awaiting: 2).needsAgent)
    }

    @Test func commandLineQuotesThePrompt() {
        #expect(agentCommandLine(template: "claude {prompt}", prompt: "it's red") == #"claude 'it'\''s red'"#)
        #expect(agentCommandLine(template: " codex ", prompt: "go") == "codex 'go'")
    }
}

@Suite struct VanishedPRTests {
    private func final(_ state: String, merged: String? = nil, closed: String? = nil) -> PRFinalState {
        PRFinalState(state: state, mergedAt: merged, closedAt: closed, title: "T", url: "u", author: "me")
    }

    @Test func mergedAndClosedAreReportedOpenAndMissingAreDropped() {
        let ids = ["github:o/r#1", "github:o/r#2", "github:o/r#3", "github:o/r#4"]
        let (closed, unresolved) = GitHubClient.resolveVanished(ids, finals: [
            "github:o/r#1": final("MERGED", merged: "2026-11-02T10:00:00Z"),
            "github:o/r#2": final("CLOSED", closed: "2026-11-02T11:00:00Z"),
            "github:o/r#3": final("OPEN"),
        ])
        #expect(closed == [
            ClosedPR(id: "github:o/r#1", repo: "o/r", number: 1, title: "T", url: "u", author: "me",
                     merged: true, date: parseISODate("2026-11-02T10:00:00Z")!),
            ClosedPR(id: "github:o/r#2", repo: "o/r", number: 2, title: "T", url: "u", author: "me",
                     merged: false, date: parseISODate("2026-11-02T11:00:00Z")!),
        ])
        #expect(unresolved.isEmpty)
    }

    @Test func failedFetchLeavesEveryVanishedIdForRetry() {
        let (closed, unresolved) = GitHubClient.resolveVanished(["github:o/r#1", "github:a/b#2"], finals: nil)
        #expect(closed.isEmpty)
        #expect(unresolved == ["github:o/r#1", "github:a/b#2"])
    }

    @Test func parsesIds() {
        #expect(GitHubClient.parseId("github:o/r.js#42")! == ("o/r.js", 42))
        #expect(GitHubClient.parseId("gitlab:g/p#1") == nil)
    }

    @Test func retainedIdsSurviveTheSnapshotRebuild() {
        let s = SnapshotState(ciState: .success, reviewDecision: nil, mergeable: .mergeable)
        let next = nextSnapshot([], previous: ["github:o/r#1": s, "github:o/r#2": s], keeping: [],
                                retaining: ["github:o/r#1"])
        #expect(next == ["github:o/r#1": s])
    }

    @Test func mergedEventsFollowTheMergedTrigger() {
        let off = Triggers(ci: true, review: true, conflicts: true, comments: true, merged: false)
        #expect(!isEnabled(.merged, off) && !isEnabled(.closed, off))
        #expect(isEnabled(.merged, Triggers(ci: false, review: false, conflicts: false, comments: false, merged: true)))
    }
}

@Suite struct DailyProgressTests {
    private let now = parseISODate("2026-11-02T15:00:00Z")!
    private var utc: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }

    private func event(_ kind: ActivityKind, _ iso: String, mine: Bool?) -> ActivityEvent {
        ActivityEvent(date: parseISODate(iso)!, prId: "x", repo: "o/r", number: 1, ref: "#1",
                      title: "T", url: "u", kind: kind, mine: mine)
    }

    private func agent(_ state: AgentState) -> AgentSession {
        AgentSession(id: UUID().uuidString, title: nil, lastPrompt: nil, cwd: "/w", branch: nil, repo: nil,
                     prLinks: [], lastActivity: now, state: state)
    }

    @Test func countsOnlyMyMergesTodayAndMyOpenPRs() {
        let activity = [
            event(.merged, "2026-11-02T09:00:00Z", mine: true),
            event(.merged, "2026-11-02T10:00:00Z", mine: true),
            event(.closed, "2026-11-02T11:00:00Z", mine: true),
            event(.merged, "2026-11-01T23:59:00Z", mine: true),    // yesterday
            event(.merged, "2026-11-02T12:00:00Z", mine: false),   // someone else's
            event(.merged, "2026-11-02T12:00:00Z", mine: nil),     // pre-field event
            event(.ciPassed, "2026-11-02T12:00:00Z", mine: true),
        ]
        let prs = [
            pr(number: 1, ci: .failure),
            pr(number: 2, review: .approved),
            pr(number: 3, draft: true),
            pr(number: 4, review: .reviewRequired),
            pr(number: 5, ci: .failure, mine: false),
        ]
        let p = dailyProgress(activity: activity, prs: prs,
                              agents: [agent(.working), agent(.waiting), agent(.idle), agent(.inactive)],
                              now: now, calendar: utc)
        #expect(p == DailyProgress(merged: 2, closed: 1, openMine: 4, failingCI: 1, inReview: 2,
                                   approved: 1, agentsWorking: 1, agentsNeedYou: 2))
    }
}

@Suite struct WorktreeTests {
    private func project(_ branch: String?, defaultBranch: String?) -> LocalProject {
        LocalProject(id: "/w", name: "w", path: "/w", branch: branch, repo: "o/r", defaultBranch: defaultBranch)
    }

    @Test func featureBranchUsesOriginHeadWhenKnown() {
        #expect(project("feat/x", defaultBranch: "main").onFeatureBranch)
        #expect(!project("develop", defaultBranch: "develop").onFeatureBranch)
        #expect(project("main", defaultBranch: "develop").onFeatureBranch)
        #expect(!project("master", defaultBranch: nil).onFeatureBranch)
        #expect(project("feat/x", defaultBranch: nil).onFeatureBranch)
        #expect(!project("HEAD", defaultBranch: "main").onFeatureBranch)
        #expect(!project(nil, defaultBranch: "main").onFeatureBranch)
    }

    @Test func onlyRecentOrDirtyFeatureBranchesCountAsMissingAPR() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        var p = project("feat/x", defaultBranch: "main")
        p.lastCommit = now.addingTimeInterval(-6 * 86400)
        #expect(p.isActiveWithoutPR(now: now))
        p.lastCommit = now.addingTimeInterval(-8 * 86400)
        #expect(!p.isActiveWithoutPR(now: now))
        p.changedFiles = 2
        #expect(p.isActiveWithoutPR(now: now))
        var main = project("main", defaultBranch: "main")
        main.changedFiles = 5
        #expect(!main.isActiveWithoutPR(now: now))
    }
}

@Suite struct HandoffPlanTests {
    private func session(_ state: AgentState, tty: String?) -> AgentSession {
        AgentSession(id: "s", title: nil, lastPrompt: nil, cwd: "/w/app", branch: nil, repo: nil,
                     prLinks: [], lastActivity: .distantPast, state: state, tty: tty)
    }

    @Test func typesOnlyIntoAnIdleRunningSession() {
        #expect(HandoffPlan(session: session(.idle, tty: "/dev/ttys1"), path: "/p") == .type(tty: "/dev/ttys1"))
        #expect(HandoffPlan(session: session(.waiting, tty: "/dev/ttys1"), path: "/p") == .focus(tty: "/dev/ttys1"))
        #expect(HandoffPlan(session: session(.working, tty: "/dev/ttys1"), path: "/p") == .focus(tty: "/dev/ttys1"))
    }

    @Test func startsANewAgentWithoutARunningSession() {
        #expect(HandoffPlan(session: session(.idle, tty: nil), path: "/p") == .start(dir: "/p"))
        #expect(HandoffPlan(session: session(.idle, tty: nil), path: nil) == .start(dir: "/w/app"))
        #expect(HandoffPlan(session: nil, path: nil) == HandoffPlan.none)
    }
}
