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

struct PullRequest: Identifiable, Sendable, Equatable {
    let id: String            // "owner/repo#number"
    let number: Int
    let title: String
    let url: String
    let isDraft: Bool
    let repo: String          // owner/repo
    let author: String
    let reviewDecision: ReviewDecision?
    let mergeable: Mergeable
    let ciState: CheckState?

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

    init(_ pr: PullRequest) {
        ciState = pr.ciState
        reviewDecision = pr.reviewDecision
        mergeable = pr.mergeable
    }
}
