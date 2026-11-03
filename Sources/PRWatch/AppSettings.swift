import Foundation
import Observation

/// Repo names compare case-insensitively: GitHub treats `Acme/App` and `acme/app` alike.
func ignoredChecks(_ rules: [String: [String]], in repo: String) -> Set<String> {
    Set(rules.filter { $0.key.lowercased() == repo.lowercased() }.values.joined())
}

/// `rules` with `name` added to or removed from `repo`'s list; an emptied repo is dropped.
func settingCheck(_ name: String, ignored: Bool, in repo: String, rules: [String: [String]]) -> [String: [String]] {
    var rules = rules
    let key = rules.keys.first { $0.lowercased() == repo.lowercased() } ?? repo
    var names = rules[key] ?? []
    names.removeAll { $0 == name }
    if ignored { names.append(name); names.sort() }
    rules[key] = names.isEmpty ? nil : names
    return rules
}

/// User-configurable settings, persisted to UserDefaults. Read by `PRStore`.
@Observable
final class AppSettings {
    var pollInterval: Int { didSet { d.set(pollInterval, forKey: "pollInterval") } }

    // Notification triggers
    var notifyCI: Bool { didSet { d.set(notifyCI, forKey: "notifyCI") } }
    var notifyReview: Bool { didSet { d.set(notifyReview, forKey: "notifyReview") } }
    var notifyConflicts: Bool { didSet { d.set(notifyConflicts, forKey: "notifyConflicts") } }
    var notifyComments: Bool { didSet { d.set(notifyComments, forKey: "notifyComments") } }
    var notifyAgents: Bool { didSet { d.set(notifyAgents, forKey: "notifyAgents") } }
    var notifyMerged: Bool { didSet { d.set(notifyMerged, forKey: "notifyMerged") } }
    /// Command that starts an agent in a worktree; `{prompt}` is replaced, shell-quoted.
    var agentCommand: String { didSet { d.set(agentCommand, forKey: "agentCommand") } }

    // Providers
    var watchGitHub: Bool { didSet { d.set(watchGitHub, forKey: "watchGitHub") } }
    var watchGitLab: Bool { didSet { d.set(watchGitLab, forKey: "watchGitLab") } }
    var gitlabHost: String { didSet { d.set(gitlabHost, forKey: "gitlabHost") } }
    var watchAgents: Bool { didSet { d.set(watchAgents, forKey: "watchAgents") } }

    // Watch scope
    var watchAuthored: Bool { didSet { d.set(watchAuthored, forKey: "watchAuthored") } }
    var watchReviewRequested: Bool { didSet { d.set(watchReviewRequested, forKey: "watchReviewRequested") } }
    var watchMentions: Bool { didSet { d.set(watchMentions, forKey: "watchMentions") } }
    /// Repositories (owner/name) to limit watching to. Empty = all repos.
    var repoFilters: [String] { didSet { d.set(repoFilters, forKey: "repoFilters") } }
    /// Per repo (owner/name): check names whose failures don't count toward CI state.
    var ignoredChecks: [String: [String]] { didSet { d.set(ignoredChecks, forKey: "ignoredChecks") } }
    /// Explicitly-watched PRs, each "owner/repo#number".
    var customPRs: [String] { didSet { d.set(customPRs, forKey: "customPRs") } }

    /// Directories scanned for local git projects (Projects tab).
    var scanRoots: [String] { didSet { d.set(scanRoots, forKey: "scanRoots") } }

    /// Terminal used to open a project ("iterm" | "terminal" | "custom").
    var terminalApp: String { didSet { d.set(terminalApp, forKey: "terminalApp") } }
    var customTerminalCommand: String { didSet { d.set(customTerminalCommand, forKey: "customTerminalCommand") } }

    var launchAtLogin: Bool { didSet { d.set(launchAtLogin, forKey: "launchAtLogin") } }

    /// Populate the app with synthetic sample data (DemoData) instead of fetching — a
    /// living visual reference rendered through the real views. No network, no notifications.
    var demoMode: Bool { didSet { d.set(demoMode, forKey: "demoMode") } }

    private let d = UserDefaults.standard

    func ignoredChecks(in repo: String) -> Set<String> { PRWatch.ignoredChecks(ignoredChecks, in: repo) }

    func setCheck(_ name: String, ignored: Bool, in repo: String) {
        ignoredChecks = settingCheck(name, ignored: ignored, in: repo, rules: ignoredChecks)
    }

    init() {
        // register defaults so first launch has sensible values
        d.register(defaults: [
            "pollInterval": 60,
            "notifyCI": true,
            "notifyReview": true,
            "notifyConflicts": true,
            "notifyComments": true,
            "notifyAgents": true,
            "notifyMerged": true,
            "agentCommand": "claude {prompt}",
            "watchAgents": true,
            "watchAuthored": true,
            "watchReviewRequested": true,
            "watchMentions": true,
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
        notifyComments = d.bool(forKey: "notifyComments")
        notifyAgents = d.bool(forKey: "notifyAgents")
        notifyMerged = d.bool(forKey: "notifyMerged")
        agentCommand = d.string(forKey: "agentCommand") ?? "claude {prompt}"
        watchAgents = d.bool(forKey: "watchAgents")
        watchAuthored = d.bool(forKey: "watchAuthored")
        watchReviewRequested = d.bool(forKey: "watchReviewRequested")
        watchMentions = d.bool(forKey: "watchMentions")
        let legacyRepoFilter = d.string(forKey: "repoFilter") ?? ""
        repoFilters = d.stringArray(forKey: "repoFilters") ?? (legacyRepoFilter.isEmpty ? [] : [legacyRepoFilter])
        customPRs = d.stringArray(forKey: "customPRs") ?? []
        ignoredChecks = d.dictionary(forKey: "ignoredChecks") as? [String: [String]] ?? [:]
        scanRoots = d.stringArray(forKey: "scanRoots") ?? ["~/projects"]
        terminalApp = d.string(forKey: "terminalApp") ?? "iterm"
        customTerminalCommand = d.string(forKey: "customTerminalCommand") ?? "open -a Ghostty {path}"
        launchAtLogin = d.bool(forKey: "launchAtLogin")
        demoMode = d.bool(forKey: "demoMode")
    }
}
