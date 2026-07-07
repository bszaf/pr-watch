import Foundation

/// Fetches the signed-in user's open Merge Requests from GitLab (gitlab.com or a
/// self-managed host) and maps them onto the shared `PullRequest` model.
struct GitLabClient {
    let authored: Bool
    let reviewRequested: Bool
    let repoFilter: String     // client-side filter on project fullPath ("" = all)
    let host: String           // base URL, e.g. "https://gitlab.com"

    init(authored: Bool, reviewRequested: Bool, repoFilter: String, host: String) {
        self.authored = authored
        self.reviewRequested = reviewRequested
        self.repoFilter = repoFilter.trimmingCharacters(in: .whitespaces)
        let trimmed = host.trimmingCharacters(in: .whitespaces)
        self.host = trimmed.isEmpty ? "https://gitlab.com" : trimmed
    }

    private var hostname: String { URL(string: host)?.host ?? "gitlab.com" }

    // MARK: - Token resolution

    /// 1) Keychain PAT  2) `glab auth token`  3) `glab config get token`  4) GITLAB_TOKEN env.
    func resolveToken() -> ResolvedToken? {
        if let pat = Keychain.readToken(account: Provider.gitlab.keychainAccount) {
            return ResolvedToken(token: pat, source: .keychain)
        }
        if let t = run("/bin/zsh", ["-lc", "glab auth token -h \(hostname)"]) { return ResolvedToken(token: t, source: .cli) }
        for path in ["/opt/homebrew/bin/glab", "/usr/local/bin/glab"] where FileManager.default.isExecutableFile(atPath: path) {
            if let t = run(path, ["config", "get", "token", "-h", hostname]) { return ResolvedToken(token: t, source: .cli) }
        }
        if let env = ProcessInfo.processInfo.environment["GITLAB_TOKEN"], !env.isEmpty {
            return ResolvedToken(token: env, source: .env)
        }
        return nil
    }

    private func run(_ launch: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launch)
        p.arguments = args
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

    // MARK: - Fetch

    func fetch() async throws -> ProviderResult {
        guard authored || reviewRequested else { return ProviderResult(prs: [], viewerLogin: nil, source: .none) }
        // No token isn't an error — GitLab is just "not configured" (shows "no CLI").
        guard let resolved = resolveToken() else { return ProviderResult(prs: [], viewerLogin: nil, source: .none) }
        guard let url = URL(string: "\(host)/api/graphql") else { throw GitHubError.transport("bad GitLab host") }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(resolved.token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["query": query()])

        let (data, resp): (Data, URLResponse)
        do {
            (data, resp) = try await URLSession.shared.data(for: req)
        } catch {
            throw GitHubError.transport(error.localizedDescription)
        }
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            throw GitHubError.http(http.statusCode, String(decoding: data, as: UTF8.self))
        }

        let decoded = try JSONDecoder().decode(GLResponse.self, from: data)
        if let errors = decoded.errors, !errors.isEmpty, decoded.data?.currentUser == nil {
            throw GitHubError.graphql(errors.map(\.message).joined(separator: "; "))
        }
        guard let user = decoded.data?.currentUser else {
            throw GitHubError.graphql("no currentUser (token missing read_api scope?)")
        }

        var seen = Set<String>()
        var result: [PullRequest] = []
        for node in (user.authored?.nodes ?? []) + (user.reviewRequested?.nodes ?? []) {
            guard let pr = node.toPullRequest() else { continue }
            if !repoFilter.isEmpty, pr.repo != repoFilter { continue }
            if seen.insert(pr.id).inserted { result.append(pr) }
        }
        return ProviderResult(prs: result, viewerLogin: user.username, source: resolved.source)
    }

    // MARK: - Query

    private func query() -> String {
        var blocks: [String] = []
        if authored { blocks.append("authored: authoredMergeRequests(state: opened, first: 40) { nodes { \(Self.mrFields) } }") }
        if reviewRequested { blocks.append("reviewRequested: reviewRequestedMergeRequests(state: opened, first: 40) { nodes { \(Self.mrFields) } }") }
        return "query { currentUser { username \(blocks.joined(separator: " ")) } }"
    }

    private static let mrFields = """
    iid title webUrl draft conflicts approved
    author { username }
    project { fullPath }
    headPipeline { status }
    """
}

// MARK: - Decoding + mapping

private struct GLResponse: Decodable {
    let data: DataBlock?
    let errors: [GLError]?
    struct GLError: Decodable { let message: String }
    struct DataBlock: Decodable { let currentUser: CurrentUser? }
    struct CurrentUser: Decodable {
        let username: String?
        let authored: MRList?
        let reviewRequested: MRList?
    }
    struct MRList: Decodable { let nodes: [Node] }

    struct Node: Decodable {
        let iid: String?
        let title: String?
        let webUrl: String?
        let draft: Bool?
        let conflicts: Bool?
        let approved: Bool?
        let author: Author?
        let project: Project?
        let headPipeline: Pipeline?

        struct Author: Decodable { let username: String? }
        struct Project: Decodable { let fullPath: String }
        struct Pipeline: Decodable { let status: String? }

        func toPullRequest() -> PullRequest? {
            guard let iidStr = iid, let number = Int(iidStr),
                  let title, let url = webUrl, let repo = project?.fullPath else { return nil }
            return PullRequest(
                id: "gitlab:\(repo)#\(number)",
                provider: .gitlab,
                number: number,
                title: title,
                url: url,
                isDraft: draft ?? false,
                repo: repo,
                author: author?.username ?? "",
                reviewDecision: (approved == true) ? .approved : nil,
                mergeable: (conflicts == true) ? .conflicting : .mergeable,
                ciState: Self.mapCI(headPipeline?.status)
            )
        }

        /// Map a GitLab pipeline status string to the shared CheckState.
        static func mapCI(_ status: String?) -> CheckState? {
            switch status {
            case "SUCCESS": .success
            case "SKIPPED": .success
            case "FAILED": .failure
            case "CANCELED": .error
            case "RUNNING", "PENDING", "CREATED", "PREPARING",
                 "SCHEDULED", "WAITING_FOR_RESOURCE", "MANUAL": .pending
            default: nil
            }
        }
    }
}
