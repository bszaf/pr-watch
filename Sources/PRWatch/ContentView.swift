import SwiftUI

struct ContentView: View {
    @Environment(PRStore.self) private var store
    @Environment(ProjectStore.self) private var projects
    @Environment(\.openSettings) private var openSettings
    @State private var tab: Tab = .mine
    @State private var showFilters = false

    enum Tab: String, CaseIterable, Identifiable {
        case mine = "My PRs"
        case others = "Other PRs"
        case activity = "Activity"
        case projects = "Projects"
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                tabContent
                Divider()
                footer
            }
            .navigationTitle("PR Watch")
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("View", selection: $tab) {
                        ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(minWidth: 340)
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    if tab == .activity && !store.activity.isEmpty {
                        Button { store.clearActivity() } label: {
                            Label("Clear activity", systemImage: "trash")
                        }
                        .help("Clear the activity history")
                    }
                    filterButton
                    Button { openSettings() } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                    .help("Settings")
                }
            }
        }
    }

    /// Bottom status bar: poll countdown + refresh, kept out of the titlebar.
    private var footer: some View {
        HStack(spacing: 10) {
            Spacer()
            countdown
            Button {
                Task { await store.refresh() }
                Task { await projects.scan() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(store.isRefreshing)
            .help("Refresh now")
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(.bar)
    }

    @ViewBuilder private var tabContent: some View {
        switch tab {
        case .mine: prList(store.pullRequests.filter { store.isMine($0) }, emptyLabel: "No PRs of yours")
        case .others: prList(store.pullRequests.filter { !store.isMine($0) }, emptyLabel: "No PRs to review")
        case .activity: ActivityView()
        case .projects: ProjectsView()
        }
    }

    @ViewBuilder private func prList(_ prs: [PullRequest], emptyLabel: String) -> some View {
        if let error = store.lastError, store.pullRequests.isEmpty {
            ContentUnavailableView {
                Label("Can't load PRs", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            }
        } else if prs.isEmpty {
            ContentUnavailableView(emptyLabel, systemImage: "checkmark.circle",
                                   description: Text("Nothing to show here right now."))
        } else {
            // ScrollView + LazyVStack (not List) so expanding a row animates its height
            // smoothly — List doesn't animate variable row heights and flickers.
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(prs) { pr in
                        PRRow(pr: pr).padding(.horizontal, 12)
                        Divider()
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var countdown: some View {
        Group {
            if store.isRefreshing {
                Text("refreshing…")
            } else if let next = store.nextPollDate {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    let secs = max(0, Int(next.timeIntervalSince(ctx.date).rounded()))
                    Text(verbatim: "next in \(secs)s").monospacedDigit()
                }
            }
        }
        .font(.caption).foregroundStyle(.secondary)
        .padding(.leading, 8)
        .help("Time until the next automatic refresh")
    }

    private var filterButton: some View {
        Button {
            showFilters.toggle()
        } label: {
            Label("Watched PRs", systemImage: hasFilter ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
        .help("Watched PRs")
        .popover(isPresented: $showFilters, arrowEdge: .bottom) {
            FilterPopover().frame(width: 340)
        }
    }

    private var hasFilter: Bool {
        !store.settings.customPRs.isEmpty
    }
}

/// Repo scoping + individually-watched PRs, tucked into a toolbar popover.
struct FilterPopover: View {
    @Environment(PRStore.self) private var store
    @State private var newPR = ""

    var body: some View {
        @Bindable var settings = store.settings

        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Watch a specific PR").font(.subheadline).bold()
                HStack {
                    TextField("URL or owner/repo#123", text: $newPR)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(add)
                    Button("Add", action: add)
                        .disabled(GitHubClient.normalizePR(newPR) == nil)
                }
                if settings.customPRs.isEmpty {
                    Text("Watched PRs appear under “Other PRs.”")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(settings.customPRs, id: \.self) { pr in
                        HStack {
                            Image(systemName: "eye").foregroundStyle(.secondary).font(.caption)
                            Text(pr).font(.caption)
                            Spacer()
                            Button {
                                settings.customPRs.removeAll { $0 == pr }
                                Task { await store.refresh() }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                            .help("Stop watching")
                        }
                    }
                }
            }
        }
        .padding(14)
        // Re-fetch when the popover closes so filter edits always take effect.
        .onDisappear { Task { await store.refresh() } }
    }

    private func add() {
        guard let normalized = GitHubClient.normalizePR(newPR) else { return }
        if !store.settings.customPRs.contains(normalized) {
            store.settings.customPRs.append(normalized)
        }
        newPR = ""
        Task { await store.refresh() }
    }
}

/// The real Finder icon for a path (consistent folder representation everywhere).
struct FolderIcon: View {
    let path: String
    var size: CGFloat = 16
    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: path))
            .resizable().frame(width: size, height: size)
    }
}

struct ProjectsView: View {
    @Environment(ProjectStore.self) private var projects

    // Honor the repository filter (Settings → Repositories); empty = all.
    private var shown: [LocalProject] {
        let filters = projects.settings.repoFilters
        guard !filters.isEmpty else { return projects.projects }
        return projects.projects.filter { $0.repo.map(filters.contains) ?? false }
    }

    var body: some View {
        Group {
            if shown.isEmpty {
                ContentUnavailableView(
                    projects.isScanning ? "Scanning…" : "No projects found",
                    systemImage: "folder",
                    description: Text("Add folders to scan in Settings → General → Project folders.")
                )
            } else {
                List(shown) { ProjectRow(project: $0) }
                    .listStyle(.inset)
            }
        }
        .task { await projects.scan() }
    }
}

struct ProjectRow: View {
    let project: LocalProject
    @Environment(PRStore.self) private var store

    private var matchedPR: PullRequest? {
        store.pullRequests.first { $0.repo == project.repo && $0.headBranch == project.branch }
    }

    var body: some View {
        HStack(spacing: 10) {
            FolderIcon(path: project.path)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(project.name).fontWeight(.medium)
                    if let branch = project.branch {
                        Label(branch, systemImage: "arrow.triangle.branch")
                            .labelStyle(.titleAndIcon).font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.secondary.opacity(0.15), in: Capsule())
                    }
                }
                Text(verbatim: project.repo ?? project.path)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if let pr = matchedPR {
                Button {
                    if let url = URL(string: pr.url) { NSWorkspace.shared.open(url) }
                } label: {
                    Label(pr.ref, systemImage: "arrow.triangle.pull")
                        .labelStyle(.titleAndIcon).font(.caption).lineLimit(1)
                }
                .buttonStyle(.plain).foregroundStyle(.green)
                .help("Open PR: \(pr.title)")
            }
            Button {
                TerminalLauncher.open(path: project.path, settings: store.settings)
            } label: {
                Image(systemName: "terminal")
            }
            .buttonStyle(.borderless)
            .help("Open in terminal")
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button("Open in Terminal") { TerminalLauncher.open(path: project.path, settings: store.settings) }
            Button("Reveal in Finder") {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: project.path)
            }
        }
    }
}

struct ActivityView: View {
    @Environment(PRStore.self) private var store

    var body: some View {
        if store.activity.isEmpty {
            ContentUnavailableView(
                "No activity yet", systemImage: "clock.arrow.circlepath",
                description: Text("CI results, reviews, and merge-conflict changes on your PRs will show up here.")
            )
        } else {
            List(store.activity) { ActivityRow(event: $0) }
                .listStyle(.inset)
        }
    }
}

struct ActivityRow: View {
    let event: ActivityEvent

    var body: some View {
        Button {
            if let url = URL(string: event.url) { NSWorkspace.shared.open(url) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: event.kind.symbol)
                    .foregroundStyle(color).font(.system(size: 14)).frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(event.kind.label).fontWeight(.medium)
                    Text(verbatim: "\(event.repo) \(event.ref ?? "#\(event.number)") · \(event.title)")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Text(event.date, style: .relative).font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var color: Color {
        switch event.kind {
        case .ciPassed, .approved: .green
        case .ciFailed: .red
        case .changesRequested, .conflict: .orange
        case .reviewRequested: .secondary
        }
    }
}

struct PRRow: View {
    let pr: PullRequest
    @Environment(ProjectStore.self) private var projects
    @State private var expanded = false

    private var subtitle: String {
        let base = "\(pr.repo) \(pr.ref)"
        return pr.author.isEmpty ? base : "\(base) · @\(pr.author)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if expanded {
                PRDetail(pr: pr)
                    .padding(.leading, 26).padding(.top, 6).padding(.bottom, 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(.vertical, 2)
        .clipped()   // reveal the detail downward from the header, no overshoot flicker
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "chevron.right")
                .font(.caption2).foregroundStyle(.secondary)
                .rotationEffect(.degrees(expanded ? 90 : 0))
                .frame(width: 10)
            StatusIcons(pr: pr)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(pr.title).lineLimit(1)
                    if pr.isDraft {
                        Text("Draft").font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.secondary.opacity(0.2), in: Capsule())
                            .help("This PR is a draft")
                    }
                }
                Text(verbatim: subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let project = projects.project(for: pr) {
                Button {
                    TerminalLauncher.open(path: project.path, settings: projects.settings)
                } label: {
                    Label(project.name, systemImage: "terminal")
                        .labelStyle(.titleAndIcon).font(.caption).lineLimit(1)
                }
                .buttonStyle(.plain).foregroundStyle(.blue)
                .help("Open worktree in terminal: \(project.path)")
                .contextMenu {
                    Button("Open in Terminal") { TerminalLauncher.open(path: project.path, settings: projects.settings) }
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: project.path)
                    }
                }
            }
            Button {
                if let url = URL(string: pr.url) { NSWorkspace.shared.open(url) }
            } label: {
                Image(systemName: "arrow.up.forward.square")
            }
            .buttonStyle(.borderless)
            .help("Open on GitHub")
        }
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() } }
    }
}

/// Expanded detail for a PR: reviewers, metadata, and local worktree + actions.
struct PRDetail: View {
    let pr: PullRequest
    @Environment(ProjectStore.self) private var projects

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            reviews
            metadata
            local
        }
        .font(.caption)
    }

    @ViewBuilder private var reviews: some View {
        if pr.approvers.isEmpty && pr.changeRequesters.isEmpty && pr.pendingReviewers.isEmpty {
            line("person.2", "No reviews yet", .secondary)
        } else {
            if !pr.approvers.isEmpty { line("checkmark.seal.fill", "Approved · " + names(pr.approvers), .green) }
            if !pr.changeRequesters.isEmpty { line("hand.raised.fill", "Changes · " + names(pr.changeRequesters), .orange) }
            if !pr.pendingReviewers.isEmpty { line("clock.fill", "Pending · " + names(pr.pendingReviewers), .secondary) }
        }
    }

    @ViewBuilder private var metadata: some View {
        if let base = pr.baseBranch {
            line("arrow.triangle.branch", "\(base) ← \(pr.headBranch ?? "?")" + diffStat, .secondary)
        }
        if !pr.labels.isEmpty {
            line("tag", pr.labels.joined(separator: ", "), .secondary)
        }
        if pr.updatedAt != nil || pr.comments != nil {
            line("clock.arrow.circlepath", metaFooter, .secondary)
        }
    }

    @ViewBuilder private var local: some View {
        if let project = projects.project(for: pr) {
            HStack(spacing: 8) {
                Image(systemName: "folder.fill").foregroundStyle(.blue)
                Text(project.path).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                Button("Terminal") { TerminalLauncher.open(path: project.path, settings: projects.settings) }
                Button("Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: project.path) }
            }
            .buttonStyle(.link)
        }
    }

    private func line(_ symbol: String, _ text: String, _ color: Color) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: symbol).foregroundStyle(color).frame(width: 14)
            Text(text).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }

    private func names(_ logins: [String]) -> String { logins.map { "@\($0)" }.joined(separator: ", ") }

    private var diffStat: String {
        guard let a = pr.additions, let d = pr.deletions else { return "" }
        return "  +\(a) −\(d)"
    }

    private var metaFooter: String {
        var parts: [String] = []
        if let updated = pr.updatedAt, let date = ISO8601DateFormatter().date(from: updated) {
            parts.append("updated \(relative(date))")
        }
        if let c = pr.comments, c > 0 { parts.append("\(c) comment\(c == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }

    private func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }
}

/// CI / review / mergeable status shown as SF Symbols, each with a hover tooltip.
struct StatusIcons: View {
    let pr: PullRequest

    // Fixed-width slots so CI / review / conflict icons line up in columns across rows.
    var body: some View {
        HStack(spacing: 4) {
            slot { icon(ciSymbol, ciColor).help(ciHelp) }
            slot {
                if let review = pr.reviewDecision {
                    icon(reviewSymbol(review), reviewColor(review)).help(reviewHelp(review))
                }
            }
            slot {
                if pr.mergeable == .conflicting {
                    icon("exclamationmark.triangle.fill", .orange)
                        .help("Merge conflict — this branch needs a rebase/merge before it can land")
                }
            }
        }
    }

    // A sized transparent base holds the column open even when the icon is absent.
    private func slot<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        Color.clear.frame(width: 16, height: 16).overlay { content() }
    }

    private func icon(_ name: String, _ color: Color) -> some View {
        Image(systemName: name).foregroundStyle(color).font(.system(size: 13))
    }

    private var ciSymbol: String {
        switch pr.ciState {
        case .success: "checkmark.circle.fill"
        case .failure, .error: "xmark.circle.fill"
        case .pending, .expected: "clock.fill"
        case nil: "circle.dashed"
        }
    }
    private var ciColor: Color {
        switch pr.ciState {
        case .success: .green
        case .failure, .error: .red
        case .pending, .expected: .yellow
        case nil: .secondary
        }
    }
    private var ciHelp: String {
        switch pr.ciState {
        case .success: "CI checks passed"
        case .failure, .error: "CI checks failed"
        case .pending, .expected: "CI checks are still running"
        case nil: "No CI checks on this PR"
        }
    }

    private func reviewSymbol(_ d: ReviewDecision) -> String {
        switch d {
        case .approved: "hand.thumbsup.fill"
        case .changesRequested: "hand.raised.fill"
        case .reviewRequired: "eye.fill"
        }
    }
    private func reviewColor(_ d: ReviewDecision) -> Color {
        switch d {
        case .approved: .green
        case .changesRequested: .orange
        case .reviewRequired: .secondary
        }
    }
    private func reviewHelp(_ d: ReviewDecision) -> String {
        switch d {
        case .approved: "Review: approved"
        case .changesRequested: "Review: changes requested"
        case .reviewRequired: "Review: awaiting review (not yet reviewed)"
        }
    }
}
