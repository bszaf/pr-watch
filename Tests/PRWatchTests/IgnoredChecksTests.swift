import Testing
import Foundation
@testable import PRWatch

private func pr(ci: CheckState?, _ checks: [CICheck], complete: Bool = true) -> PullRequest {
    var p = PullRequest(
        id: "github:o/r#1", provider: .github, number: 1, title: "T", url: "u", isDraft: false,
        repo: "o/r", author: "me", headBranch: "b", reviewDecision: nil, mergeable: .mergeable,
        ciState: ci, approvers: [], changeRequesters: [], pendingReviewers: [], baseBranch: nil,
        additions: nil, deletions: nil, labels: [], comments: nil, updatedAt: nil)
    p.checks = checks
    p.checksComplete = complete
    return p
}

private let approval = CICheck(name: "two-human-approval", state: .failure)
private let tests = CICheck(name: "tests", state: .failure)
private let build = CICheck(name: "build", state: .success)
private let lint = CICheck(name: "lint", state: .pending)

@Suite struct IgnoredChecksTests {
    @Test func ignoringTheOnlyFailuresLeavesTheRestDeciding() {
        let green = pr(ci: .failure, [approval, build]).applyingIgnoredChecks(["two-human-approval"])
        #expect(green.ciState == .success)
        #expect(green.ignoredFailures == [approval])

        #expect(pr(ci: .failure, [approval, build, lint]).applyingIgnoredChecks(["two-human-approval"]).ciState == .pending)
        #expect(pr(ci: .failure, [approval, build, lint]).applyingIgnoredChecks(["two-human-approval", "lint"]).ciState == .success)
        #expect(pr(ci: .error, [approval, build]).applyingIgnoredChecks(["two-human-approval"]).ciState == .success)
    }

    @Test func theReportedStateStandsWhenAnythingElseFailsOrTheListIsPartial() {
        let red = pr(ci: .failure, [approval, tests]).applyingIgnoredChecks(["two-human-approval"])
        #expect(red.ciState == .failure)
        #expect(red.ignoredFailures == [approval])

        #expect(pr(ci: .failure, [approval, build], complete: false).applyingIgnoredChecks(["two-human-approval"]).ciState == .failure)
        #expect(pr(ci: .failure, []).applyingIgnoredChecks(["two-human-approval"]).ciState == .failure)
        #expect(pr(ci: .failure, [approval, build]).applyingIgnoredChecks(["Two-Human-Approval"]).ciState == .failure)
        #expect(pr(ci: .pending, [lint]).applyingIgnoredChecks(["lint"]).ciState == .pending)
    }

    @Test func rulesAreKeyedPerRepoCaseInsensitively() {
        var rules = settingCheck("a", ignored: true, in: "Acme/App", rules: [:])
        rules = settingCheck("b", ignored: true, in: "acme/app", rules: rules)
        rules = settingCheck("a", ignored: true, in: "acme/app", rules: rules)
        #expect(rules == ["Acme/App": ["a", "b"]])
        #expect(ignoredChecks(rules, in: "ACME/APP") == ["a", "b"])
        #expect(ignoredChecks(rules, in: "acme/other").isEmpty)

        rules = settingCheck("a", ignored: false, in: "acme/app", rules: rules)
        #expect(rules == ["Acme/App": ["b"]])
        #expect(settingCheck("b", ignored: false, in: "acme/app", rules: rules).isEmpty)
    }

    @Test func aRulesChangeIsAdoptedSilentlyNotReportedAsCIPassing() {
        let before = SnapshotState(ciState: .failure, reviewDecision: .approved, mergeable: .conflicting, awaitingReply: 2)
        let now = pr(ci: .failure, [approval, build]).applyingIgnoredChecks(["two-human-approval"])
        let other = SnapshotState(ciState: .pending, reviewDecision: nil, mergeable: .mergeable)
        let snap = adoptingCIStates([now], into: [now.id: before, "github:o/r#2": other])

        #expect(snap[now.id] == SnapshotState(ciState: .success, reviewDecision: .approved, mergeable: .conflicting, awaitingReply: 2))
        #expect(snap["github:o/r#2"] == other)
        #expect(!transitions(for: now, previous: snap[now.id]).contains(.ciPassed))
        #expect(adoptingCIStates([pr(ci: .success, [])], into: [:]).isEmpty)
    }
}

@Suite struct GitHubChecksTests {
    @Test func mapsCheckRunsAndCommitStatuses() {
        func run(_ status: String, _ conclusion: String?) -> GitHubCheckContext {
            GitHubCheckContext(typename: "CheckRun", name: "\(status)/\(conclusion ?? "-")", status: status,
                               conclusion: conclusion, detailsUrl: "d", title: "t")
        }
        func status(_ state: String) -> GitHubCheckContext {
            GitHubCheckContext(typename: "StatusContext", context: state, state: state, description: "why", targetUrl: "x")
        }
        let got = GitHubClient.checks(from: [
            run("IN_PROGRESS", nil), run("QUEUED", nil), run("COMPLETED", "SUCCESS"), run("COMPLETED", "SKIPPED"),
            run("COMPLETED", "NEUTRAL"), run("COMPLETED", "FAILURE"), run("COMPLETED", "CANCELLED"),
            run("COMPLETED", "TIMED_OUT"),
            status("SUCCESS"), status("FAILURE"), status("ERROR"), status("PENDING"), status("EXPECTED"),
        ])
        #expect(got.map(\.state) == [.pending, .pending, .success, .success, .success, .failure, .failure, .failure,
                                     .success, .failure, .failure, .pending, .pending])
        #expect(got[5] == CICheck(name: "COMPLETED/FAILURE", state: .failure, summary: "t", url: "d"))
        #expect(got[9] == CICheck(name: "FAILURE", state: .failure, summary: "why", url: "x"))
    }

    @Test func checksKeyMovesWithTheCommitOrAnyCountButIgnoresZeros() {
        let key = GitHubClient.checksKey(oid: "abc", runs: [("SUCCESS", 40), ("FAILURE", 0)], statuses: [("FAILURE", 1)])
        #expect(key == GitHubClient.checksKey(oid: "abc", runs: [("SUCCESS", 40)], statuses: [("FAILURE", 1), ("PENDING", 0)]))
        #expect(key != GitHubClient.checksKey(oid: "abd", runs: [("SUCCESS", 40)], statuses: [("FAILURE", 1)]))
        #expect(key != GitHubClient.checksKey(oid: "abc", runs: [("SUCCESS", 39), ("FAILURE", 1)], statuses: [("FAILURE", 1)]))
        #expect(key != GitHubClient.checksKey(oid: "abc", runs: [("FAILURE", 40)], statuses: [("FAILURE", 1)]))
        #expect(key != GitHubClient.checksKey(oid: "abc", runs: [("SUCCESS", 40)], statuses: [("SUCCESS", 1)]))
    }
}
