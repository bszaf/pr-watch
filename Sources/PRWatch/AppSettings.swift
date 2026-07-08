import Foundation
import Observation

/// User-configurable settings, persisted to UserDefaults. Read by `PRStore`.
@Observable
final class AppSettings {
    var pollInterval: Int { didSet { d.set(pollInterval, forKey: "pollInterval") } }

    // Notification triggers
    var notifyCI: Bool { didSet { d.set(notifyCI, forKey: "notifyCI") } }
    var notifyReview: Bool { didSet { d.set(notifyReview, forKey: "notifyReview") } }
    var notifyConflicts: Bool { didSet { d.set(notifyConflicts, forKey: "notifyConflicts") } }

    // Providers
    var watchGitHub: Bool { didSet { d.set(watchGitHub, forKey: "watchGitHub") } }
    var watchGitLab: Bool { didSet { d.set(watchGitLab, forKey: "watchGitLab") } }
    var gitlabHost: String { didSet { d.set(gitlabHost, forKey: "gitlabHost") } }

    // Watch scope
    var watchAuthored: Bool { didSet { d.set(watchAuthored, forKey: "watchAuthored") } }
    var watchReviewRequested: Bool { didSet { d.set(watchReviewRequested, forKey: "watchReviewRequested") } }
    /// Repositories (owner/name) to limit watching to. Empty = all repos.
    var repoFilters: [String] { didSet { d.set(repoFilters, forKey: "repoFilters") } }
    /// Explicitly-watched PRs, each "owner/repo#number".
    var customPRs: [String] { didSet { d.set(customPRs, forKey: "customPRs") } }

    /// Directories scanned for local git projects (Projects tab).
    var scanRoots: [String] { didSet { d.set(scanRoots, forKey: "scanRoots") } }

    /// Terminal used to open a project ("iterm" | "terminal" | "custom").
    var terminalApp: String { didSet { d.set(terminalApp, forKey: "terminalApp") } }
    var customTerminalCommand: String { didSet { d.set(customTerminalCommand, forKey: "customTerminalCommand") } }

    var launchAtLogin: Bool { didSet { d.set(launchAtLogin, forKey: "launchAtLogin") } }

    private let d = UserDefaults.standard

    init() {
        // register defaults so first launch has sensible values
        d.register(defaults: [
            "pollInterval": 60,
            "notifyCI": true,
            "notifyReview": true,
            "notifyConflicts": true,
            "watchAuthored": true,
            "watchReviewRequested": false,
            "watchGitHub": true,
            "watchGitLab": true,
            "gitlabHost": "https://gitlab.com",
        ])
        watchGitHub = d.bool(forKey: "watchGitHub")
        watchGitLab = d.bool(forKey: "watchGitLab")
        gitlabHost = d.string(forKey: "gitlabHost") ?? "https://gitlab.com"
        pollInterval = d.integer(forKey: "pollInterval")
        notifyCI = d.bool(forKey: "notifyCI")
        notifyReview = d.bool(forKey: "notifyReview")
        notifyConflicts = d.bool(forKey: "notifyConflicts")
        watchAuthored = d.bool(forKey: "watchAuthored")
        watchReviewRequested = d.bool(forKey: "watchReviewRequested")
        let legacyRepoFilter = d.string(forKey: "repoFilter") ?? ""
        repoFilters = d.stringArray(forKey: "repoFilters") ?? (legacyRepoFilter.isEmpty ? [] : [legacyRepoFilter])
        customPRs = d.stringArray(forKey: "customPRs") ?? []
        scanRoots = d.stringArray(forKey: "scanRoots") ?? ["~/projects"]
        terminalApp = d.string(forKey: "terminalApp") ?? "iterm"
        customTerminalCommand = d.string(forKey: "customTerminalCommand") ?? "open -a Ghostty {path}"
        launchAtLogin = d.bool(forKey: "launchAtLogin")
    }
}
