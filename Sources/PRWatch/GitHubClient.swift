import Foundation

enum GitHubError: LocalizedError {
    case noToken
    case http(Int, String)
    case graphql(String)
    case transport(String)
    case rateLimited(Date?)

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
        case let .rateLimited(reset):
            if let reset {
                let f = DateFormatter(); f.timeStyle = .short
                return "GitHub API rate limit reached — resumes at \(f.string(from: reset))."
            }
            return "GitHub API rate limit reached."
        }
    }
}

struct GitHubClient {
    let authored: Bool
    let reviewRequested: Bool
    let mentioned: Bool
    let repoFilters: [String]    // owner/repo list; empty = all repos
    let customPRs: [String]      // "owner/repo#number"

    init(authored: Bool, reviewRequested: Bool, mentioned: Bool, repoFilters: [String], customPRs: [String]) {
        self.authored = authored
        self.reviewRequested = reviewRequested
        self.mentioned = mentioned
        self.repoFilters = repoFilters.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
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
        let http = resp as? HTTPURLResponse
        let remaining = http?.value(forHTTPHeaderField: "x-ratelimit-remaining").flatMap(Int.init)
        let resetAt = http?.value(forHTTPHeaderField: "x-ratelimit-reset")
            .flatMap(TimeInterval.init).map { Date(timeIntervalSince1970: $0) }

        if let code = http?.statusCode, code != 200 {
            if (code == 403 || code == 429), (remaining ?? 1) == 0 { throw GitHubError.rateLimited(resetAt) }
            throw GitHubError.http(code, String(decoding: data, as: UTF8.self))
        }

        let decoded = try JSONDecoder().decode(GraphQLResponse.self, from: data)
        // Partial errors (e.g. a mistyped custom PR that 404s) are tolerated as long as
        // some data came back; only a fully-null data payload is fatal.
        guard let block = decoded.data else {
            let msg = decoded.errors?.map(\.message).joined(separator: "; ") ?? "no data"
            if msg.lowercased().contains("rate limit") { throw GitHubError.rateLimited(resetAt) }
            throw GitHubError.graphql(msg)
        }

        // Merge buckets, unioning the relation(s) that put each PR in the set.
        let viewer = block.viewer?.login
        var byId: [String: PullRequest] = [:]
        var order: [String] = []
        func add(_ nodes: [GraphQLResponse.Node], _ relation: PRRelation) {
            for node in nodes {
                guard let pr = node.toPullRequest(viewer: viewer) else { continue }
                if byId[pr.id] == nil { byId[pr.id] = pr; order.append(pr.id) }
                byId[pr.id]?.relations.insert(relation)
            }
        }
        let directIds = Set((block.reviewDirect?.nodes ?? []).compactMap { $0.toPullRequest(viewer: viewer)?.id })
        add(block.authored?.nodes ?? [], .authored)
        // review-requested is the superset; a PR not in the direct set is a team request.
        for node in block.reviewRequested?.nodes ?? [] {
            guard let pr = node.toPullRequest(viewer: viewer) else { continue }
            if byId[pr.id] == nil { byId[pr.id] = pr; order.append(pr.id) }
            byId[pr.id]?.relations.insert(directIds.contains(pr.id) ? .reviewDirect : .reviewTeam)
        }
        add(block.mentioned?.nodes ?? [], .mentioned)
        add(block.custom, .watched)
        let result = order.compactMap { byId[$0] }
        return ProviderResult(prs: result, viewerLogin: block.viewer?.login, source: resolved.source,
                              rateLimitRemaining: remaining, rateLimitResetAt: resetAt)
    }

    // MARK: - Query building

    private func query() -> String? {
        var blocks: [String] = []
        if authored {
            blocks.append("authored: search(query: \"\(qString("author:@me"))\", type: ISSUE, first: 40) { nodes { ... on PullRequest { \(Self.prFields) } } }")
        }
        if reviewRequested {
            // review-requested = direct + team; user-review-requested = direct only.
            // The set difference tells us which reviews are via a team.
            blocks.append("reviewRequested: search(query: \"\(qString("review-requested:@me"))\", type: ISSUE, first: 40) { nodes { ... on PullRequest { \(Self.prFields) } } }")
            blocks.append("reviewDirect: search(query: \"\(qString("user-review-requested:@me"))\", type: ISSUE, first: 40) { nodes { ... on PullRequest { \(Self.prFields) } } }")
        }
        if mentioned {
            blocks.append("mentioned: search(query: \"\(qString("mentions:@me"))\", type: ISSUE, first: 40) { nodes { ... on PullRequest { \(Self.prFields) } } }")
        }
        for (i, raw) in customPRs.enumerated() {
            guard let p = Self.parsePR(raw) else { continue }
            blocks.append("c\(i): repository(owner: \"\(p.owner)\", name: \"\(p.repo)\") { pullRequest(number: \(p.number)) { \(Self.prFields) } }")
        }
        guard !blocks.isEmpty else { return nil }
        return "query { viewer { login } \(blocks.joined(separator: " ")) }"
    }

    private func qString(_ who: String) -> String {
        // Multiple `repo:` qualifiers are OR-ed by GitHub search.
        var terms = ["is:open", "is:pr", who]
        terms += repoFilters.map { "repo:\($0)" }
        return terms.joined(separator: " ")
    }

    private static let prFields = """
    number title url isDraft headRefName baseRefName additions deletions updatedAt
    author { login }
    repository { nameWithOwner }
    reviewDecision
    latestReviews(first: 10) { nodes { author { login __typename } state } }
    reviewThreads(first: 8) { nodes { isResolved comments(last: 1) { nodes { author { login __typename } } } } }
    reviewRequests(first: 10) { nodes { requestedReviewer { __typename ... on User { login } ... on Team { slug } } } }
    labels(first: 10) { nodes { name } }
    comments { totalCount }
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
        var reviewDirect: SearchBlock?
        var mentioned: SearchBlock?
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
                case "reviewDirect": reviewDirect = try c.decode(SearchBlock.self, forKey: key)
                case "mentioned": mentioned = try c.decode(SearchBlock.self, forKey: key)
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
        let baseRefName: String?
        let additions: Int?
        let deletions: Int?
        let updatedAt: String?
        let reviewDecision: ReviewDecision?
        let latestReviews: Reviews?
        let reviewThreads: ReviewThreads?
        let reviewRequests: ReviewRequests?
        let labels: Labels?
        let comments: Count?
        let mergeable: Mergeable?
        let commits: Commits?

        struct Author: Decodable {
            let login: String?
            let typename: String?
            enum CodingKeys: String, CodingKey { case login; case typename = "__typename" }
            var isBot: Bool { typename == "Bot" || (login?.hasSuffix("[bot]") ?? false) }
        }
        struct Repo: Decodable { let nameWithOwner: String }
        struct Reviews: Decodable {
            let nodes: [ReviewNode]
            struct ReviewNode: Decodable { let author: Author?; let state: String? }
        }
        struct ReviewThreads: Decodable {
            let nodes: [Thread]
            struct Thread: Decodable {
                let isResolved: Bool
                let comments: Comments
                struct Comments: Decodable { let nodes: [ReviewNode]; struct ReviewNode: Decodable { let author: Author? } }
                var lastAuthor: Author? { comments.nodes.last?.author }
            }
        }
        struct ReviewRequests: Decodable {
            let nodes: [RRNode]
            struct RRNode: Decodable { let requestedReviewer: Reviewer? }
            struct Reviewer: Decodable { let login: String?; let slug: String? }
        }
        struct Labels: Decodable {
            let nodes: [LabelNode]
            struct LabelNode: Decodable { let name: String }
        }
        struct Count: Decodable { let totalCount: Int }
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

        func toPullRequest(viewer: String?) -> PullRequest? {
            guard let number, let title, let url, let repo = repository?.nameWithOwner else { return nil }
            let reviews = latestReviews?.nodes ?? []
            let approvers = reviews.filter { $0.state == "APPROVED" }.compactMap { $0.author?.login }
            let changeRequesters = reviews.filter { $0.state == "CHANGES_REQUESTED" }.compactMap { $0.author?.login }
            let commented = reviews
                .filter { $0.state == "COMMENTED" && $0.author?.isBot == false }
                .compactMap { $0.author?.login }
                .filter { !approvers.contains($0) && !changeRequesters.contains($0) }

            let unresolved = (reviewThreads?.nodes ?? []).filter { !$0.isResolved }
            let awaiting = unresolved.filter { thread in
                guard let a = thread.lastAuthor, a.isBot == false, let login = a.login else { return false }
                return login != viewer
            }
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
                ciState: commits?.nodes.first?.commit.statusCheckRollup?.state,
                approvers: approvers,
                changeRequesters: changeRequesters,
                pendingReviewers: (reviewRequests?.nodes ?? []).compactMap { $0.requestedReviewer?.login ?? $0.requestedReviewer?.slug },
                baseBranch: baseRefName,
                additions: additions,
                deletions: deletions,
                labels: (labels?.nodes ?? []).map(\.name),
                comments: comments?.totalCount,
                updatedAt: updatedAt,
                commentedReviewers: commented,
                unresolvedThreads: unresolved.count,
                awaitingMyReply: awaiting.count
            )
        }
    }
}
