import Testing
@testable import PRWatch

private func pr(
    ci: CheckState? = nil,
    review: ReviewDecision? = nil,
    mergeable: Mergeable = .unknown
) -> PullRequest {
    PullRequest(
        id: "github:RiverFinancial/alto#1", provider: .github, number: 1, title: "Test PR",
        url: "https://example.com", isDraft: false, repo: "RiverFinancial/alto",
        author: "bszaf", reviewDecision: review, mergeable: mergeable, ciState: ci
    )
}

private let allOn = Triggers(ci: true, review: true, conflicts: true)

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
        #expect(n.first?.title.contains("alto #1") == true)
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
        let triggers = Triggers(ci: false, review: true, conflicts: true)
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

    @Test func multipleTransitionsStack() {
        let prev = SnapshotState(pr(ci: .pending, review: .reviewRequired, mergeable: .mergeable))
        let n = notifications(
            for: pr(ci: .failure, review: .changesRequested, mergeable: .conflicting),
            previous: prev, triggers: allOn
        )
        #expect(n.count == 3)
    }
}
