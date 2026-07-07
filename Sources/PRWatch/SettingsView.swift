import SwiftUI

struct SettingsView: View {
    @Environment(PRStore.self) private var store
    @State private var patInput = ""
    @State private var patStatus = ""

    var body: some View {
        @Bindable var settings = store.settings

        Form {
            Section("Notifications") {
                Toggle("CI checks finished", isOn: $settings.notifyCI)
                Toggle("Review activity", isOn: $settings.notifyReview)
                Toggle("Merge conflicts", isOn: $settings.notifyConflicts)
                HStack {
                    Button("Send test notification") {
                        Notifier.notify(title: "PR Watch — test", body: "Notifications are working ✅")
                    }
                    Text("Fires a banner right now to confirm delivery.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Watch scope") {
                Toggle("PRs I authored", isOn: $settings.watchAuthored)
                Toggle("PRs awaiting my review", isOn: $settings.watchReviewRequested)
                Text("Repo limit and individually-watched PRs live in the main window.")
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

            Section("GitHub token") {
                Text("Leave blank to reuse your `gh` CLI login. A pasted token is stored only in the macOS Keychain.")
                    .font(.caption).foregroundStyle(.secondary)
                SecureField("Personal access token", text: $patInput)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("Save token") {
                        Keychain.setToken(patInput.trimmingCharacters(in: .whitespaces))
                        patInput = ""
                        patStatus = "Saved to Keychain."
                        Task { await store.refresh() }
                    }
                    .disabled(patInput.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Clear token") {
                        Keychain.deleteToken()
                        patStatus = "Cleared — falling back to gh login."
                        Task { await store.refresh() }
                    }
                    if !patStatus.isEmpty {
                        Text(patStatus).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            Section("Startup") {
                Toggle("Launch at login", isOn: $settings.launchAtLogin)
                    .onChange(of: settings.launchAtLogin) { _, on in
                        if on {
                            if !LaunchAgent.install() {
                                settings.launchAtLogin = false
                                patStatus = "Run from the built .app bundle to enable launch at login."
                            }
                        } else {
                            LaunchAgent.uninstall()
                        }
                    }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }
}
