import Foundation
import AppKit

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
    /// Open `path`, then run `command` there if given. Returns false when `command` couldn't
    /// be run: a custom template without a `{command}` placeholder.
    @discardableResult
    static func open(path: String, settings: AppSettings, command: String? = nil) -> Bool {
        let line = "cd " + shellQuote(path) + (command.map { " && " + $0 } ?? "")
        switch TerminalApp(rawValue: settings.terminalApp) ?? .iterm {
        case .iterm:
            osascript(itermScript(line: line))
        case .terminal:
            osascript(terminalScript(line: line))
        case .custom:
            let template = settings.customTerminalCommand
            var cmd = template.replacingOccurrences(of: "{path}", with: shellQuote(path))
            if let command { cmd = cmd.replacingOccurrences(of: "{command}", with: shellQuote(command)) }
            guard !cmd.trimmingCharacters(in: .whitespaces).isEmpty else { return command == nil }
            shell(cmd)
            return command == nil || template.contains("{command}")
        }
        return true
    }

    /// Bring the iTerm2/Terminal tab that owns `tty` to the front, else open a new one in `path`.
    @MainActor
    static func focusOrOpen(tty: String?, path: String, settings: AppSettings) async {
        if let tty, await focus(tty: tty) { return }
        open(path: path, settings: settings)
    }

    /// Bring the tab owning `tty` to the front, typing `typing` + Return into it first. Typing
    /// is iTerm2-only (`write text`); Terminal.app has no equivalent for a running program.
    @MainActor
    static func focus(tty: String, typing: String? = nil) async -> Bool {
        // Only script terminals that are already running — `tell` would launch them.
        var scripts: [String] = []
        if isRunning("com.googlecode.iterm2") { scripts.append(itermFocusScript(tty: tty, typing: typing)) }
        if typing == nil, isRunning("com.apple.Terminal") { scripts.append(terminalFocusScript(tty: tty)) }
        let candidates = scripts
        return await runBlocking {
            candidates.contains { runCapturing("/usr/bin/osascript", ["-e", $0]) == "ok" }
        }
    }

    private static func isRunning(_ bundleId: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).isEmpty
    }

    private static func itermFocusScript(tty: String, typing: String?) -> String {
        let write = typing.map { "tell s to write text \"\(appleEscape($0))\"" } ?? ""
        return """
        tell application "iTerm"
          repeat with w in windows
            repeat with t in tabs of w
              repeat with s in sessions of t
                if tty of s is "\(appleEscape(tty))" then
                  \(write)
                  tell w to select
                  tell t to select
                  tell s to select
                  activate
                  return "ok"
                end if
              end repeat
            end repeat
          end repeat
          return "none"
        end tell
        """
    }

    private static func terminalFocusScript(tty: String) -> String {
        """
        tell application "Terminal"
          repeat with w in windows
            repeat with t in tabs of w
              if tty of t is "\(appleEscape(tty))" then
                set selected tab of w to t
                set index of w to 1
                activate
                return "ok"
              end if
            end repeat
          end repeat
          return "none"
        end tell
        """
    }

    private static func itermScript(line: String) -> String {
        let cd = appleEscape(line)
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

    private static func terminalScript(line: String) -> String {
        """
        tell application "Terminal"
          activate
          do script "\(appleEscape(line))"
        end tell
        """
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
