import Foundation

/// Curated, synthetic fixtures used by **Demo mode** (Settings → General → Developer).
/// They are injected into the real stores so the app's *actual* views render them —
/// this is a living visual reference of every UX scenario, not a mock UI.
///
/// IMPORTANT: whenever a rendered scenario changes (a new status glyph, badge, relation,
/// activity kind, metadata row, …) update these fixtures so demo mode stays complete.
/// See AGENTS.md.
enum DemoData {
    // Synthetic "signed-in user"; PRs are routed to tabs by their `relations`, not by author.
    static let viewer = "octocat"

    static var viewerLogins: [Provider: String] {
        [.github: viewer, .gitlab: viewer]
    }

    static var providerStatus: [Provider: ProviderStatus] {
        [
            .github: ProviderStatus(enabled: true, source: .cli, user: viewer, error: nil),
            .gitlab: ProviderStatus(enabled: true, source: .cli, user: viewer, error: nil),
        ]
    }

    // A demo worktree that correlates to a demo PR (repo + head branch match), so the
    // worktree/terminal chip shows on the PR row and the reverse PR chip shows on Projects.
    private static let app = "Acme/app"
    private static let altoBranch = "octocat/demo-mode-ui"
    private static var home: String { NSHomeDirectory() }

    static var projects: [LocalProject] {
        [
            LocalProject(id: "\(home)/projects/app", name: "app",
                         path: "\(home)/projects/app", branch: altoBranch, repo: app),
            LocalProject(id: "\(home)/projects/webapp", name: "webapp",
                         path: "\(home)/projects/webapp", branch: "main", repo: "acme/webapp"),
            LocalProject(id: "\(home)/projects/infra", name: "infra",
                         path: "\(home)/projects/infra", branch: "release/2.0", repo: "acme/infra"),
        ]
    }

    /// Regenerated each read so relative timestamps ("updated 5m ago") stay fresh.
    static var pullRequests: [PullRequest] { curated }

    static var activity: [ActivityEvent] { activityFeed }

    // MARK: - Curated PR set (spans Mine / Review / Others and every status combination)

    private static var curated: [PullRequest] {
        [
            // ── Mine (authored) ────────────────────────────────────────────────────
            // CI success + approved → green ✅; correlates to the demo worktree.
            pr(.github, app, 1481, "Add adaptive polling cadence for in-flight CI",
               head: altoBranch, base: "main",
               ci: .success, decision: .approved, approvers: ["alice", "bob"],
               relations: [.authored],
               additions: 214, deletions: 37,
               labels: ["enhancement", "backend"], comments: 5, updated: minsAgo(6)),

            // CI failure + changes requested → red.
            pr(.github, app, 1479, "Refactor GitLab token refresh",
               head: "octocat/glab-refresh", base: "main",
               ci: .failure, decision: .changesRequested, changeRequesters: ["carol"],
               relations: [.authored],
               additions: 88, deletions: 120, labels: ["bug"], comments: 12, updated: minsAgo(41)),

            // CI still pending + review required + pending reviewers; a Draft PR.
            pr(.github, app, 1483, "WIP: notification grouping",
               head: "octocat/notif-grouping", base: "main", draft: true,
               ci: .pending, decision: .reviewRequired,
               pendingReviewers: ["dave", "review-team"],
               relations: [.authored],
               additions: 12, deletions: 0, labels: ["do-not-merge"], comments: 0, updated: minsAgo(2)),

            // GitLab (ref renders as !123): CI error + merge conflict + approved.
            pr(.gitlab, "acme/webapp", 302, "Bump image pipeline to node 20",
               head: "octocat/node-20", base: "main",
               ci: .error, decision: .approved, approvers: ["erin"],
               mergeable: .conflicting, relations: [.authored],
               additions: 6, deletions: 6, labels: ["ci"], comments: 3, updated: hoursAgo(2)),

            // No CI on the PR (nil) + no reviews yet → "No CI checks" + "No reviews yet".
            pr(.github, "acme/webapp", 77, "Docs: clarify demo mode",
               head: "octocat/docs-demo", base: "main",
               ci: nil, decision: nil,
               relations: [.authored],
               additions: 40, deletions: 2, labels: [], comments: 0, updated: hoursAgo(5)),

            // CI expected (queued, not yet started) → yellow clock.
            pr(.gitlab, "acme/infra", 58, "Add Terraform module for cache tier",
               head: "octocat/cache-tier", base: "main",
               ci: .expected, decision: .reviewRequired, pendingReviewers: ["frank"],
               relations: [.authored],
               additions: 301, deletions: 0, labels: ["infra"], comments: 1, updated: minsAgo(18)),

            // ── Review (requested from me) ─────────────────────────────────────────
            // Review requested from me individually ("review: you"): awaiting my review.
            pr(.github, "acme/webapp", 88, "Introduce feature flags service",
               author: "grace", head: "grace/feature-flags", base: "main",
               ci: .success, decision: .reviewRequired, pendingReviewers: [viewer, "heidi"],
               relations: [.reviewDirect],
               additions: 540, deletions: 22, labels: ["feature"], comments: 8, updated: minsAgo(25)),

            // Review requested via a team I'm on ("review: team"); CI running.
            pr(.gitlab, "acme/infra", 61, "Rotate staging credentials",
               author: "ivan", head: "ivan/rotate-creds", base: "main",
               ci: .pending, decision: .reviewRequired, pendingReviewers: ["backend-team"],
               relations: [.reviewTeam],
               additions: 15, deletions: 15, labels: ["security"], comments: 2, updated: minsAgo(9)),

            // ── Others (mentioned / watched) ───────────────────────────────────────
            // I was @-mentioned ("mentioned"): approved + green.
            pr(.github, "acme/webapp", 91, "Migrate analytics to new SDK",
               author: "judy", head: "judy/analytics-sdk", base: "develop",
               ci: .success, decision: .approved, approvers: ["mallory"],
               relations: [.mentioned],
               additions: 120, deletions: 90, labels: ["analytics"], comments: 4, updated: hoursAgo(1)),

            // Individually watched ("watching"): CI failed.
            pr(.gitlab, "acme/infra", 44, "Investigate flaky deploy job",
               author: "oscar", head: "oscar/flaky-deploy", base: "main",
               ci: .failure, decision: nil,
               relations: [.watched],
               additions: 3, deletions: 1, labels: ["flaky", "ci"], comments: 17, updated: hoursAgo(3)),
        ]
    }

    // MARK: - Activity feed (one entry per ActivityKind)

    private static var activityFeed: [ActivityEvent] {
        [
            ev(minsAgo(6), .github, app, 1481, "Add adaptive polling cadence for in-flight CI", .ciPassed),
            ev(minsAgo(20), .github, "acme/webapp", 91, "Migrate analytics to new SDK", .approved),
            ev(minsAgo(41), .github, app, 1479, "Refactor GitLab token refresh", .ciFailed),
            ev(minsAgo(50), .github, app, 1479, "Refactor GitLab token refresh", .changesRequested),
            ev(hoursAgo(1), .github, "acme/webapp", 88, "Introduce feature flags service", .reviewRequested),
            ev(hoursAgo(2), .gitlab, "acme/webapp", 302, "Bump image pipeline to node 20", .conflict),
        ]
    }

    // MARK: - Factories

    private static func pr(
        _ provider: Provider, _ repo: String, _ number: Int, _ title: String,
        author: String? = nil, head: String, base: String, draft: Bool = false,
        ci: CheckState?, decision: ReviewDecision?,
        approvers: [String] = [], changeRequesters: [String] = [], pendingReviewers: [String] = [],
        mergeable: Mergeable = .mergeable, relations: Set<PRRelation>,
        additions: Int, deletions: Int, labels: [String], comments: Int, updated: String
    ) -> PullRequest {
        let prefix = provider == .gitlab ? "!" : "#"
        return PullRequest(
            id: "\(provider.rawValue):\(repo)\(prefix)\(number)",
            provider: provider, number: number, title: title,
            url: demoURL(provider, repo, number),
            isDraft: draft, repo: repo,
            author: author ?? (relations.contains(.authored) ? viewer : "contributor"),
            headBranch: head, reviewDecision: decision, mergeable: mergeable, ciState: ci,
            approvers: approvers, changeRequesters: changeRequesters, pendingReviewers: pendingReviewers,
            baseBranch: base, additions: additions, deletions: deletions,
            labels: labels, comments: comments, updatedAt: updated, relations: relations)
    }

    private static func ev(
        _ date: Date, _ provider: Provider, _ repo: String, _ number: Int,
        _ title: String, _ kind: ActivityKind
    ) -> ActivityEvent {
        let ref = provider == .gitlab ? "!\(number)" : "#\(number)"
        return ActivityEvent(
            date: date, prId: "\(provider.rawValue):\(repo)\(ref)", repo: repo,
            number: number, ref: ref, title: title, url: demoURL(provider, repo, number), kind: kind)
    }

    private static func demoURL(_ provider: Provider, _ repo: String, _ number: Int) -> String {
        provider == .gitlab
            ? "https://gitlab.com/\(repo)/-/merge_requests/\(number)"
            : "https://github.com/\(repo)/pull/\(number)"
    }

    // ISO8601 timestamp `n` minutes/hours in the past (for the "updated …" metadata line).
    private static func minsAgo(_ n: Int) -> String { iso(Date().addingTimeInterval(TimeInterval(-n * 60))) }
    private static func hoursAgo(_ n: Int) -> String { iso(Date().addingTimeInterval(TimeInterval(-n * 3600))) }
    private static func minsAgo(_ n: Int) -> Date { Date().addingTimeInterval(TimeInterval(-n * 60)) }
    private static func hoursAgo(_ n: Int) -> Date { Date().addingTimeInterval(TimeInterval(-n * 3600)) }
    private static func iso(_ d: Date) -> String { ISO8601DateFormatter().string(from: d) }
}
