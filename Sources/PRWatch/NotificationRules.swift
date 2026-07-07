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
    case .approved: title = "👍 Approved — \(tag)"
    case .changesRequested: title = "✋ Changes requested — \(tag)"
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

/// "RiverFinancial/alto" -> "alto" for compact tags.
func shortRepo(_ full: String) -> String {
    full.split(separator: "/").last.map(String.init) ?? full
}
