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
        if let t = runCapturing("/bin/zsh", ["-lc", "gh auth token"]) { return ResolvedToken(token: t, source: .cli) }
        for path in ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"] where FileManager.default.isExecutableFile(atPath: path) {
            if let t = runCapturing(path, ["auth", "token"]) { return ResolvedToken(token: t, source: .cli) }
        }
        if let env = ProcessInfo.processInfo.environment["GITHUB_TOKEN"], !env.isEmpty {
            return ResolvedToken(token: env, source: .env)
        }
        return nil
    }

    // MARK: - Fetch

    /// Two-phase fetch. Phase A lists every watched PR with the *light* fields (identity,
    /// CI, review-decision, mergeable) that can change without bumping `updatedAt`. Phase B
    /// then fetches the expensive review threads / reviews ONLY for PRs that are new, whose
    /// `updatedAt` moved, or that still have open threads (a resolution may not bump
    /// `updatedAt`, so we re-check those to detect it clearing). Everything else reuses the
    /// per-PR `cache`, keeping typical polls far under the GraphQL rate budget.
    /// `known` = GitHub PR ids seen open last time; any now missing are checked for merged/closed
    /// in the same phase-B request.
    /// Failing PRs also get their check list in phase B, re-fetched only when `checksCache`'s key
    /// (head commit + per-state check counts) moved.
    func fetch(cache: [String: CachedReview], checksCache: [String: CachedChecks] = [:],
               known: Set<String> = []) async throws -> ProviderResult {
        guard let qA = queryPhaseA() else { return ProviderResult(prs: [], viewerLogin: nil, source: .none) }
        // No token isn't an error — GitHub is just "not configured" (matches GitLab).
        guard var resolved = await runBlocking({ Self.resolveToken() }) else { return ProviderResult(prs: [], viewerLogin: nil, source: .none) }

        var (dataA, remA, resetA): (Data, Int?, Date?)
        do {
            (dataA, remA, resetA) = try await post(qA, token: resolved.token)
        } catch GitHubError.http(401, _) {
            // Stale cached token (e.g. expired gh OAuth token) — re-resolve once and retry.
            Self.invalidateTokenCache()
            guard let refreshed = await runBlocking({ Self.resolveToken() }) else { throw GitHubError.http(401, "token expired") }
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

        let vanished = known.subtracting(order).sorted()
        let needChecks = order.compactMap { id -> GraphQLResponse.Node? in
            guard let node = nodeById[id], node.rollupState?.isFailure == true,
                  let key = node.checksKey, checksCache[id]?.key != key else { return nil }
            return node
        }

        // Phase B: targeted thread/review fetch for the stale set only, plus vanished PRs' final state.
        var fresh: [String: ReviewInfo] = [:]
        var finals: [String: PRFinalState]?
        var remLast = remA, resetLast = resetA
        var freshChecks: [String: CachedChecks] = [:]
        if let qB = queryPhaseB(stale, vanished: vanished, checks: needChecks) {
            do {
                let (dataB, remB, resetB) = try await post(qB, token: resolved.token)
                if remB != nil { remLast = remB }
                if resetB != nil { resetLast = resetB }
                let dec = try JSONDecoder().decode(PhaseBResponse.self, from: dataB)
                for (i, node) in stale.enumerated() {
                    guard let id = node.ghId, let n = dec.data?.byAlias["p\(i)"] else { continue }
                    fresh[id] = n.reviewInfo(viewer: viewer)
                }
                var got: [String: PRFinalState] = [:]
                for (i, id) in vanished.enumerated() {
                    guard let n = dec.data?.byAlias["v\(i)"], let state = n.state,
                          let title = n.title, let url = n.url else { continue }
                    got[id] = PRFinalState(state: state, mergedAt: n.mergedAt, closedAt: n.closedAt,
                                           title: title, url: url, author: n.author?.login)
                }
                finals = got
                for (i, node) in needChecks.enumerated() {
                    guard let id = node.ghId, let key = node.checksKey,
                          let contexts = dec.data?.byAlias["k\(i)"]?.commits?.nodes.first?.commit.statusCheckRollup?.contexts
                    else { continue }
                    freshChecks[id] = CachedChecks(key: key, checks: Self.checks(from: contexts.nodes ?? []),
                                                   complete: contexts.pageInfo?.hasNextPage != true)
                }
            } catch {
                // Phase B failed (rate limit / network): keep phase-A data, fall back to
                // cached thread info below rather than dropping the whole poll.
            }
        }

        // Assemble PRs (fresh info for stale, cached info otherwise) and rebuild the cache.
        var prs: [PullRequest] = []
        var newCache: [String: CachedReview] = [:]
        var newChecks: [String: CachedChecks] = [:]
        for id in order {
            guard let node = nodeById[id] else { continue }
            let isStale = staleSet.contains(id)
            let info = isStale
                ? (fresh[id] ?? cache[id]?.info ?? ReviewInfo())
                : (cache[id]?.info ?? ReviewInfo())
            guard var pr = node.toPullRequest(info: info) else { continue }
            pr.relations = relationsById[id] ?? []
            if let c = freshChecks[id] ?? checksCache[id] {
                newChecks[id] = c
                if c.key == node.checksKey { pr.checks = c.checks; pr.checksComplete = c.complete }
            }
            prs.append(pr)
            newCache[id] = CachedReview(
                updatedAt: Self.cacheStamp(nodeUpdatedAt: node.updatedAt, wasStale: isStale,
                                           gotFresh: fresh[id] != nil, previous: cache[id]?.updatedAt),
                info: info)
        }
        let (closed, unresolved) = Self.resolveVanished(vanished, finals: finals)
        return ProviderResult(prs: prs, viewerLogin: viewer, source: resolved.source,
                              rateLimitRemaining: remLast, rateLimitResetAt: resetLast,
                              threadCache: newCache, checksCache: newChecks, closed: closed, unresolvedVanished: unresolved)
    }

    /// Split vanished ids by their fetched final state. `finals == nil` (phase B failed) leaves
    /// all of them unresolved for a retry; a PR still OPEN only left the watched set (filter,
    /// review un-requested) and an id with no data (deleted / no access) is dropped.
    static func resolveVanished(_ ids: [String], finals: [String: PRFinalState]?) -> (closed: [ClosedPR], unresolved: Set<String>) {
        guard let finals else { return ([], Set(ids)) }
        let closed = ids.compactMap { id -> ClosedPR? in
            guard let f = finals[id], f.state != "OPEN", let ref = parseId(id) else { return nil }
            let merged = f.state == "MERGED"
            let date = (merged ? f.mergedAt : f.closedAt).flatMap(parseISODate) ?? Date()
            return ClosedPR(id: id, repo: ref.repo, number: ref.number, title: f.title, url: f.url,
                            author: f.author ?? "", merged: merged, date: date)
        }
        return (closed, [])
    }

    /// "github:owner/repo#12" → ("owner/repo", 12).
    static func parseId(_ id: String) -> (repo: String, number: Int)? {
        guard id.hasPrefix("github:"), let hash = id.lastIndex(of: "#"),
              let n = Int(id[id.index(after: hash)...]) else { return nil }
        return (String(id[id.index(id.startIndex, offsetBy: 7)..<hash]), n)
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

    /// Phase B: reviews + threads for just the stale PRs, one aliased block each, plus the final
    /// state of vanished PRs.
    private func queryPhaseB(_ stale: [GraphQLResponse.Node], vanished: [String],
                             checks: [GraphQLResponse.Node]) -> String? {
        var blocks: [String] = []
        for (i, node) in stale.enumerated() {
            guard let number = node.number,
                  let repo = node.repository?.nameWithOwner else { continue }
            let parts = repo.split(separator: "/", maxSplits: 1)
            guard parts.count == 2 else { continue }
            blocks.append("p\(i): repository(owner: \"\(parts[0])\", name: \"\(parts[1])\") { pullRequest(number: \(number)) { \(Self.threadFields) } }")
        }
        for (i, id) in vanished.enumerated() {
            guard let ref = Self.parseId(id) else { continue }
            let parts = ref.repo.split(separator: "/", maxSplits: 1)
            guard parts.count == 2, let owner = Self.safeName(String(parts[0])),
                  let name = Self.safeName(String(parts[1])) else { continue }
            blocks.append("v\(i): repository(owner: \"\(owner)\", name: \"\(name)\") { pullRequest(number: \(ref.number)) { state mergedAt closedAt title url author { login } } }")
        }
        for (i, node) in checks.enumerated() {
            guard let number = node.number, let repo = node.repository?.nameWithOwner else { continue }
            let parts = repo.split(separator: "/", maxSplits: 1)
            guard parts.count == 2 else { continue }
            blocks.append("k\(i): repository(owner: \"\(parts[0])\", name: \"\(parts[1])\") { pullRequest(number: \(number)) { \(Self.checkFields) } }")
        }
        guard !blocks.isEmpty else { return nil }
        return "query { \(blocks.joined(separator: " ")) }"
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
    number title url isDraft headRefName baseRefName additions deletions updatedAt
    author { login }
    repository { nameWithOwner }
    reviewDecision
    reviewRequests(first: 10) { nodes { requestedReviewer { __typename ... on User { login } ... on Team { slug } } } }
    labels(first: 10) { nodes { name } }
    comments { totalCount }
    mergeable
    commits(last: 1) { nodes { commit { oid statusCheckRollup { state contexts(first: 0) { checkRunCountsByState { state count } statusContextCountsByState { state count } } } } } }
    """

    /// Phase B, failing PRs only: every check of the head commit. Busy repos run 50–70 checks.
    private static let checkFields = """
    commits(last: 1) { nodes { commit { statusCheckRollup { contexts(first: 100) { pageInfo { hasNextPage } nodes { __typename ... on CheckRun { name status conclusion detailsUrl title } ... on StatusContext { context state description targetUrl } } } } } } }
    """

    /// Head commit + non-zero per-state counts of check runs and commit statuses.
    static func checksKey(oid: String, runs: [(String, Int)], statuses: [(String, Int)]) -> String {
        let counts = runs.filter { $0.1 > 0 }.map { "run.\($0.0)=\($0.1)" }
            + statuses.filter { $0.1 > 0 }.map { "status.\($0.0)=\($0.1)" }
        return ([oid] + counts).joined(separator: " ")
    }

    /// Check runs settle as `status` COMPLETED + a `conclusion`; commit statuses carry a `state`.
    static func checks(from contexts: [GitHubCheckContext]) -> [CICheck] {
        contexts.compactMap { c in
            if c.typename == "StatusContext" {
                guard let name = c.context else { return nil }
                let state: CheckState = switch c.state {
                case "SUCCESS": .success
                case "FAILURE", "ERROR": .failure
                default: .pending
                }
                return CICheck(name: name, state: state, summary: c.description, url: c.targetUrl)
            }
            guard let name = c.name else { return nil }
            let state: CheckState = switch (c.status, c.conclusion) {
            case ("COMPLETED", "SUCCESS"), ("COMPLETED", "NEUTRAL"), ("COMPLETED", "SKIPPED"), ("COMPLETED", nil): .success
            case ("COMPLETED", _): .failure
            default: .pending
            }
            return CICheck(name: name, state: state, summary: c.title, url: c.detailsUrl)
        }
    }

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

/// A `statusCheckRollup` context: a `CheckRun` (name/status/conclusion) or a `StatusContext`
/// (context/state).
struct GitHubCheckContext: Decodable {
    var typename: String?
    var name: String?, status: String?, conclusion: String?, detailsUrl: String?, title: String?
    var context: String?, state: String?, description: String?, targetUrl: String?
    enum CodingKeys: String, CodingKey {
        case typename = "__typename", name, status, conclusion, detailsUrl, title
        case context, state, description, targetUrl
    }
}

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
        let state: String?
        let mergedAt: String?
        let closedAt: String?

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
                    let oid: String?
                    let statusCheckRollup: Rollup?
                    struct Rollup: Decodable { let state: CheckState?; let contexts: Contexts? }
                }
            }
        }

        struct Contexts: Decodable {
            let pageInfo: PageInfo?
            let nodes: [GitHubCheckContext]?
            let checkRunCountsByState: [StateCount]?
            let statusContextCountsByState: [StateCount]?
            struct PageInfo: Decodable { let hasNextPage: Bool }
            struct StateCount: Decodable { let state: String; let count: Int }
        }

        var rollupState: CheckState? { commits?.nodes.first?.commit.statusCheckRollup?.state }

        /// Changes whenever any check of the head commit changes state — the cue to re-fetch them.
        var checksKey: String? {
            guard let commit = commits?.nodes.first?.commit, let oid = commit.oid else { return nil }
            let c = commit.statusCheckRollup?.contexts
            return GitHubClient.checksKey(
                oid: oid,
                runs: (c?.checkRunCountsByState ?? []).map { ($0.state, $0.count) },
                statuses: (c?.statusContextCountsByState ?? []).map { ($0.state, $0.count) })
        }

        /// Stable id from the light fields alone (available in both fetch phases).
        var ghId: String? {
            guard let number, let repo = repository?.nameWithOwner else { return nil }
            return "github:\(repo)#\(number)"
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
                ciState: rollupState,
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
