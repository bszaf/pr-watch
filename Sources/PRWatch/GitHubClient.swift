import Foundation

enum GitHubError: LocalizedError {
    case noToken
    case http(Int, String)
    case graphql(String)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .noToken:
            return "No GitHub token. Run `gh auth login` or paste a PAT in Settings."
        case let .http(code, body):
            return "GitHub HTTP \(code): \(body.prefix(200))"
        case let .graphql(msg):
            return "GitHub GraphQL error: \(msg)"
        case let .transport(msg):
            return "Network error: \(msg)"
        }
    }
}

struct GitHubClient {
    let authored: Bool
    let reviewRequested: Bool
    let repoFilter: String       // "" = all repos
    let customPRs: [String]      // "owner/repo#number"

    init(authored: Bool, reviewRequested: Bool, repoFilter: String, customPRs: [String]) {
        self.authored = authored
        self.reviewRequested = reviewRequested
        self.repoFilter = repoFilter.trimmingCharacters(in: .whitespaces)
        self.customPRs = customPRs
    }

    /// Parse "owner/repo#123" or a github.com PR URL into its parts.
    static func parsePR(_ raw: String) -> (owner: String, repo: String, number: Int)? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if let url = URL(string: s), url.host?.contains("github.com") == true {
            let parts = url.pathComponents.filter { $0 != "/" }
            if parts.count >= 4, parts[2] == "pull", let n = Int(parts[3]) {
                return (parts[0], parts[1], n)
            }
        }
        if let hash = s.firstIndex(of: "#") {
            let rp = s[..<hash].split(separator: "/")
            if rp.count == 2, let n = Int(s[s.index(after: hash)...]) {
                return (String(rp[0]), String(rp[1]), n)
            }
        }
        return nil
    }

    /// Canonical "owner/repo#number" for a parseable input, else nil.
    static func normalizePR(_ raw: String) -> String? {
        guard let p = parsePR(raw) else { return nil }
        return "\(p.owner)/\(p.repo)#\(p.number)"
    }

    // MARK: - Token resolution

    /// 1) Keychain PAT  2) `gh auth token` via a login shell  3) probe homebrew `gh`
    /// 4) GITHUB_TOKEN env.
    static func resolveToken() -> ResolvedToken? {
        if let pat = Keychain.readToken(account: Provider.github.keychainAccount) {
            return ResolvedToken(token: pat, source: .keychain)
        }
        if let t = run("/bin/zsh", ["-lc", "gh auth token"]) { return ResolvedToken(token: t, source: .cli) }
        for path in ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"] where FileManager.default.isExecutableFile(atPath: path) {
            if let t = run(path, ["auth", "token"]) { return ResolvedToken(token: t, source: .cli) }
        }
        if let env = ProcessInfo.processInfo.environment["GITHUB_TOKEN"], !env.isEmpty {
            return ResolvedToken(token: env, source: .env)
        }
        return nil
    }

    private static func run(_ launch: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launch)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let s = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    // MARK: - Fetch

    func fetch() async throws -> ProviderResult {
        guard let q = query() else { return ProviderResult(prs: [], viewerLogin: nil, source: .none) }
        guard let resolved = Self.resolveToken() else { throw GitHubError.noToken }

        var req = URLRequest(url: URL(string: "https://api.github.com/graphql")!)
        req.httpMethod = "POST"
        req.setValue("bearer \(resolved.token)", forHTTPHeaderField: "Authorization")
        req.setValue("PR-Watch", forHTTPHeaderField: "User-Agent")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["query": q])

        let (data, resp): (Data, URLResponse)
        do {
            (data, resp) = try await URLSession.shared.data(for: req)
        } catch {
            throw GitHubError.transport(error.localizedDescription)
        }
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            throw GitHubError.http(http.statusCode, String(decoding: data, as: UTF8.self))
        }

        let decoded = try JSONDecoder().decode(GraphQLResponse.self, from: data)
        // Partial errors (e.g. a mistyped custom PR that 404s) are tolerated as long as
        // some data came back; only a fully-null data payload is fatal.
        guard let block = decoded.data else {
            throw GitHubError.graphql(decoded.errors?.map(\.message).joined(separator: "; ") ?? "no data")
        }

        var seen = Set<String>()
        var result: [PullRequest] = []
        let nodes = (block.authored?.nodes ?? []) + (block.reviewRequested?.nodes ?? []) + block.custom
        for node in nodes {
            guard let pr = node.toPullRequest(), seen.insert(pr.id).inserted else { continue }
            result.append(pr)
        }
        return ProviderResult(prs: result, viewerLogin: block.viewer?.login, source: resolved.source)
    }

    // MARK: - Query building

    private func query() -> String? {
        var blocks: [String] = []
        if authored {
            blocks.append("authored: search(query: \"\(qString("author:@me"))\", type: ISSUE, first: 40) { nodes { ... on PullRequest { \(Self.prFields) } } }")
        }
        if reviewRequested {
            blocks.append("reviewRequested: search(query: \"\(qString("review-requested:@me"))\", type: ISSUE, first: 40) { nodes { ... on PullRequest { \(Self.prFields) } } }")
        }
        for (i, raw) in customPRs.enumerated() {
            guard let p = Self.parsePR(raw) else { continue }
            blocks.append("c\(i): repository(owner: \"\(p.owner)\", name: \"\(p.repo)\") { pullRequest(number: \(p.number)) { \(Self.prFields) } }")
        }
        guard !blocks.isEmpty else { return nil }
        return "query { viewer { login } \(blocks.joined(separator: " ")) }"
    }

    private func qString(_ who: String) -> String {
        var terms = ["is:open", "is:pr", who]
        if !repoFilter.isEmpty { terms.append("repo:\(repoFilter)") }
        return terms.joined(separator: " ")
    }

    private static let prFields = """
    number title url isDraft headRefName
    author { login }
    repository { nameWithOwner }
    reviewDecision
    mergeable
    commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
    """
}

// MARK: - GraphQL decoding

private struct GraphQLResponse: Decodable {
    let data: DataBlock?
    let errors: [GQLError]?

    struct GQLError: Decodable { let message: String }

    /// Known aliases (`authored`, `reviewRequested`) plus arbitrary `c<N>` repository
    /// blocks for custom PRs — decoded via dynamic keys.
    struct DataBlock: Decodable {
        var viewer: Viewer?
        var authored: SearchBlock?
        var reviewRequested: SearchBlock?
        var custom: [Node] = []

        private struct Key: CodingKey {
            var stringValue: String
            init?(stringValue: String) { self.stringValue = stringValue }
            var intValue: Int? { nil }
            init?(intValue: Int) { nil }
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Key.self)
            for key in c.allKeys {
                switch key.stringValue {
                case "viewer": viewer = try c.decode(Viewer.self, forKey: key)
                case "authored": authored = try c.decode(SearchBlock.self, forKey: key)
                case "reviewRequested": reviewRequested = try c.decode(SearchBlock.self, forKey: key)
                default:
                    // Custom `c<N>` repository blocks; a bad/404 one decodes as null and is skipped.
                    if let repo = try? c.decode(RepoBlock.self, forKey: key), let pr = repo.pullRequest {
                        custom.append(pr)
                    }
                }
            }
        }
    }

    struct Viewer: Decodable { let login: String? }
    struct SearchBlock: Decodable { let nodes: [Node] }
    struct RepoBlock: Decodable { let pullRequest: Node? }

    struct Node: Decodable {
        let number: Int?
        let title: String?
        let url: String?
        let isDraft: Bool?
        let author: Author?
        let repository: Repo?
        let headRefName: String?
        let reviewDecision: ReviewDecision?
        let mergeable: Mergeable?
        let commits: Commits?

        struct Author: Decodable { let login: String? }
        struct Repo: Decodable { let nameWithOwner: String }
        struct Commits: Decodable {
            let nodes: [CommitNode]
            struct CommitNode: Decodable {
                let commit: Commit
                struct Commit: Decodable {
                    let statusCheckRollup: Rollup?
                    struct Rollup: Decodable { let state: CheckState? }
                }
            }
        }

        func toPullRequest() -> PullRequest? {
            guard let number, let title, let url, let repo = repository?.nameWithOwner else { return nil }
            return PullRequest(
                id: "github:\(repo)#\(number)",
                provider: .github,
                number: number,
                title: title,
                url: url,
                isDraft: isDraft ?? false,
                repo: repo,
                author: author?.login ?? "",
                headBranch: headRefName,
                reviewDecision: reviewDecision,
                mergeable: mergeable ?? .unknown,
                ciState: commits?.nodes.first?.commit.statusCheckRollup?.state
            )
        }
    }
}
