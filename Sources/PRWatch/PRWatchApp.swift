import SwiftUI
import UserNotifications

@main
struct PRWatchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store: PRStore
    @State private var projects: ProjectStore

    init() {
        let settings = AppSettings()
        _store = State(initialValue: PRStore(settings: settings))
        _projects = State(initialValue: ProjectStore(settings: settings))
    }

    var body: some Scene {
        WindowGroup("PR Watch", id: "PR Watch") {
            ContentView()
                .environment(store)
                .environment(projects)
                // Min width keeps the titlebar segmented tabs from collapsing into overflow.
                .frame(minWidth: 760, idealWidth: 860, minHeight: 520, idealHeight: 680)
                .task { store.start() }
                .task { await projects.scan() }
        }
        .windowResizability(.contentMinSize)

        MenuBarExtra {
            MenuBarView()
                .environment(store)
        } label: {
            Label(menuBarCount, systemImage: "checklist")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(store)
                .environment(projects)
        }
    }

    private var menuBarCount: String {
        let n = store.pullRequests.count
        return n == 0 ? "" : "\(n)"
    }
}

/// Owns UNUserNotifications setup + click handling (opens the PR in the browser).
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            Notifier.useUserNotifications = granted
        }
    }

    // Show banners even while the app is frontmost.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    // Clicking a banner opens the PR.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if let urlString = response.notification.request.content.userInfo["url"] as? String,
           let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
        completionHandler()
    }
}
