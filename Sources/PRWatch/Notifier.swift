import Foundation
import UserNotifications
import AppKit

/// Posts notifications. Prefers `UNUserNotifications` (clickable — opens the PR in the
/// browser); falls back to `osascript` banners if the app isn't authorized/bundled for UN.
enum Notifier {
    /// Set true once UN authorization is granted (see `AppDelegate`).
    static var useUserNotifications = false

    static func notify(title: String, body: String, url: String? = nil) {
        if useUserNotifications {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            if let url { content.userInfo = ["url": url] }
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request)
        } else {
            osascript(title: title, body: body)
        }
    }

    private static func osascript(title: String, body: String) {
        let script = "display notification \"\(esc(body))\" with title \"\(esc(title))\" sound name \"Glass\""
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        try? p.run()
    }

    private static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
