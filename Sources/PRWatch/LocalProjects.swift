import Foundation
import Observation

/// A git project (repo or worktree) discovered under a scan root.
struct LocalProject: Identifiable, Sendable, Equatable {
    let id: String        // absolute path
    let name: String
    let path: String
    let branch: String?
    let repo: String?     // owner/repo from the origin remote
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
                    repo: git(path, ["config", "--get", "remote.origin.url"]).flatMap(normalizeRepo)
                ))
            }
        }
        return out
    }

    private static func git(_ dir: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", dir] + args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let s = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
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

    init(settings: AppSettings) { self.settings = settings }

    func scan() async {
        guard !isScanning else { return }
        isScanning = true
        let roots = settings.scanRoots
        projects = await Task.detached { ProjectScanner.scan(roots: roots) }.value
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
