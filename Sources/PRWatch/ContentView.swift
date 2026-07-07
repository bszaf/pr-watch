import SwiftUI

struct ContentView: View {
    @Environment(PRStore.self) private var store
    @State private var tab: Tab = .mine
    @State private var showFilters = false

    enum Tab: String, CaseIterable, Identifiable {
        case mine = "My PRs"
        case others = "Other PRs"
        case activity = "Activity"
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            tabContent
                .navigationTitle("PR Watch")
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        Picker("View", selection: $tab) {
                            ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .frame(minWidth: 280)
                    }
                    ToolbarItemGroup(placement: .primaryAction) {
                        if tab == .activity && !store.activity.isEmpty {
                            Button("Clear") { store.clearActivity() }
                                .help("Clear the activity history")
                        }
                        countdown
                        filterButton
                        Button {
                            Task { await store.refresh() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .disabled(store.isRefreshing)
                        .help("Refresh now")
                    }
                }
        }
    }

    @ViewBuilder private var tabContent: some View {
        switch tab {
        case .mine: prList(store.pullRequests.filter { store.isMine($0) }, emptyLabel: "No PRs of yours")
        case .others: prList(store.pullRequests.filter { !store.isMine($0) }, emptyLabel: "No PRs to review")
        case .activity: ActivityView()
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
            List(prs) { PRRow(pr: $0) }
                .listStyle(.inset)
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
        .help("Time until the next automatic refresh")
    }

    private var filterButton: some View {
        Button {
            showFilters.toggle()
        } label: {
            Image(systemName: hasFilter ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
        .help("Repo filter & watched PRs")
        .popover(isPresented: $showFilters, arrowEdge: .bottom) {
            FilterPopover().frame(width: 340)
        }
    }

    private var hasFilter: Bool {
        !store.settings.repoFilter.isEmpty || !store.settings.customPRs.isEmpty
    }
}

/// Repo scoping + individually-watched PRs, tucked into a toolbar popover.
struct FilterPopover: View {
    @Environment(PRStore.self) private var store
    @State private var newPR = ""

    var body: some View {
        @Bindable var settings = store.settings

        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Limit to repository").font(.subheadline).bold()
                TextField("owner/name (blank = all)", text: $settings.repoFilter)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await store.refresh() } }
            }

            Divider()

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
                    Text(verbatim: "\(event.repo) #\(event.number) · \(event.title)")
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

    private var subtitle: String {
        let base = "\(pr.repo) #\(pr.number)"
        return pr.author.isEmpty ? base : "\(base) · @\(pr.author)"
    }

    var body: some View {
        HStack(spacing: 10) {
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
            Button {
                if let url = URL(string: pr.url) { NSWorkspace.shared.open(url) }
            } label: {
                Image(systemName: "arrow.up.forward.square")
            }
            .buttonStyle(.borderless)
            .help("Open on GitHub")
        }
        .padding(.vertical, 2)
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
