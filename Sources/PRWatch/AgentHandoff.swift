import AppKit

extension PullRequest {
    /// Something an agent can act on: red CI, a conflict, or review feedback.
    var needsAgent: Bool {
        ciState?.isFailure == true || mergeable == .conflicting
            || reviewDecision == .changesRequested || awaitingMyReply > 0
    }
}

/// The task for an agent working on `pr`. Single-line: typed into a running session, a
/// newline would submit it early.
func agentPrompt(for pr: PullRequest) -> String {
    let gh = pr.provider == .github
    var tasks: [String] = []
    if pr.ciState?.isFailure == true {
        tasks.append(gh ? "CI is failing — find the failing checks with `gh pr checks \(pr.number)` and their logs, and fix them"
                        : "CI is failing — find the failing jobs with `glab ci status` and their logs, and fix them")
    }
    if pr.mergeable == .conflicting {
        tasks.append("it conflicts with \(pr.baseBranch ?? "the base branch") — rebase onto origin/\(pr.baseBranch ?? "main") and resolve the conflicts")
    }
    if pr.reviewDecision == .changesRequested || pr.awaitingMyReply > 0 {
        tasks.append(gh ? "address the unresolved review comments (`gh pr view \(pr.number) --comments` and the review threads) and reply to each"
                        : "address the unresolved review comments (`glab mr view \(pr.number) --comments`) and reply to each")
    }
    if tasks.isEmpty { tasks.append("check its status and continue the work") }
    let head = pr.headBranch.map { ", branch \($0)" } ?? ""
    let prompt = "PR \(pr.url) (\(pr.repo) \(pr.ref)\(head)): \(tasks.joined(separator: "; ")). Commit and push when done."
    return prompt.replacingOccurrences(of: "\n", with: " ")
}

func agentPrompt(for project: LocalProject) -> String {
    "Branch \(project.branch ?? "?") has no PR yet: review what's done, finish the work, commit, push, and open a PR."
}

/// The shell command that starts an agent: `{prompt}` in `template` becomes the quoted prompt
/// (appended when the template has no placeholder).
func agentCommandLine(template: String, prompt: String) -> String {
    let quoted = shellQuote(prompt)
    let t = template.trimmingCharacters(in: .whitespaces)
    return t.contains("{prompt}") ? t.replacingOccurrences(of: "{prompt}", with: quoted) : "\(t) \(quoted)"
}

/// Where a handoff goes, decided before touching any terminal.
enum HandoffPlan: Equatable {
    case type(tty: String)       // type into the idle session, falling back to `.focus`
    case focus(tty: String)      // switch to the busy session; prompt goes to the clipboard
    case start(dir: String)      // start a new agent
    case none

    /// Only an idle session is typed into: one asking for permission would take the prompt
    /// as its answer.
    init(session: AgentSession?, path: String?) {
        if let session, let tty = session.tty {
            self = session.state == .idle ? .type(tty: tty) : .focus(tty: tty)
        } else if let dir = path ?? session?.cwd {
            self = .start(dir: dir)
        } else {
            self = .none
        }
    }
}

@MainActor
enum AgentHandoff {
    /// Hand `prompt` to an agent per `HandoffPlan`. Typing is iTerm2-only; when it or the
    /// switch fails, a new agent starts in `path` (or the session's folder).
    static func send(prompt: String, session: AgentSession?, path: String?, settings: AppSettings) async {
        var plan = HandoffPlan(session: session, path: path)
        if case .type(let tty) = plan {
            if await TerminalLauncher.focus(tty: tty, typing: prompt) { return }
            plan = .focus(tty: tty)
        }
        if case .focus(let tty) = plan {
            copy(prompt)
            if await TerminalLauncher.focus(tty: tty) {
                Notifier.notify(title: "Prompt copied", body: "Switched to the agent — paste the prompt when it's ready.")
                return
            }
            plan = HandoffPlan(session: nil, path: path ?? session?.cwd)
        }
        guard case .start(let dir) = plan else { return }
        let command = agentCommandLine(template: settings.agentCommand, prompt: prompt)
        if !TerminalLauncher.open(path: dir, settings: settings, command: command) {
            copy(prompt)
            Notifier.notify(title: "Prompt copied", body: "Paste it into your agent in \(dir).")
        }
    }

    private static func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}
