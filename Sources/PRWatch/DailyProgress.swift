import Foundation

/// Today's tally for the Activity header and the menu bar: what landed, and what's open.
struct DailyProgress: Equatable, Sendable {
    var merged = 0
    var closed = 0
    var openMine = 0
    var failingCI = 0
    var inReview = 0          // mine, ready (not draft), not yet approved
    var approved = 0
    var agentsWorking = 0
    var agentsNeedYou = 0     // may need you, or finished and waiting for the next prompt

    var hasActivity: Bool { merged + closed > 0 }
}

/// Merged/closed count only my PRs (`mine == true`) within `now`'s calendar day.
func dailyProgress(activity: [ActivityEvent], prs: [PullRequest], agents: [AgentSession],
                   now: Date, calendar: Calendar = .current) -> DailyProgress {
    var p = DailyProgress()
    for e in activity where e.mine == true && calendar.isDate(e.date, inSameDayAs: now) {
        if e.kind == .merged { p.merged += 1 }
        if e.kind == .closed { p.closed += 1 }
    }
    for pr in prs where pr.isMine {
        p.openMine += 1
        if pr.ciState?.isFailure == true { p.failingCI += 1 }
        if pr.reviewDecision == .approved { p.approved += 1 }
        else if !pr.isDraft { p.inReview += 1 }
    }
    for a in agents {
        switch a.state {
        case .working: p.agentsWorking += 1
        case .waiting, .idle: p.agentsNeedYou += 1
        case .inactive: break
        }
    }
    return p
}
