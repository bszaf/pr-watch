import Testing
import Foundation
@testable import PRWatch

private func pr(
    ci: CheckState? = nil,
    review: ReviewDecision? = nil,
    mergeable: Mergeable = .unknown,
    approvers: [String] = [],
    changeRequesters: [String] = [],
    awaitingReply: Int = 0
) -> PullRequest {
    PullRequest(
        id: "github:Acme/app#1", provider: .github, number: 1, title: "Test PR",
        url: "https://example.com", isDraft: false, repo: "Acme/app",
        author: "bszaf", headBranch: nil, reviewDecision: review, mergeable: mergeable, ciState: ci,
        approvers: approvers, changeRequesters: changeRequesters,
        pendingReviewers: [], baseBranch: nil, additions: nil, deletions: nil,
        labels: [], comments: nil, updatedAt: nil, awaitingMyReply: awaitingReply
    )
}

private let allOn = Triggers(ci: true, review: true, conflicts: true, comments: true)

@Suite struct NotificationRulesTests {
    @Test func firstSightingNeverNotifies() {
        let n = notifications(for: pr(ci: .failure), previous: nil, triggers: allOn)
        #expect(n.isEmpty)
    }

    @Test func ciPendingToSuccessNotifies() {
        let prev = SnapshotState(pr(ci: .pending))
        let n = notifications(for: pr(ci: .success), previous: prev, triggers: allOn)
        #expect(n.count == 1)
        #expect(n.first?.title.contains("CI passed") == true)
        #expect(n.first?.title.contains("app #1") == true)
    }

    @Test func ciFailureNotifies() {
        let prev = SnapshotState(pr(ci: .pending))
        let n = notifications(for: pr(ci: .failure), previous: prev, triggers: allOn)
        #expect(n.first?.title.contains("CI failed") == true)
    }

    @Test func unchangedCiDoesNotNotify() {
        let prev = SnapshotState(pr(ci: .success))
        let n = notifications(for: pr(ci: .success), previous: prev, triggers: allOn)
        #expect(n.isEmpty)
    }

    @Test func pendingIsNotTerminalSoNoNotify() {
        let prev = SnapshotState(pr(ci: nil))
        let n = notifications(for: pr(ci: .pending), previous: prev, triggers: allOn)
        #expect(n.isEmpty)
    }

    @Test func disabledTriggerSuppresses() {
        let prev = SnapshotState(pr(ci: .pending))
        let triggers = Triggers(ci: false, review: true, conflicts: true, comments: true)
        let n = notifications(for: pr(ci: .failure), previous: prev, triggers: triggers)
        #expect(n.isEmpty)
    }

    @Test func newConflictNotifiesOnce() {
        let prev = SnapshotState(pr(mergeable: .mergeable))
        let n1 = notifications(for: pr(mergeable: .conflicting), previous: prev, triggers: allOn)
        #expect(n1.contains { $0.title.contains("Merge conflict") })
        // stays conflicting -> no repeat
        let prev2 = SnapshotState(pr(mergeable: .conflicting))
        let n2 = notifications(for: pr(mergeable: .conflicting), previous: prev2, triggers: allOn)
        #expect(n2.isEmpty)
    }

    @Test func reviewApprovalNotifies() {
        let prev = SnapshotState(pr(review: .reviewRequired))
        let n = notifications(for: pr(review: .approved), previous: prev, triggers: allOn)
        #expect(n.first?.title.contains("Approved") == true)
    }

    @Test func approvalNotificationNamesTheApprover() {
        let prev = SnapshotState(pr(review: .reviewRequired))
        let n = notifications(for: pr(review: .approved, approvers: ["alice"]), previous: prev, triggers: allOn)
        #expect(n.first?.title.contains("Approved by @alice") == true)
    }

    // GitHub's mergeable flaps to UNKNOWN between polls; that must not re-fire conflicts.
    @Test func unknownMergeableCarriesLastKnownForward() {
        #expect(resolvedMergeable(.unknown, previous: .conflicting) == .conflicting)
        #expect(resolvedMergeable(.unknown, previous: .mergeable) == .mergeable)
        #expect(resolvedMergeable(.unknown, previous: nil) == .unknown)
        #expect(resolvedMergeable(.conflicting, previous: .mergeable) == .conflicting)
    }

    @Test func conflictDoesNotRefireAfterUnknownFlap() {
        // With last-known carried forward, a re-observed CONFLICTING is not a new transition.
        let prev = SnapshotState(ciState: nil, reviewDecision: nil, mergeable: .conflicting)
        let n = notifications(for: pr(mergeable: .conflicting), previous: prev, triggers: allOn)
        #expect(n.isEmpty)
    }

    @Test func adaptivePollingSpeedsUpWhenActive() {
        // Idle (nothing pending, no recent change) → configured interval.
        #expect(adaptiveInterval(anyPending: false, recentlyChanged: false, idle: 60) == 60)
        // CI in flight → fast.
        #expect(adaptiveInterval(anyPending: true, recentlyChanged: false, idle: 60) == 30)
        // Recent change → fast.
        #expect(adaptiveInterval(anyPending: false, recentlyChanged: true, idle: 300) == 30)
        // Idle never faster than the fast floor.
        #expect(adaptiveInterval(anyPending: false, recentlyChanged: false, idle: 5) == 30)
    }

    @Test func newUnansweredCommentNotifies() {
        let prev = SnapshotState(ciState: nil, reviewDecision: nil, mergeable: .unknown, awaitingReply: 0)
        let n = notifications(for: pr(awaitingReply: 2), previous: prev, triggers: allOn)
        #expect(n.first?.title.contains("awaiting your reply") == true)
    }

    @Test func awaitingReplyRequiresMyParticipation() {
        // My PR, other person spoke last → my turn.
        #expect(threadAwaitsReply(viewer: "me", prAuthor: "me", firstAuthor: "alice",
                                  lastAuthor: "alice", lastIsBot: false))
        // A thread I opened on someone else's PR, they replied → my turn.
        #expect(threadAwaitsReply(viewer: "me", prAuthor: "bob", firstAuthor: "me",
                                  lastAuthor: "bob", lastIsBot: false))
        // Two other people's conversation on someone else's PR → not my turn.
        #expect(!threadAwaitsReply(viewer: "me", prAuthor: "bob", firstAuthor: "alice",
                                   lastAuthor: "alice", lastIsBot: false))
        // Last word is mine, or a bot's → not awaiting me.
        #expect(!threadAwaitsReply(viewer: "me", prAuthor: "me", firstAuthor: "alice",
                                   lastAuthor: "me", lastIsBot: false))
        #expect(!threadAwaitsReply(viewer: "me", prAuthor: "me", firstAuthor: "alice",
                                   lastAuthor: "ci-bot", lastIsBot: true))
    }

    @Test func replyingClearsTheCommentSignal() {
        // Went from 2 awaiting to 1 (you replied to one) → not a new-comment transition.
        let prev = SnapshotState(ciState: nil, reviewDecision: nil, mergeable: .unknown, awaitingReply: 2)
        let n = notifications(for: pr(awaitingReply: 1), previous: prev, triggers: allOn)
        #expect(n.isEmpty)
    }

    @Test func nilPreviousAwaitingCountDoesNotNotify() {
        // Pre-upgrade snapshots have no awaiting count — unknown must not be treated as 0,
        // or every PR with existing unresolved threads fires a banner after an app update.
        let prev = SnapshotState(ciState: nil, reviewDecision: nil, mergeable: .unknown, awaitingReply: nil)
        let n = notifications(for: pr(awaitingReply: 3), previous: prev, triggers: allOn)
        #expect(n.isEmpty)
    }

    @Test func multipleTransitionsStack() {
        let prev = SnapshotState(pr(ci: .pending, review: .reviewRequired, mergeable: .mergeable))
        let n = notifications(
            for: pr(ci: .failure, review: .changesRequested, mergeable: .conflicting),
            previous: prev, triggers: allOn
        )
        #expect(n.count == 3)
    }
}

private func provPR(_ provider: Provider, _ number: Int, ci: CheckState?, mergeable: Mergeable = .mergeable) -> PullRequest {
    let repo = provider == .github ? "Acme/app" : "group/proj"
    return PullRequest(
        id: "\(provider.rawValue):\(repo)#\(number)", provider: provider, number: number, title: "T",
        url: "https://example.com", isDraft: false, repo: repo, author: "bszaf", headBranch: nil,
        reviewDecision: nil, mergeable: mergeable, ciState: ci, approvers: [], changeRequesters: [],
        pendingReviewers: [], baseBranch: nil, additions: nil, deletions: nil,
        labels: [], comments: nil, updatedAt: nil
    )
}

@Suite struct SnapshotAndEventDateTests {
    @Test func failedProviderKeepsItsEntriesWhileSucceededProviderIsReplaced() {
        let previous: [String: SnapshotState] = [
            "github:Acme/app#1": SnapshotState(ciState: .pending, reviewDecision: nil, mergeable: .mergeable),
            "gitlab:group/proj#2": SnapshotState(ciState: .success, reviewDecision: nil, mergeable: .conflicting),
            "gitlab:group/proj#3": SnapshotState(ciState: .success, reviewDecision: nil, mergeable: .mergeable),
        ]
        let next = nextSnapshot([provPR(.gitlab, 2, ci: .failure, mergeable: .unknown)],
                                previous: previous, keeping: [.github])
        #expect(next == [
            "github:Acme/app#1": SnapshotState(ciState: .pending, reviewDecision: nil, mergeable: .mergeable),
            "gitlab:group/proj#2": SnapshotState(ciState: .failure, reviewDecision: nil, mergeable: .conflicting),
        ])
    }

    @Test func ciAndConflictEventsAreDatedNowNotAtUpdatedAt() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let stale = "2026-01-01T10:00:00Z"
        #expect(eventDate(for: .ciPassed, updatedAt: stale, now: now) == now)
        #expect(eventDate(for: .conflict, updatedAt: stale, now: now) == now)
        #expect(eventDate(for: .approved, updatedAt: stale, now: now) == parseISODate(stale))
        #expect(eventDate(for: .approved, updatedAt: nil, now: now) == now)
    }
}
