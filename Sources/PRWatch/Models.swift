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
    var ciState: CheckState?
    let approvers: [String]          // logins who approved
    let changeRequesters: [String]   // logins who requested changes
    let pendingReviewers: [String]   // requested but not yet reviewed
    let baseBranch: String?
    let additions: Int?
    let deletions: Int?
    let labels: [String]
    let comments: Int?
    let updatedAt: String?           // ISO8601
    var commentedReviewers: [String] = []   // left a comment-only review (GitHub)
    var unresolvedThreads: Int = 0          // open review conversations
    var awaitingMyReply: Int = 0            // unresolved & last comment isn't mine (or a bot)
    var relations: Set<PRRelation> = []
    /// Individual checks of the head commit; fetched only while CI is failing (GitHub).
    var checks: [CICheck] = []
    var checksComplete = true               // false when the list was cut off at the fetch cap
    var ignoredFailures: [CICheck] = []     // failing checks discounted from `ciState` by settings

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

/// One CI check (a check run or a commit status) of a PR's head commit.
struct CICheck: Sendable, Equatable, Hashable {
    let name: String
    let state: CheckState      // only .success / .failure / .pending
    var summary: String? = nil
    var url: String? = nil
}

extension PullRequest {
    /// This PR with `ignored` check names' failures discounted from `ciState`. Without the full
    /// check list (not fetched, or cut off) the reported state stands.
    func applyingIgnoredChecks(_ ignored: Set<String>) -> PullRequest {
        var pr = self
        let failing = checks.filter { $0.state.isFailure }
        pr.ignoredFailures = failing.filter { ignored.contains($0.name) }
        guard ciState?.isFailure == true, checksComplete, !pr.ignoredFailures.isEmpty,
              pr.ignoredFailures.count == failing.count else { return pr }
        pr.ciState = checks.contains { $0.state == .pending && !ignored.contains($0.name) } ? .pending : .success
        return pr
    }
}

/// The subset of per-PR state we diff between polls to decide notifications.
struct SnapshotState: Codable, Equatable, Sendable {
    let ciState: CheckState?
    let reviewDecision: ReviewDecision?
    let mergeable: Mergeable
    var awaitingReply: Int?          // optional so older persisted snapshots still decode

    init(ciState: CheckState?, reviewDecision: ReviewDecision?, mergeable: Mergeable, awaitingReply: Int? = 0) {
        self.ciState = ciState
        self.reviewDecision = reviewDecision
        self.mergeable = mergeable
        self.awaitingReply = awaitingReply
    }

    init(_ pr: PullRequest) {
        self.init(ciState: pr.ciState, reviewDecision: pr.reviewDecision,
                  mergeable: pr.mergeable, awaitingReply: pr.awaitingMyReply)
    }
}

/// GitHub timestamps are plain ISO8601; GitLab's can carry fractional seconds.
private let isoPlain = ISO8601DateFormatter()
private let isoFractional: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

func parseISODate(_ s: String) -> Date? {
    isoPlain.date(from: s) ?? isoFractional.date(from: s)
}

/// An unresolved thread "awaits my reply" only if I'm part of the conversation — it's on
/// my PR or I opened the thread — and the last word isn't mine (or a bot's).
func threadAwaitsReply(viewer: String?, prAuthor: String?, firstAuthor: String?,
                       lastAuthor: String?, lastIsBot: Bool) -> Bool {
    guard let viewer, let lastAuthor, !lastIsBot, lastAuthor != viewer else { return false }
    return prAuthor == viewer || firstAuthor == viewer
}

/// GitHub computes `mergeable` asynchronously, so it flaps to `UNKNOWN` between polls.
/// Treat `UNKNOWN` as "no new info" and carry the last known state forward, so a
/// CONFLICTING→UNKNOWN→CONFLICTING flap doesn't re-fire a conflict notification.
func resolvedMergeable(_ current: Mergeable, previous: Mergeable?) -> Mergeable {
    current == .unknown ? (previous ?? .unknown) : current
}
