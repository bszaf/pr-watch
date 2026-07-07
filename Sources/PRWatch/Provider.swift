import Foundation

/// A code-hosting provider. The app fetches from every enabled provider concurrently
/// and merges the results into one set of `PullRequest`s.
enum Provider: String, Codable, Sendable, CaseIterable, Identifiable {
    case github
    case gitlab

    var id: String { rawValue }
    var label: String { self == .github ? "GitHub" : "GitLab" }
    var cliName: String { self == .github ? "gh" : "glab" }
    var keychainAccount: String { self == .github ? "github-pat" : "gitlab-pat" }
}

/// Where a provider's token came from — used for the Preferences status line.
enum TokenSource: Sendable {
    case keychain     // pasted PAT
    case cli          // gh / glab
    case env          // GITHUB_TOKEN / GITLAB_TOKEN
    case none
}

struct ResolvedToken: Sendable {
    let token: String
    let source: TokenSource
}

/// A provider's current auth/fetch state, surfaced in Preferences.
struct ProviderStatus: Sendable, Equatable {
    var enabled: Bool
    var source: TokenSource
    var user: String?
    var error: String?

    /// e.g. "gh — user:bszaf", "PAT — user:bszaf", or "gitlab — no CLI".
    func summary(for provider: Provider) -> String {
        switch source {
        case .cli: return "\(provider.cliName) — user:\(user ?? "?")"
        case .keychain: return "PAT — user:\(user ?? "?")"
        case .env: return "env token — user:\(user ?? "?")"
        case .none: return "\(provider.rawValue) — no CLI"
        }
    }

    static func == (l: ProviderStatus, r: ProviderStatus) -> Bool {
        l.enabled == r.enabled && l.user == r.user && l.error == r.error
    }
}

struct ProviderResult: Sendable {
    let prs: [PullRequest]
    let viewerLogin: String?
    let source: TokenSource
}
