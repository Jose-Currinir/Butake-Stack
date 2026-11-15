import Foundation

/// A connected account: who it is, never its token. This is what the Keychain item keeps in its
/// attributes, so listing accounts reads no secret and asks macOS for nothing.
struct GitHostingAccount: Codable, Hashable, Identifiable, Sendable {
    var provider: GitHostingProvider
    /// GitHub's user name, or Bitbucket's.
    var login: String
    /// The name the provider shows, when it has one.
    var name: String
    /// Bitbucket: the Atlassian account's email, which goes with the token (not a secret).
    var email: String
    var id: String { "\(provider.rawValue)/\(login)" }
    var display: String { name.isEmpty || name == login ? login : "\(name) (\(login))" }
}

/// A token and, for Bitbucket, its email: in memory only, for the request being made. It never
/// prints its token (`description`), so it cannot end up in a log by accident.
struct GitHostingCredentials: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let email: String
    let token: String
    var description: String { "GitHostingCredentials(••••)" }
    var debugDescription: String { description }
}

/// A failure of the provider's API in plain words. Fixed codes; the detail is the provider's own
/// short message (never a request, a header or a token).
struct GitHostingFailure: Error, Equatable, Sendable, LocalizedError {
    enum Code: String, Sendable, CaseIterable {
        /// No account of that provider: the tab leads to Ajustes › Cuentas.
        case noAccount
        /// The token was refused (expired, revoked, mistyped).
        case unauthorized
        /// The token lacks a permission.
        case forbidden
        case notFound
        /// The provider refused the change (a repository that exists, a pull request already open…).
        case rejected
        /// Too many requests: wait a moment.
        case rateLimited
        /// No connection, or the provider did not answer.
        case offline
        /// macOS did not give the token (the user denied access to the Keychain).
        case keychain
        /// An answer the tool cannot read, or a request it refuses to send.
        case invalid
    }
    let code: Code
    let provider: GitHostingProvider?
    let detail: String

    init(_ code: Code, provider: GitHostingProvider? = nil, detail: String = "") {
        self.code = code; self.provider = provider; self.detail = detail
    }

    var title: String { String(format: L("git.hosting.error.\(code.rawValue)"), provider?.title ?? L("git.hosting.provider")) }
    var errorDescription: String? { detail.isEmpty ? title : "\(title)\n\(detail)" }
}

/// The state of a pull request.
enum GitPullRequestState: String, CaseIterable, Identifiable, Sendable {
    case open, merged, closed
    var id: String { rawValue }
    var title: String { L("git.pr.state.\(rawValue)") }
}

/// A pull request, the same for both providers.
struct GitPullRequest: Identifiable, Hashable, Sendable {
    var id: Int
    var title: String
    var body: String
    var state: GitPullRequestState
    var draft: Bool
    var author: String
    /// The branch it brings, and the one it goes into.
    var source: String
    var target: String
    /// The last commit of `source`, for its checks.
    var head: String?
    var page: URL?
    var updated: Date?
}

/// A comment of the conversation, or of a line of a file (`path`, `line`).
struct GitPullRequestComment: Identifiable, Hashable, Sendable {
    var id: String
    var author: String
    var body: String
    var created: Date?
    var path: String?
    var line: Int?
}

/// What a reviewer said last.
struct GitPullRequestReview: Identifiable, Hashable, Sendable {
    enum Verdict: String, Sendable { case approved, changesRequested, commented }
    var author: String
    var verdict: Verdict
    var id: String { author }
}

/// A check of a commit: GitHub's check runs, Bitbucket's build statuses.
struct GitHostingCheck: Identifiable, Hashable, Sendable {
    enum State: String, Sendable { case success, failure, pending, skipped }
    var id: String
    var name: String
    var state: State
    var page: URL?
}

/// A repository the account can clone.
struct GitHostingRemoteRepository: Identifiable, Hashable, Sendable {
    var provider: GitHostingProvider
    /// `owner/name`
    var fullName: String
    var ssh: String
    var https: String
    var isPrivate: Bool
    var summary: String
    var updated: Date?
    var id: String { "\(provider.rawValue):\(fullName)" }
}

/// Whether the provider protects a branch from direct pushes.
enum GitHostingProtection: Equatable, Sendable {
    case protected, open
    /// The token cannot read the rules (the cached value is cleared).
    case unknown
    /// The provider did not answer (the cached value stays).
    case unreachable
}

/// Dates of both providers: «…Z» (GitHub) and «….123456+00:00» (Bitbucket).
func gitHostingDate(_ text: String?) -> Date? {
    guard let text else { return nil }
    let plain = ISO8601DateFormatter()
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = plain.date(from: text) ?? fractional.date(from: text) { return date }
    // Six fractional digits: keep three.
    if let dot = text.firstIndex(of: "."), let zone = text[dot...].firstIndex(where: { "+-Z".contains($0) }) {
        return fractional.date(from: String(text[..<dot]) + String(text[dot..<zone].prefix(4)) + String(text[zone...]))
    }
    return nil
}
