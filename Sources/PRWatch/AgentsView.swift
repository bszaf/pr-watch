import SwiftUI

struct AgentsView: View {
    @Environment(AgentStore.self) private var agents

    var body: some View {
        if agents.sessions.isEmpty {
            ContentUnavailableView(
                "No agent sessions", systemImage: "sparkles",
                description: Text(agents.settings.watchAgents
                    ? "Claude Code sessions active in the last 24 hours show up here."
                    : "Turn on Settings → Projects → Track Claude Code sessions.")
            )
        } else {
            List(agents.sessions) { AgentRow(session: $0) }
                .listStyle(.inset)
        }
    }
}

struct AgentRow: View {
    let session: AgentSession
    @Environment(PRStore.self) private var store
    @Environment(ProjectStore.self) private var projects

    private var subtitle: String {
        [session.folder, session.branch].compactMap { $0 }.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 10) {
            AgentStateIcon(state: session.state).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.displayTitle).fontWeight(.medium).lineLimit(1)
                HStack(spacing: 4) {
                    Text(verbatim: subtitle)
                    Text("·")
                    Text(session.lastActivity, style: .relative)
                }
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if session.title != nil, let prompt = session.lastPrompt {
                    Text(prompt).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            Spacer()
            prChip
            Button {
                Task { await TerminalLauncher.focusOrOpen(tty: session.tty, path: session.cwd, settings: projects.settings) }
            } label: {
                Image(systemName: session.tty == nil ? "terminal" : "terminal.fill")
            }
            .buttonStyle(.borderless)
            .help(session.terminalHelp)
            .linkCursor()
            .contextMenu {
                Button("Reveal in Finder") {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: session.cwd)
                }
            }
        }
        .padding(.vertical, 2)
        .opacity(session.state == .inactive ? 0.55 : 1)
        .help(session.state.help)
    }

    @ViewBuilder private var prChip: some View {
        if let pr = store.pullRequests.first(where: session.works(on:)) {
            Button {
                if let url = URL(string: pr.url) { NSWorkspace.shared.open(url) }
            } label: {
                HStack(spacing: 4) {
                    StatusIcons(pr: pr)
                    Text(verbatim: pr.ref).font(.caption)
                }
            }
            .buttonStyle(.plain)
            .help("\(pr.repo) \(pr.ref) · \(pr.title)")
            .linkCursor()
        } else if let link = session.prLinks.last {
            // A linked PR outside the watched set (closed, merged, or another repo).
            Button {
                if let url = URL(string: link.url) { NSWorkspace.shared.open(url) }
            } label: {
                Text(verbatim: "#\(link.number)")
            }
            .buttonStyle(.link).font(.caption)
            .help(link.url)
            .linkCursor()
        }
    }
}

struct AgentStateIcon: View {
    let state: AgentState

    var body: some View {
        Image(systemName: state.symbol)
            .foregroundStyle(state.color)
            .font(.system(size: 14))
            .symbolEffect(.pulse, isActive: state == .working)
            .help(state.help)
    }
}

/// Compact capsule for PR rows that have an agent on them.
struct AgentStateBadge: View {
    let state: AgentState

    var body: some View {
        Label("agent: \(state.label.lowercased())", systemImage: state.symbol)
            .labelStyle(.titleAndIcon).font(.caption2)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(state.color.opacity(0.18), in: Capsule())
            .foregroundStyle(state.color)
    }
}

extension AgentState {
    var color: Color {
        switch self {
        case .waiting: .orange
        case .idle: .green
        case .working: .blue
        case .inactive: .secondary
        }
    }
}
