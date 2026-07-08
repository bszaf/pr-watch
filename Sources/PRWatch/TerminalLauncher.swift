import Foundation

/// Which terminal to open a project in.
enum TerminalApp: String, CaseIterable, Identifiable {
    case iterm
    case terminal
    case custom

    var id: String { rawValue }
    var label: String {
        switch self {
        case .iterm: "iTerm2"
        case .terminal: "Terminal"
        case .custom: "Custom command"
        }
    }
}

/// Opens a directory in the user's chosen terminal. iTerm2/Terminal are driven via
/// AppleScript (opens a new tab and `cd`s in); this prompts for Automation permission
/// the first time. Custom runs a shell command template with `{path}` substituted.
enum TerminalLauncher {
    static func open(path: String, settings: AppSettings) {
        switch TerminalApp(rawValue: settings.terminalApp) ?? .iterm {
        case .iterm:
            osascript(itermScript(path: path))
        case .terminal:
            osascript(terminalScript(path: path))
        case .custom:
            let cmd = settings.customTerminalCommand.replacingOccurrences(of: "{path}", with: shellQuote(path))
            guard !cmd.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            shell(cmd)
        }
    }

    private static func itermScript(path: String) -> String {
        let cd = appleEscape("cd " + shellQuote(path))
        return """
        tell application "iTerm"
          activate
          if (count of windows) = 0 then
            set w to (create window with default profile)
            tell current session of w to write text "\(cd)"
          else
            tell current window
              set t to (create tab with default profile)
              tell current session of t to write text "\(cd)"
            end tell
          end if
        end tell
        """
    }

    private static func terminalScript(path: String) -> String {
        """
        tell application "Terminal"
          activate
          do script "\(appleEscape("cd " + shellQuote(path)))"
        end tell
        """
    }

    /// Single-quote for the shell (handles spaces and embedded quotes).
    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Escape for an AppleScript double-quoted string literal.
    private static func appleEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func osascript(_ script: String) {
        run("/usr/bin/osascript", ["-e", script])
    }

    private static func shell(_ command: String) {
        run("/bin/zsh", ["-lc", command])
    }

    private static func run(_ launch: String, _ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launch)
        p.arguments = args
        try? p.run()
    }
}
