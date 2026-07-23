import Foundation

enum CheckState: String, Codable, Sendable {
    case success = "SUCCESS"
    case failure = "FAILURE"
    case error = "ERROR"
    case pending = "PENDING"
    case expected = "EXPECTED"

    /// A check rollup is settled once it is no longer pending/expected.
    var isTerminal: Bool { self == .success || self == .failure || self == .error }
    var isFailure: Bool { self == .failure || self == .error }
}

enum ReviewDecision: String, Codable, Sendable {
    case approved = "APPROVED"
    case changesRequested = "CHANGES_REQUESTED"
    case reviewRequired = "REVIEW_REQUIRED"
}

enum Mergeable: String, Codable, Sendable {
    case mergeable = "MERGEABLE"
    case conflicting = "CONFLICTING"
    case unknown = "UNKNOWN"
}

/// Why a PR is in the watched set (a PR can have several). Drives the window tabs.
enum PRRelation: String, Codable, Sendable {
    case authored        // I opened it
    case reviewDirect    // review requested from me individually
    case reviewTeam      // review requested from a team I'm on
    case mentioned       // I was @-mentioned
    case watched         // individually watched (custom PR)
}

struct PullRequest: Identifiable, Sendable, Equatable {
    let id: String            // "<provider>:owner/repo#number" — unique across providers
    let provider: Provider
    let number: Int
    let title: String
    let url: String
    let isDraft: Bool
    let repo: String          // owner/repo (GitHub) or group/project (GitLab)
    let author: String
    let headBranch: String?   // head/source branch — used to match a local worktree
    let reviewDecision: ReviewDecision?
    let mergeable: Mergeable
    let ciState: CheckState?
    let approvers: [String]          // logins who approved
    let changeRequesters: [String]   // logins who requested changes
    let pendingReviewers: [String]   // requested but not yet reviewed
    let baseBranch: String?
    let additions: Int?
    let deletions: Int?
    let labels: [String]
    let comments: Int?
    let updatedAt: String?           // ISO8601
    var relations: Set<PRRelation> = []

    var isMine: Bool { relations.contains(.authored) }
    var isReview: Bool { relations.contains(.reviewDirect) || relations.contains(.reviewTeam) }

    /// Display reference: "#123" on GitHub, "!123" on GitLab.
    var ref: String { provider == .gitlab ? "!\(number)" : "#\(number)" }

    /// The single worst-status glyph for compact displays.
    var glyph: String {
        if ciState?.isFailure == true || mergeable == .conflicting { return "❌" }
        if ciState == .success && reviewDecision == .approved { return "✅" }
        if ciState == nil || ciState == .pending || ciState == .expected { return "🟡" }
        return "✅"
    }
}

/// The subset of per-PR state we diff between polls to decide notifications.
struct SnapshotState: Codable, Equatable, Sendable {
    let ciState: CheckState?
    let reviewDecision: ReviewDecision?
    let mergeable: Mergeable

    init(ciState: CheckState?, reviewDecision: ReviewDecision?, mergeable: Mergeable) {
        self.ciState = ciState
        self.reviewDecision = reviewDecision
        self.mergeable = mergeable
    }

    init(_ pr: PullRequest) {
        self.init(ciState: pr.ciState, reviewDecision: pr.reviewDecision, mergeable: pr.mergeable)
    }
}

/// GitHub computes `mergeable` asynchronously, so it flaps to `UNKNOWN` between polls.
/// Treat `UNKNOWN` as "no new info" and carry the last known state forward, so a
/// CONFLICTING→UNKNOWN→CONFLICTING flap doesn't re-fire a conflict notification.
func resolvedMergeable(_ current: Mergeable, previous: Mergeable?) -> Mergeable {
    current == .unknown ? (previous ?? .unknown) : current
}
