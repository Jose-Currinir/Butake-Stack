import Foundation

/// The code hosting services the Git tool talks to through their web API (pull requests, checks,
/// repositories of the account). Git itself works with any remote; these add what lives on the
/// provider. Only GitHub and Bitbucket Cloud.
enum GitHostingProvider: String, CaseIterable, Identifiable, Codable, Sendable {
    case github, bitbucket

    var id: String { rawValue }
    /// The provider's own name (a proper noun, the same in every language).
    var title: String { self == .github ? "GitHub" : "Bitbucket Cloud" }
    /// Bitbucket's API tokens go with the Atlassian account's email; GitHub's stand alone.
    var needsEmail: Bool { self == .bitbucket }
    /// Where the user creates the token, on the provider's own site.
    var tokenPage: URL {
        switch self {
        case .github: URL(string: "https://github.com/settings/personal-access-tokens/new")!
        case .bitbucket: URL(string: "https://id.atlassian.com/manage-profile/security/api-tokens")!
        }
    }
    /// The minimum permissions, by the names the provider's page uses (texts `git.hosting.permission.<provider>.<n>`).
    static let permissionCount = 7
    func permission(_ index: Int) -> String { L("git.hosting.permission.\(rawValue).\(index)") }
}

/// Where each provider's API and website are. The real ones in the app; a local fake server in
/// tests and QA (`GitHostingEndpoints.loopback`), so nothing reaches the real providers.
struct GitHostingEndpoints: Equatable, Sendable {
    /// The API's base URL, ending in «/».
    var api: [GitHostingProvider: URL]
    /// The host of the website and of the clone addresses (`github.com`).
    var web: [GitHostingProvider: String]

    static let production = GitHostingEndpoints(
        api: [.github: URL(string: "https://api.github.com/")!, .bitbucket: URL(string: "https://api.bitbucket.org/2.0/")!],
        web: [.github: "github.com", .bitbucket: "bitbucket.org"])

    /// A fake server on this Mac: the API under `http://127.0.0.1:<port>/<provider>/` and made-up
    /// web hosts that never resolve (`.invalid`).
    static func loopback(port: UInt16) -> GitHostingEndpoints {
        GitHostingEndpoints(
            api: [.github: URL(string: "http://127.0.0.1:\(port)/github/")!, .bitbucket: URL(string: "http://127.0.0.1:\(port)/bitbucket/")!],
            web: [.github: "github.fake.invalid", .bitbucket: "bitbucket.fake.invalid"])
    }

    func apiBase(_ provider: GitHostingProvider) -> URL { api[provider] ?? Self.production.api[provider]! }
    func webHost(_ provider: GitHostingProvider) -> String { web[provider] ?? Self.production.web[provider]! }

    /// A request may only go to the provider's own API: HTTPS to its host, or plain HTTP to this
    /// Mac's loopback address (the fake server). Anything else is refused before it leaves.
    func allows(_ url: URL, for provider: GitHostingProvider) -> Bool {
        let base = apiBase(provider)
        guard url.host == base.host, url.port == base.port, url.scheme == base.scheme, url.path.hasPrefix(base.path) else { return false }
        return url.scheme == "https" || (url.scheme == "http" && url.host == "127.0.0.1")
    }
}

/// `owner/name` of a repository on a provider, read strictly from a remote's address
/// (`git@github.com:owner/name.git`, `https://bitbucket.org/owner/name.git`…).
struct GitHostedRepository: Hashable, Sendable {
    var provider: GitHostingProvider
    var owner: String
    var name: String
    var path: String { "\(owner)/\(name)" }

    /// Nil for a remote of another server, or one whose path is not exactly `owner/name`.
    init?(remote: String, endpoints: GitHostingEndpoints) {
        var value = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        // «https://usuario@bitbucket.org/…» (Bitbucket's own clone address): the user is not part
        // of the repository. A password («usuario:clave@») is never accepted.
        if value.lowercased().hasPrefix("https://"), let at = value.firstIndex(of: "@") {
            let start = value.index(value.startIndex, offsetBy: 8)
            let slash = value[start...].firstIndex(of: "/") ?? value.endIndex
            if at < slash {
                guard !value[start..<at].contains(":") else { return nil }
                value = "https://" + value[value.index(after: at)...]
            }
        }
        let lowered = value.lowercased()
        var found: (GitHostingProvider, String)?
        for provider in GitHostingProvider.allCases {
            let host = endpoints.webHost(provider).lowercased()
            let hosts = [host] + (host == "github.com" ? ["ssh.github.com"] : host == "bitbucket.org" ? ["altssh.bitbucket.org"] : [])
            for candidate in hosts {
                for prefix in ["git@\(candidate):", "https://\(candidate)/", "ssh://git@\(candidate)/", "ssh://git@\(candidate):22/", "ssh://git@\(candidate):443/"]
                where lowered.hasPrefix(prefix) {
                    found = (provider, String(value.dropFirst(prefix.count)))
                }
            }
        }
        guard let (provider, raw) = found else { return nil }
        var path = raw
        if path.hasSuffix("/") { path.removeLast() }
        if path.hasSuffix(".git") { path.removeLast(4) }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, parts.allSatisfy(GitHostedRepository.validPart) else { return nil }
        self.provider = provider
        owner = parts[0]
        name = parts[1]
    }

    init(provider: GitHostingProvider, owner: String, name: String) {
        self.provider = provider; self.owner = owner; self.name = name
    }

    /// Letters, digits, «-», «_» and «.», never «.» or «..» alone: safe inside an API path.
    static func validPart(_ part: String) -> Bool {
        !part.isEmpty && part != "." && part != ".." && part.count <= 100
            && part.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }
    }

    /// The repository's page on the provider's website.
    func webPage(_ endpoints: GitHostingEndpoints) -> URL? { URL(string: "https://\(endpoints.webHost(provider))/\(path)") }

    /// The SSH and HTTPS clone addresses of a repository on this provider.
    static func cloneAddresses(provider: GitHostingProvider, path: String, endpoints: GitHostingEndpoints) -> (ssh: String, https: String) {
        let host = endpoints.webHost(provider)
        return ("git@\(host):\(path).git", "https://\(host)/\(path).git")
    }
}
