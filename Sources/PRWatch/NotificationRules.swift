import Foundation

/// Which triggers are enabled — mirrors the AppSettings toggles.
struct Triggers: Sendable {
    var ci: Bool
    var review: Bool
    var conflicts: Bool
}

struct PendingNotification: Equatable, Sendable {
    let title: String
    let body: String
}

/// All state transitions since `previous` (nil = first sighting), independent of
/// which triggers are enabled. Kept pure so it's directly testable. The activity feed
/// records every transition; banners are the enabled subset.
///
/// Role split:
/// - Authored PRs: CI / approval / changes-requested / conflicts.
/// - Reviewer-only PRs: first appearance = "you were asked to review" (no CI spam).
func transitions(for pr: PullRequest, previous: SnapshotState?) -> [ActivityKind] {
    // Newly appeared after the initial fetch: only notify reviewers that they were added.
    guard let previous else {
        return (pr.isReview && !pr.isMine) ? [.reviewRequested] : []
    }

    var out: [ActivityKind] = []

    if pr.isMine {
        if let ci = pr.ciState, ci.isTerminal, ci != previous.ciState {
            out.append(ci == .success ? .ciPassed : .ciFailed)
        }
        if pr.reviewDecision != previous.reviewDecision, let decision = pr.reviewDecision {
            switch decision {
            case .approved: out.append(.approved)
            case .changesRequested: out.append(.changesRequested)
            case .reviewRequired: break  // PR-level "needs review" ≠ "I was selected"
            }
        }
        if pr.mergeable == .conflicting, previous.mergeable != .conflicting {
            out.append(.conflict)
        }
    }

    return out
}

func isEnabled(_ kind: ActivityKind, _ triggers: Triggers) -> Bool {
    switch kind {
    case .ciPassed, .ciFailed: triggers.ci
    case .approved, .changesRequested, .reviewRequested: triggers.review
    case .conflict: triggers.conflicts
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
