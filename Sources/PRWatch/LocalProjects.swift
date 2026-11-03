import Foundation
import Observation

/// A git project (repo or worktree) discovered under a scan root.
struct LocalProject: Identifiable, Sendable, Equatable {
    let id: String        // absolute path
    let name: String
    let path: String
    let branch: String?
    let repo: String?     // owner/repo from the origin remote
    var changedFiles = 0          // uncommitted (incl. untracked) paths
    var lastCommit: Date? = nil
    var defaultBranch: String? = nil   // origin/HEAD target, e.g. "main"

    /// On a branch that should end up as a PR (not the default / a mainline branch).
    var onFeatureBranch: Bool {
        guard let branch, branch != "HEAD" else { return false }
        if let defaultBranch { return branch != defaultBranch }
        return !["main", "master", "develop", "trunk"].contains(branch)
    }

    /// A feature branch with recent or uncommitted work. Old idle branches are left out:
    /// after a squash merge they look exactly like branches that never got a PR.
    func isActiveWithoutPR(now: Date) -> Bool {
        guard onFeatureBranch else { return false }
        return changedFiles > 0 || lastCommit.map { now.timeIntervalSince($0) < 7 * 86400 } ?? false
    }
}

enum ProjectScanner {
    /// List git projects directly under each root (a dir containing `.git`, which covers
    /// both plain repos and worktrees whose `.git` is a file).
    static func scan(roots: [String]) -> [LocalProject] {
        let fm = FileManager.default
        var seen = Set<String>()
        var out: [LocalProject] = []
        for root in roots {
            let base = (root as NSString).expandingTildeInPath
            guard let entries = try? fm.contentsOfDirectory(atPath: base) else { continue }
            for entry in entries.sorted(by: { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })
            where !entry.hasPrefix(".") {
                let path = base + "/" + entry
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue,
                      fm.fileExists(atPath: path + "/.git"),
                      seen.insert(path).inserted else { continue }
                out.append(LocalProject(
                    id: path, name: entry, path: path,
                    branch: git(path, ["rev-parse", "--abbrev-ref", "HEAD"]),
                    repo: git(path, ["config", "--get", "remote.origin.url"]).flatMap(normalizeRepo),
                    changedFiles: git(path, ["status", "--porcelain"])
                        .map { $0.split(separator: "\n").count } ?? 0,
                    lastCommit: git(path, ["log", "-1", "--format=%ct"])
                        .flatMap(TimeInterval.init).map(Date.init(timeIntervalSince1970:)),
                    defaultBranch: git(path, ["symbolic-ref", "--short", "refs/remotes/origin/HEAD"])
                        .map { $0.hasPrefix("origin/") ? String($0.dropFirst(7)) : $0 }
                ))
            }
        }
        return out
    }

    private static func git(_ dir: String, _ args: [String]) -> String? {
        runCapturing("/usr/bin/git", ["-C", dir] + args)
    }

    /// "git@github.com:owner/repo.git" or "https://host/owner/repo.git" -> "owner/repo".
    static func normalizeRepo(_ url: String) -> String? {
        var s = url.trimmingCharacters(in: .whitespaces)
        if s.hasSuffix(".git") { s.removeLast(4) }
        if !s.contains("://"), let colon = s.lastIndex(of: ":") {
            s = String(s[s.index(after: colon)...])           // scp-like git@host:owner/repo
        } else if let path = URL(string: s)?.path {
            s = path                                           // https://host/owner/repo
        }
        let parts = s.split(separator: "/").suffix(2)
        return parts.count == 2 ? parts.joined(separator: "/") : nil
    }
}

@MainActor
@Observable
final class ProjectStore {
    private(set) var projects: [LocalProject] = []
    private(set) var isScanning = false
    let settings: AppSettings

    private var byRepoBranch: [String: LocalProject] = [:]

    private var timer: Timer?

    init(settings: AppSettings) { self.settings = settings }

    /// Rescan periodically so dirty / no-PR state of agent worktrees stays current.
    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.scan() }
        }
    }

    func scan() async {
        guard !isScanning else { return }
        if settings.demoMode { loadDemo(); return }
        isScanning = true
        let roots = settings.scanRoots
        projects = await runBlocking { ProjectScanner.scan(roots: roots) }
        byRepoBranch = Dictionary(
            projects.compactMap { p in Self.key(p.repo, p.branch).map { ($0, p) } },
            uniquingKeysWith: { first, _ in first }
        )
        isScanning = false
    }

    /// Populate from `DemoData` and rebuild the PR-match index — no filesystem scan.
    private func loadDemo() {
        projects = DemoData.projects
        byRepoBranch = Dictionary(
            projects.compactMap { p in Self.key(p.repo, p.branch).map { ($0, p) } },
            uniquingKeysWith: { first, _ in first }
        )
        isScanning = false
    }

    /// The local project matching a PR's repo + head branch, if any.
    func project(for pr: PullRequest) -> LocalProject? {
        Self.key(pr.repo, pr.headBranch).flatMap { byRepoBranch[$0] }
    }

    private static func key(_ repo: String?, _ branch: String?) -> String? {
        guard let repo, let branch else { return nil }
        return "\(repo)\u{0}\(branch)"
    }
}
