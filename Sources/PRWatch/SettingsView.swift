import SwiftUI
import AppKit

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            NotificationSettings()
                .tabItem { Label("Notifications", systemImage: "bell") }
            AccountSettings()
                .tabItem { Label("Accounts", systemImage: "person.crop.circle") }
        }
        .frame(width: 460)
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @Environment(PRStore.self) private var store
    @Environment(ProjectStore.self) private var projects
    @State private var launchMsg = ""
    @State private var newRepo = ""

    var body: some View {
        @Bindable var settings = store.settings
        Form {
            Section("Project folders") {
                Text("Scanned for local git projects, shown in the Projects tab.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(settings.scanRoots, id: \.self) { root in
                    HStack {
                        Image(systemName: "folder").foregroundStyle(.secondary)
                        Text(root).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button {
                            settings.scanRoots.removeAll { $0 == root }
                            Task { await projects.scan() }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                }
                Button("Add folder…", action: addFolder)
            }
            Section("Open projects in") {
                Picker("Terminal", selection: $settings.terminalApp) {
                    ForEach(TerminalApp.allCases) { Text($0.label).tag($0.rawValue) }
                }
                if settings.terminalApp == TerminalApp.custom.rawValue {
                    TextField("Command ({path} = project path)", text: $settings.customTerminalCommand)
                        .textFieldStyle(.roundedBorder)
                    Text("Example: open -a Ghostty {path}")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("Opening iTerm2/Terminal may prompt for Automation permission the first time.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Polling") {
                Picker("Check every", selection: $settings.pollInterval) {
                    Text("30 seconds").tag(30)
                    Text("1 minute").tag(60)
                    Text("2 minutes").tag(120)
                    Text("5 minutes").tag(300)
                }
                .onChange(of: settings.pollInterval) { store.restartTimer() }
            }
            Section("Watch scope") {
                Toggle("PRs I authored", isOn: $settings.watchAuthored)
                    .onChange(of: settings.watchAuthored) { Task { await store.refresh() } }
                Toggle("PRs awaiting my review", isOn: $settings.watchReviewRequested)
                    .onChange(of: settings.watchReviewRequested) { Task { await store.refresh() } }
                Text("Individually-watched PRs live in the main window's filter.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Repositories") {
                Text("Limit watching to these repos (owner/name). Empty = all repos.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(settings.repoFilters, id: \.self) { repo in
                    HStack {
                        Image(systemName: "shippingbox").foregroundStyle(.secondary)
                        Text(repo).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button {
                            settings.repoFilters.removeAll { $0 == repo }
                            Task { await store.refresh() }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    TextField("owner/name", text: $newRepo)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addRepo)
                    Button("Add", action: addRepo)
                        .disabled(newRepo.trimmingCharacters(in: .whitespaces).isEmpty)
                    if !repoSuggestions.isEmpty {
                        Menu {
                            ForEach(repoSuggestions, id: \.self) { repo in
                                Button(repo) { add(repo) }
                            }
                        } label: {
                            Image(systemName: "sparkles")
                        }
                        .menuStyle(.borderlessButton).fixedSize()
                        .help("Suggestions from local projects and open PRs")
                    }
                }
            }
            Section("Startup") {
                Toggle("Launch at login", isOn: $settings.launchAtLogin)
                    .onChange(of: settings.launchAtLogin) { _, on in
                        if on, !LaunchAgent.install() {
                            settings.launchAtLogin = false
                            launchMsg = "Run from the built .app bundle to enable launch at login."
                        } else if !on {
                            LaunchAgent.uninstall()
                        }
                    }
                if !launchMsg.isEmpty {
                    Text(launchMsg).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Distinct repos seen locally or in open PRs, minus ones already filtered.
    private var repoSuggestions: [String] {
        let current = Set(store.settings.repoFilters)
        let fromPRs = store.pullRequests.map(\.repo)
        let fromProjects = projects.projects.compactMap(\.repo)
        return Array(Set(fromPRs + fromProjects).subtracting(current)).sorted()
    }

    private func add(_ repo: String) {
        guard !store.settings.repoFilters.contains(repo) else { return }
        store.settings.repoFilters.append(repo)
        Task { await store.refresh() }
    }

    private func addRepo() {
        let repo = newRepo.trimmingCharacters(in: .whitespaces)
        guard !repo.isEmpty else { return }
        add(repo)
        newRepo = ""
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        let settings = store.settings
        for url in panel.urls where !settings.scanRoots.contains(url.path) {
            settings.scanRoots.append(url.path)
        }
        Task { await projects.scan() }
    }
}

// MARK: - Notifications

private struct NotificationSettings: View {
    @Environment(PRStore.self) private var store

    var body: some View {
        @Bindable var settings = store.settings
        Form {
            Section("Notify me when") {
                Toggle("CI checks finish", isOn: $settings.notifyCI)
                Toggle("Review activity happens", isOn: $settings.notifyReview)
                Toggle("A merge conflict appears", isOn: $settings.notifyConflicts)
            }
            Section("Test") {
                Button("Send test notification") {
                    Notifier.notify(title: "PR Watch — test", body: "Notifications are working ✅")
                }
                Text("Fires a banner right now to confirm delivery.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Accounts

private struct AccountSettings: View {
    @Environment(PRStore.self) private var store
    @State private var ghPAT = ""
    @State private var glPAT = ""
    @State private var statusMsg = ""

    var body: some View {
        @Bindable var settings = store.settings
        Form {
            Section("GitHub") {
                Toggle("Watch GitHub", isOn: $settings.watchGitHub)
                    .onChange(of: settings.watchGitHub) { Task { await store.refresh() } }
                statusLine(.github)
                SecureField("Personal access token (blank = use gh CLI)", text: $ghPAT)
                    .textFieldStyle(.roundedBorder)
                tokenButtons(provider: .github, input: $ghPAT, blankHint: "gh login")
            }
            Section("GitLab") {
                Toggle("Watch GitLab", isOn: $settings.watchGitLab)
                    .onChange(of: settings.watchGitLab) { Task { await store.refresh() } }
                statusLine(.gitlab)
                TextField("Host", text: $settings.gitlabHost)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await store.refresh() } }
                SecureField("Personal access token (read_api; blank = use glab)", text: $glPAT)
                    .textFieldStyle(.roundedBorder)
                tokenButtons(provider: .gitlab, input: $glPAT, blankHint: "glab / no CLI")
            }
            if !statusMsg.isEmpty {
                Section { Text(statusMsg).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private func statusLine(_ provider: Provider) -> some View {
        let status = store.providerStatus[provider]
        VStack(alignment: .leading, spacing: 2) {
            Text("Using: \(status?.summary(for: provider) ?? "\(provider.rawValue) — not checked")")
                .font(.caption).foregroundStyle(.secondary)
            if let error = status?.error {
                Text(error).font(.caption2).foregroundStyle(.red).lineLimit(2)
            }
        }
    }

    private func tokenButtons(provider: Provider, input: Binding<String>, blankHint: String) -> some View {
        HStack {
            Button("Save token") {
                Keychain.setToken(input.wrappedValue.trimmingCharacters(in: .whitespaces),
                                  account: provider.keychainAccount)
                input.wrappedValue = ""
                statusMsg = "\(provider.label) token saved to Keychain."
                Task { await store.refresh() }
            }
            .disabled(input.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Clear token") {
                Keychain.deleteToken(account: provider.keychainAccount)
                statusMsg = "\(provider.label) token cleared — falling back to \(blankHint)."
                Task { await store.refresh() }
            }
        }
    }
}
