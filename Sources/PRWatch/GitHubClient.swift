import Foundation

enum GitHubError: LocalizedError {
    case http(Int, String)
    case graphql(String)
    case transport(String)
    case rateLimited(Date?)

    var errorDescription: String? {
        switch self {
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
    let showBehindCount: Bool
    let repoFilters: [String]    // owner/repo list; empty = all repos
    let customPRs: [String]      // "owner/repo#number"

    init(authored: Bool, reviewRequested: Bool, mentioned: Bool, showBehindCount: Bool = true,
         repoFilters: [String], customPRs: [String]) {
        self.authored = authored
        self.reviewRequested = reviewRequested
        self.mentioned = mentioned
        self.showBehindCount = showBehindCount
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

    /// Resolution spawns a login shell, so cache the result across polls; a 401 (or a
    /// token change in Settings) invalidates and re-resolves.
    private static let tokenLock = NSLock()
    private static var cachedToken: ResolvedToken?

    static func resolveToken() -> ResolvedToken? {
        tokenLock.lock()
        defer { tokenLock.unlock() }
        if let cachedToken { return cachedToken }
        cachedToken = resolveTokenUncached()
        return cachedToken
    }

    static func invalidateTokenCache() {
        tokenLock.lock()
        cachedToken = nil
        tokenLock.unlock()
    }

    /// 1) Keychain PAT  2) `gh auth token` via a login shell  3) probe homebrew `gh`
    /// 4) GITHUB_TOKEN env.
    private static func resolveTokenUncached() -> ResolvedToken? {
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

    /// Two-phase fetch. Phase A lists every watched PR with the *light* fields (identity,
    /// CI, review-decision, mergeable) that can change without bumping `updatedAt`. Phase B
    /// then fetches the expensive review threads / reviews ONLY for PRs that are new, whose
    /// `updatedAt` moved, or that still have open threads (a resolution may not bump
    /// `updatedAt`, so we re-check those to detect it clearing). Everything else reuses the
    /// per-PR `cache`, keeping typical polls far under the GraphQL rate budget.
    func fetch(cache: [String: CachedReview]) async throws -> ProviderResult {
        guard let qA = queryPhaseA() else { return ProviderResult(prs: [], viewerLogin: nil, source: .none) }
        // No token isn't an error — GitHub is just "not configured" (matches GitLab).
        guard var resolved = Self.resolveToken() else { return ProviderResult(prs: [], viewerLogin: nil, source: .none) }

        var (dataA, remA, resetA): (Data, Int?, Date?)
        do {
            (dataA, remA, resetA) = try await post(qA, token: resolved.token)
        } catch GitHubError.http(401, _) {
            // Stale cached token (e.g. expired gh OAuth token) — re-resolve once and retry.
            Self.invalidateTokenCache()
            guard let refreshed = Self.resolveToken() else { throw GitHubError.http(401, "token expired") }
            resolved = refreshed
            (dataA, remA, resetA) = try await post(qA, token: refreshed.token)
        }
        let decoded = try JSONDecoder().decode(GraphQLResponse.self, from: dataA)
        // Partial errors (e.g. a mistyped custom PR that 404s) are tolerated as long as
        // some data came back; only a fully-null data payload is fatal.
        guard let block = decoded.data else {
            let msg = decoded.errors?.map(\.message).joined(separator: "; ") ?? "no data"
            if msg.lowercased().contains("rate limit") { throw GitHubError.rateLimited(resetA) }
            throw GitHubError.graphql(msg)
        }

        // Merge buckets, unioning the relation(s) that put each PR in the set.
        let viewer = block.viewer?.login
        var order: [String] = []
        var nodeById: [String: GraphQLResponse.Node] = [:]
        var relationsById: [String: Set<PRRelation>] = [:]
        func add(_ nodes: [GraphQLResponse.Node], _ relation: PRRelation) {
            for node in nodes {
                guard let id = node.ghId else { continue }
                if nodeById[id] == nil { nodeById[id] = node; order.append(id) }
                relationsById[id, default: []].insert(relation)
            }
        }
        let directIds = Set((block.reviewDirect?.nodes ?? []).compactMap { $0.ghId })
        add(block.authored?.nodes ?? [], .authored)
        // review-requested is the superset; a PR not in the direct set is a team request.
        for node in block.reviewRequested?.nodes ?? [] {
            guard let id = node.ghId else { continue }
            if nodeById[id] == nil { nodeById[id] = node; order.append(id) }
            relationsById[id, default: []].insert(directIds.contains(id) ? .reviewDirect : .reviewTeam)
        }
        add(block.mentioned?.nodes ?? [], .mentioned)
        add(block.custom, .watched)

        // Base branches can advance without changing a PR's updatedAt, so compare every
        // authored PR on each poll. One batched query returns all exact behind counts.
        var behindById: [String: Int] = [:]
        var remLast = remA, resetLast = resetA
        let authoredNodes = showBehindCount ? (block.authored?.nodes ?? []) : []
        if let query = queryBehindCounts(authoredNodes) {
            do {
                let (data, remaining, reset) = try await post(query, token: resolved.token)
                if remaining != nil { remLast = remaining }
                if reset != nil { resetLast = reset }
                let response = try JSONDecoder().decode(BehindResponse.self, from: data)
                for (index, node) in authoredNodes.enumerated() {
                    guard let id = node.ghId,
                          let count = response.data?.byAlias["b\(index)"] else { continue }
                    behindById[id] = count
                }
            } catch {
                // Behind counts are supplementary; keep the PR list if comparison fails.
            }
        }

        // Which PRs need a fresh thread/review fetch?
        var stale: [GraphQLResponse.Node] = []
        var staleSet = Set<String>()
        for id in order {
            guard let node = nodeById[id] else { continue }
            let cached = cache[id]
            let changed = cached == nil || cached!.updatedAt != node.updatedAt
            let hasOpenThreads = (cached?.info.unresolvedThreads ?? 0) > 0
            if changed || hasOpenThreads { stale.append(node); staleSet.insert(id) }
        }

        // Phase B: targeted thread/review fetch for the stale set only.
        var fresh: [String: ReviewInfo] = [:]
        if let qB = queryPhaseB(stale) {
            do {
                let (dataB, remB, resetB) = try await post(qB, token: resolved.token)
                if remB != nil { remLast = remB }
                if resetB != nil { resetLast = resetB }
                let dec = try JSONDecoder().decode(PhaseBResponse.self, from: dataB)
                for (i, node) in stale.enumerated() {
                    guard let id = node.ghId, let n = dec.data?.byAlias["p\(i)"] else { continue }
                    fresh[id] = n.reviewInfo(viewer: viewer)
                }
            } catch {
                // Phase B failed (rate limit / network): keep phase-A data, fall back to
                // cached thread info below rather than dropping the whole poll.
            }
        }

        // Assemble PRs (fresh info for stale, cached info otherwise) and rebuild the cache.
        var prs: [PullRequest] = []
        var newCache: [String: CachedReview] = [:]
        for id in order {
            guard let node = nodeById[id] else { continue }
            let isStale = staleSet.contains(id)
            let info = isStale
                ? (fresh[id] ?? cache[id]?.info ?? ReviewInfo())
                : (cache[id]?.info ?? ReviewInfo())
            guard var pr = node.toPullRequest(info: info) else { continue }
            pr.relations = relationsById[id] ?? []
            pr.behindBy = behindById[id]
            prs.append(pr)
            newCache[id] = CachedReview(
                updatedAt: Self.cacheStamp(nodeUpdatedAt: node.updatedAt, wasStale: isStale,
                                           gotFresh: fresh[id] != nil, previous: cache[id]?.updatedAt),
                info: info)
        }
        return ProviderResult(prs: prs, viewerLogin: viewer, source: resolved.source,
                              rateLimitRemaining: remLast, rateLimitResetAt: resetLast,
                              threadCache: newCache)
    }

    /// The `updatedAt` to store in the review cache. A stale PR whose fresh fetch failed
    /// (phase-B error / missing alias) keeps its OLD stamp so it is retried next poll —
    /// stamping it with the new value would freeze its cached info until the PR moves again.
    static func cacheStamp(nodeUpdatedAt: String?, wasStale: Bool, gotFresh: Bool, previous: String?) -> String? {
        wasStale && !gotFresh ? previous : nodeUpdatedAt
    }

    /// POST a GraphQL query, parse rate-limit headers, and translate HTTP failures.
    private func post(_ query: String, token: String) async throws -> (Data, Int?, Date?) {
        var req = URLRequest(url: URL(string: "https://api.github.com/graphql")!)
        req.httpMethod = "POST"
        req.setValue("bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("PR-Watch", forHTTPHeaderField: "User-Agent")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["query": query])

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
        return (data, remaining, resetAt)
    }

    // MARK: - Query building

    /// Phase A: the PR list with light fields only (no reviews / threads).
    /// Each search bucket caps at 40 PRs — beyond that the excess is silently unwatched.
    private func queryPhaseA() -> String? {
        var blocks: [String] = []
        if authored {
            blocks.append("authored: search(query: \"\(qString("author:@me"))\", type: ISSUE, first: 40) { nodes { ... on PullRequest { \(Self.lightFields) } } }")
        }
        if reviewRequested {
            // review-requested = direct + team; user-review-requested = direct only.
            // The set difference tells us which reviews are via a team.
            blocks.append("reviewRequested: search(query: \"\(qString("review-requested:@me"))\", type: ISSUE, first: 40) { nodes { ... on PullRequest { \(Self.lightFields) } } }")
            blocks.append("reviewDirect: search(query: \"\(qString("user-review-requested:@me"))\", type: ISSUE, first: 40) { nodes { ... on PullRequest { \(Self.lightFields) } } }")
        }
        if mentioned {
            blocks.append("mentioned: search(query: \"\(qString("mentions:@me"))\", type: ISSUE, first: 40) { nodes { ... on PullRequest { \(Self.lightFields) } } }")
        }
        for (i, raw) in customPRs.enumerated() {
            guard let p = Self.parsePR(raw),
                  let owner = Self.safeName(p.owner), let repo = Self.safeName(p.repo) else { continue }
            blocks.append("c\(i): repository(owner: \"\(owner)\", name: \"\(repo)\") { pullRequest(number: \(p.number)) { \(Self.lightFields) } }")
        }
        guard !blocks.isEmpty else { return nil }
        return "query { viewer { login } \(blocks.joined(separator: " ")) }"
    }

    /// Phase B: reviews + threads for just the stale PRs, one aliased block each.
    private func queryPhaseB(_ stale: [GraphQLResponse.Node]) -> String? {
        var blocks: [String] = []
        for (i, node) in stale.enumerated() {
            guard let number = node.number,
                  let repo = node.repository?.nameWithOwner else { continue }
            let parts = repo.split(separator: "/", maxSplits: 1)
            guard parts.count == 2 else { continue }
            blocks.append("p\(i): repository(owner: \"\(parts[0])\", name: \"\(parts[1])\") { pullRequest(number: \(number)) { \(Self.threadFields) } }")
        }
        guard !blocks.isEmpty else { return nil }
        return "query { \(blocks.joined(separator: " ")) }"
    }

    private func queryBehindCounts(_ nodes: [GraphQLResponse.Node]) -> String? {
        var blocks: [String] = []
        for (index, node) in nodes.enumerated() {
            guard let number = node.number,
                  let repo = node.repository?.nameWithOwner,
                  let head = node.comparisonHead else { continue }
            let parts = repo.split(separator: "/", maxSplits: 1)
            guard parts.count == 2 else { continue }
            blocks.append("""
            b\(index): repository(owner: "\(parts[0])", name: "\(parts[1])") {
              pullRequest(number: \(number)) {
                baseRef {
                  compare(headRef: "\(Self.escapeGraphQL(head))") { behindBy }
                }
              }
            }
            """)
        }
        guard !blocks.isEmpty else { return nil }
        return "query { \(blocks.joined(separator: " ")) }"
    }

    private static func escapeGraphQL(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private func qString(_ who: String) -> String {
        // Multiple `repo:` qualifiers are OR-ed by GitHub search.
        var terms = ["is:open", "is:pr", who]
        terms += repoFilters.compactMap(Self.safeName).map { "repo:\($0)" }
        return terms.joined(separator: " ")
    }

    /// Queries are built by string interpolation, so only identifier-safe settings values
    /// may pass through — a stray quote/backslash must not break the whole query.
    static func safeName(_ s: String) -> String? {
        let ok = !s.isEmpty && s.allSatisfy { $0.isLetter || $0.isNumber || "._-/".contains($0) }
        return ok ? s : nil
    }

    /// Phase A — cheap fields fetched for every PR each poll. Excludes reviews/threads,
    /// but keeps CI and mergeable, which can change *without* bumping `updatedAt`.
    private static let lightFields = """
    number title url isDraft headRefName baseRefName additions deletions updatedAt isCrossRepository
    headRepositoryOwner { login }
    author { login }
    repository { nameWithOwner }
    reviewDecision
    reviewRequests(first: 10) { nodes { requestedReviewer { __typename ... on User { login } ... on Team { slug } } } }
    labels(first: 10) { nodes { name } }
    comments { totalCount }
    mergeable
    commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
    """

    /// Phase B — the expensive nested connections, fetched only for stale PRs. The
    /// `first:` caps silently truncate very busy PRs (>8 open threads undercount).
    /// `opening`/`latest` alias the thread's first and last comment: who opened the
    /// thread (participation) and who spoke last (whose turn it is).
    private static let threadFields = """
    author { login }
    latestReviews(first: 10) { nodes { author { login __typename } state } }
    reviewThreads(first: 8) { nodes { isResolved opening: comments(first: 1) { nodes { author { login __typename } } } latest: comments(last: 1) { nodes { author { login __typename } } } } }
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
        let isCrossRepository: Bool?
        let headRepositoryOwner: Author?
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
                let opening: Comments?
                let latest: Comments?
                struct Comments: Decodable { let nodes: [ReviewNode]; struct ReviewNode: Decodable { let author: Author? } }
                var firstAuthor: Author? { opening?.nodes.first?.author }
                var lastAuthor: Author? { latest?.nodes.last?.author }
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

        /// Stable id from the light fields alone (available in both fetch phases).
        var ghId: String? {
            guard let number, let repo = repository?.nameWithOwner else { return nil }
            return "github:\(repo)#\(number)"
        }

        var comparisonHead: String? {
            guard let headRefName else { return nil }
            if isCrossRepository == true, let owner = headRepositoryOwner?.login {
                return "\(owner):\(headRefName)"
            }
            return headRefName
        }

        /// Derive review/thread state from the phase-B connections.
        func reviewInfo(viewer: String?) -> ReviewInfo {
            let reviews = latestReviews?.nodes ?? []
            let approvers = reviews.filter { $0.state == "APPROVED" }.compactMap { $0.author?.login }
            let changeRequesters = reviews.filter { $0.state == "CHANGES_REQUESTED" }.compactMap { $0.author?.login }
            let commented = reviews
                .filter { $0.state == "COMMENTED" && $0.author?.isBot == false }
                .compactMap { $0.author?.login }
                .filter { !approvers.contains($0) && !changeRequesters.contains($0) }

            let unresolved = (reviewThreads?.nodes ?? []).filter { !$0.isResolved }
            let awaiting = unresolved.filter { thread in
                threadAwaitsReply(viewer: viewer, prAuthor: author?.login,
                                  firstAuthor: thread.firstAuthor?.login,
                                  lastAuthor: thread.lastAuthor?.login,
                                  lastIsBot: thread.lastAuthor?.isBot ?? false)
            }
            return ReviewInfo(
                approvers: approvers, changeRequesters: changeRequesters,
                commentedReviewers: commented,
                unresolvedThreads: unresolved.count, awaitingMyReply: awaiting.count)
        }

        /// Build a `PullRequest` from the phase-A light fields plus cached/fresh `ReviewInfo`.
        func toPullRequest(info: ReviewInfo) -> PullRequest? {
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
                ciState: commits?.nodes.first?.commit.statusCheckRollup?.state,
                approvers: info.approvers,
                changeRequesters: info.changeRequesters,
                pendingReviewers: (reviewRequests?.nodes ?? []).compactMap { $0.requestedReviewer?.login ?? $0.requestedReviewer?.slug },
                baseBranch: baseRefName,
                additions: additions,
                deletions: deletions,
                labels: (labels?.nodes ?? []).map(\.name),
                comments: comments?.totalCount,
                updatedAt: updatedAt,
                commentedReviewers: info.commentedReviewers,
                unresolvedThreads: info.unresolvedThreads,
                awaitingMyReply: info.awaitingMyReply
            )
        }
    }
}

private struct BehindResponse: Decodable {
    let data: DataBlock?

    struct DataBlock: Decodable {
        var byAlias: [String: Int] = [:]

        private struct Key: CodingKey {
            var stringValue: String
            init?(stringValue: String) { self.stringValue = stringValue }
            var intValue: Int? { nil }
            init?(intValue: Int) { nil }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Key.self)
            for key in container.allKeys {
                guard let repo = try? container.decode(RepoBlock.self, forKey: key),
                      let count = repo.pullRequest?.baseRef?.compare?.behindBy else { continue }
                byAlias[key.stringValue] = count
            }
        }
    }

    struct RepoBlock: Decodable { let pullRequest: PullRequestBlock? }
    struct PullRequestBlock: Decodable { let baseRef: BaseRef? }
    struct BaseRef: Decodable { let compare: Comparison? }
    struct Comparison: Decodable { let behindBy: Int }
}

// MARK: - Phase B decoding

/// Response for the targeted thread/review query: dynamic `p<N>` repository aliases.
private struct PhaseBResponse: Decodable {
    let data: DataB?
    let errors: [GraphQLResponse.GQLError]?

    struct DataB: Decodable {
        var byAlias: [String: GraphQLResponse.Node] = [:]
        private struct Key: CodingKey {
            var stringValue: String
            init?(stringValue: String) { self.stringValue = stringValue }
            var intValue: Int? { nil }
            init?(intValue: Int) { nil }
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Key.self)
            for key in c.allKeys {
                if let repo = try? c.decode(GraphQLResponse.RepoBlock.self, forKey: key),
                   let pr = repo.pullRequest {
                    byAlias[key.stringValue] = pr
                }
            }
        }
    }
}
