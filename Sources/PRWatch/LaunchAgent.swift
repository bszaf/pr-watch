import Foundation

/// Installs/removes a launchd LaunchAgent so the app can start at login (opt-in).
/// Points at the running bundle's executable so it survives rebuilds in place.
enum LaunchAgent {
    private static let label = "com.bszaf.prwatch"

    private static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isInstalled: Bool { FileManager.default.fileExists(atPath: plistURL.path) }

    /// Path to the executable inside the current .app bundle, if we are running from one.
    private static var bundleExecutable: String? {
        let exe = Bundle.main.executableURL?.path ?? CommandLine.arguments[0]
        return exe.contains(".app/Contents/MacOS/") ? exe : nil
    }

    @discardableResult
    static func install() -> Bool {
        guard let exe = bundleExecutable else { return false }
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [exe],
            "RunAtLoad": true,
            "KeepAlive": false,
        ]
        do {
            try FileManager.default.createDirectory(
                at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: plistURL)
            return true
        } catch {
            return false
        }
    }

    static func uninstall() {
        try? FileManager.default.removeItem(at: plistURL)
    }
}
