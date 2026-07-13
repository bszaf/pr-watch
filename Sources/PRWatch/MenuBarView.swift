import SwiftUI

struct MenuBarView: View {
    @Environment(PRStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("PR Watch").font(.headline)
                Spacer()
                if store.isRefreshing { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 6)

            Divider()

            if let error = store.lastError, store.pullRequests.isEmpty {
                Text(error).font(.caption).foregroundStyle(.secondary)
                    .padding(12).frame(maxWidth: 320, alignment: .leading)
            } else if store.pullRequests.isEmpty {
                Text("No open PRs").foregroundStyle(.secondary).padding(12)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(store.pullRequests) { pr in
                            Button {
                                if let url = URL(string: pr.url) { NSWorkspace.shared.open(url) }
                                dismiss()
                            } label: {
                                HStack(spacing: 8) {
                                    Text(pr.glyph)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(pr.title).lineLimit(1)
                                        Text(verbatim: "\(pr.repo) \(pr.ref)").font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                }
                                .padding(.horizontal, 12).padding(.vertical, 5)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(MenuRowButtonStyle())
                            .linkCursor()
                        }
                    }
                }
                .frame(minHeight: 240, maxHeight: 420)
            }

            Divider()

            VStack(spacing: 2) {
                menuButton("Refresh", "arrow.clockwise") { Task { await store.refresh() } }
                menuButton("Open Window", "macwindow") {
                    openWindow(id: "PR Watch")
                    NSApp.activate(ignoringOtherApps: true)
                    dismiss()
                }
                menuButton("Settings…", "gearshape") {
                    openSettings()
                    dismiss()
                }
                Divider().padding(.vertical, 2)
                menuButton("Quit PR Watch", "power") { NSApp.terminate(nil) }
            }
            .padding(.horizontal, 6).padding(.vertical, 6)
        }
        .frame(width: 340)
    }

    private func menuButton(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(MenuRowButtonStyle())
    }
}

/// A menu-item button style that highlights on hover — the popover (`.window`) menu-bar
/// style doesn't get the native menu's automatic hover selection.
private struct MenuRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Row(configuration: configuration)
    }

    private struct Row: View {
        let configuration: Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.primary.opacity(configuration.isPressed ? 0.16 : hovering ? 0.09 : 0))
                        .padding(.horizontal, 5)
                )
                .onHover { hovering = $0 }
        }
    }
}
