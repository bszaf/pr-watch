import Testing
import Foundation
@testable import PRWatch

@Suite struct DemoDataTests {
    /// Demo mode is a visual reference, so its fixtures must exercise every scenario the
    /// real views can render. This guards against the dataset silently going stale.
    @Test func coversEveryRenderedScenario() {
        let prs = DemoData.pullRequests

        // CI: every settled/in-flight state plus the "no checks" (nil) case.
        let ci = Set(prs.map(\.ciState))
        for state in [CheckState.success, .failure, .error, .pending, .expected] {
            #expect(ci.contains(state))
        }
        #expect(ci.contains(nil))

        // Every review decision, and every kind of reviewer list.
        #expect(Set(prs.compactMap(\.reviewDecision)) == [.approved, .changesRequested, .reviewRequired])
        #expect(prs.contains { !$0.approvers.isEmpty })
        #expect(prs.contains { !$0.changeRequesters.isEmpty })
        #expect(prs.contains { !$0.pendingReviewers.isEmpty })
        #expect(prs.contains { $0.approvers.isEmpty && $0.changeRequesters.isEmpty && $0.pendingReviewers.isEmpty })

        // Draft + merge conflict glyphs.
        #expect(prs.contains { $0.isDraft })
        #expect(prs.contains { $0.mergeable == .conflicting })

        // Every relation badge / tab-routing reason.
        var relations = Set<PRRelation>()
        prs.forEach { relations.formUnion($0.relations) }
        #expect(relations == [.authored, .reviewDirect, .reviewTeam, .mentioned, .watched])

        // Both providers (so `#123` and `!123` refs both render).
        #expect(Set(prs.map(\.provider)) == [.github, .gitlab])

        // Metadata rows in the expanded detail.
        #expect(prs.allSatisfy { $0.baseBranch != nil && $0.additions != nil && $0.deletions != nil })
        #expect(prs.contains { !$0.labels.isEmpty })
        #expect(prs.contains { ($0.comments ?? 0) > 0 })

        // Comment-only reviews + unresolved thread badges (awaiting my reply, and not).
        #expect(prs.contains { !$0.commentedReviewers.isEmpty })
        #expect(prs.contains { $0.unresolvedThreads > 0 && $0.awaitingMyReply > 0 })
        #expect(prs.contains { $0.unresolvedThreads > 0 && $0.awaitingMyReply == 0 })

        // Failing checks in the detail: a red PR, one green only through an ignored check, and a
        // list cut off at the fetch cap.
        let applied = prs.map { $0.applyingIgnoredChecks(DemoData.ignoredChecks[$0.repo] ?? []) }
        #expect(applied.contains { $0.ciState?.isFailure == true && $0.checks.contains { $0.state.isFailure } })
        #expect(applied.contains { $0.ciState == .success && !$0.ignoredFailures.isEmpty })
        #expect(prs.contains { !$0.checksComplete })

        // Every activity kind appears in the feed — can't silently rot.
        #expect(Set(DemoData.activity.map(\.kind)) == Set(ActivityKind.allCases))

        // Every agent state, and both ways a session attaches to a PR (link, head branch).
        let agents = DemoData.agentSessions
        #expect(Set(agents.map(\.state)) == Set(AgentState.allCases))
        #expect(agents.contains { s in !s.prLinks.isEmpty && prs.contains { s.works(on: $0) } })
        #expect(agents.contains { s in s.prLinks.isEmpty && prs.contains { s.works(on: $0) } })
        #expect(agents.contains { $0.tty != nil } && agents.contains { $0.tty == nil })

        // Worktree states: uncommitted changes, and a feature branch with no PR (with an agent in it).
        let projects = DemoData.projects
        #expect(projects.contains { $0.changedFiles > 0 })
        let noPR = projects.filter { p in p.isActiveWithoutPR(now: Date()) && !prs.contains { $0.repo == p.repo && $0.headBranch == p.branch } }
        #expect(noPR.contains { p in agents.contains { $0.cwd == p.path } })

        // Today's progress has something merged of mine, and PRs that need an agent.
        let mergedAt = DemoData.activity.first { $0.kind == .merged }?.date ?? .distantPast
        #expect(dailyProgress(activity: DemoData.activity, prs: prs, agents: agents, now: mergedAt).merged > 0)
        #expect(prs.contains { $0.isMine && $0.needsAgent })

        // At least one PR routes to each of Mine / Review / Others.
        #expect(prs.contains { $0.isMine })
        #expect(prs.contains { $0.isReview && !$0.isMine })
        #expect(prs.contains { !$0.isMine && !$0.isReview })
    }

    /// Demo mode populates the stores locally (no network) and the demo worktree
    /// correlates to a demo PR so the worktree/terminal chip and reverse PR chip show.
    @MainActor @Test func demoModePopulatesStoresAndCorrelatesProject() async {
        ActivityStore.overrideURL = ActivityStore.freshScratchURL()
        defer { ActivityStore.overrideURL = nil }
        let settings = AppSettings()
        settings.demoMode = true
        defer { settings.demoMode = false }
        let store = PRStore(settings: settings)
        let projects = ProjectStore(settings: settings)

        await store.refresh()
        await projects.scan()

        #expect(!store.pullRequests.isEmpty)
        #expect(!store.activity.isEmpty)
        #expect(store.nextPollDate == nil)   // polling is stopped while in demo mode
        #expect(store.lastError == nil)
        #expect(store.pullRequests.contains { $0.ciState == .success && !$0.ignoredFailures.isEmpty })

        // Some demo PR maps to a demo local project via repo + head branch.
        #expect(store.pullRequests.contains { projects.project(for: $0) != nil })
    }
}
