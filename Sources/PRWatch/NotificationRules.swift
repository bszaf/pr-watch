import Foundation

/// Which triggers are enabled — mirrors the AppSettings toggles.
struct Triggers: Sendable {
    var ci: Bool
    var review: Bool
    var conflicts: Bool
    var comments: Bool
}

struct PendingNotification: Equatable, Sendable {
    let title: String
    let body: String
}

/// All state transitions since `previous` (nil = first sighting → none), independent of
/// which triggers are enabled. Kept pure so it's directly testable. The activity feed
/// records every transition; banners are the enabled subset.
func transitions(for pr: PullRequest, previous: SnapshotState?) -> [ActivityKind] {
    guard let previous else { return [] }
    var out: [ActivityKind] = []

    if let ci = pr.ciState, ci.isTerminal, ci != previous.ciState {
        out.append(ci == .success ? .ciPassed : .ciFailed)
    }
    if pr.reviewDecision != previous.reviewDecision, let decision = pr.reviewDecision {
        switch decision {
        case .approved: out.append(.approved)
        case .changesRequested: out.append(.changesRequested)
        case .reviewRequired: out.append(.reviewRequested)
        }
    }
    if pr.mergeable == .conflicting, previous.mergeable != .conflicting {
        out.append(.conflict)
    }
    // A new unresolved comment now awaits my reply (grew since last poll). A nil
    // previous count (pre-upgrade snapshot) is unknown, not zero — never spam on it.
    if let prevAwaiting = previous.awaitingReply, pr.awaitingMyReply > prevAwaiting {
        out.append(.commentAwaitingReply)
    }
    return out
}

/// The snapshot to diff the next poll against. Entries of providers whose fetch failed are
/// carried over: a failed cold-start poll returns no PRs, and dropping their entries would
/// turn every change made while the app was off into a silent first sighting.
func nextSnapshot(_ prs: [PullRequest], previous: [String: SnapshotState],
                  keeping failed: Set<Provider>) -> [String: SnapshotState] {
    var out = previous.filter { id, _ in failed.contains { id.hasPrefix("\($0.rawValue):") } }
    for pr in prs {
        out[pr.id] = SnapshotState(
            ciState: pr.ciState, reviewDecision: pr.reviewDecision,
            mergeable: resolvedMergeable(pr.mergeable, previous: previous[pr.id]?.mergeable),
            awaitingReply: pr.awaitingMyReply)
    }
    return out
}

/// When an event happened. CI and mergeability change without bumping the PR's
/// `updatedAt`, so only review/comment events can be backdated to it.
func eventDate(for kind: ActivityKind, updatedAt: String?, now: Date) -> Date {
    switch kind {
    case .ciPassed, .ciFailed, .conflict:
        return now
    case .approved, .changesRequested, .reviewRequested, .commentAwaitingReply:
        return updatedAt.flatMap(parseISODate) ?? now
    }
}

func isEnabled(_ kind: ActivityKind, _ triggers: Triggers) -> Bool {
    switch kind {
    case .ciPassed, .ciFailed: triggers.ci
    case .approved, .changesRequested, .reviewRequested: triggers.review
    case .conflict: triggers.conflicts
    case .commentAwaitingReply: triggers.comments
    }
}

func notification(for kind: ActivityKind, pr: PullRequest) -> PendingNotification {
    let tag = "\(shortRepo(pr.repo)) \(pr.ref)"
    let title: String
    switch kind {
    case .ciPassed: title = "✅ CI passed — \(tag)"
    case .ciFailed: title = "❌ CI failed — \(tag)"
    case .approved: title = "👍 Approved\(by(pr.approvers)) — \(tag)"
    case .changesRequested: title = "✋ Changes requested\(by(pr.changeRequesters)) — \(tag)"
    case .reviewRequested: title = "👀 Review requested — \(tag)"
    case .conflict: title = "⚠️ Merge conflict — \(tag)"
    case .commentAwaitingReply: title = "💬 Comment awaiting your reply — \(tag)"
    }
    let body = pr.author.isEmpty ? pr.title : "@\(pr.author) · \(pr.title)"
    return PendingNotification(title: title, body: body)
}

/// Convenience used by tests and banner-only callers: enabled transitions as banners.
func notifications(for pr: PullRequest, previous: SnapshotState?, triggers: Triggers) -> [PendingNotification] {
    transitions(for: pr, previous: previous)
        .filter { isEnabled($0, triggers) }
        .map { notification(for: $0, pr: pr) }
}

/// " by @alice, @bob" for the reviewers, or "" if unknown.
private func by(_ logins: [String]) -> String {
    logins.isEmpty ? "" : " by " + logins.map { "@\($0)" }.joined(separator: ", ")
}

/// "Acme/app" -> "app" for compact tags.
func shortRepo(_ full: String) -> String {
    full.split(separator: "/").last.map(String.init) ?? full
}
