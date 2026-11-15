import Foundation

/// `gcp` of a project: the Google Cloud account and project it works with. Not secret (an address
/// and a project id). The engine gives its processes and consoles `variables` (a value the project
/// sets by hand wins); gcloud's own configuration is never changed.
struct GCPLink: Codable, Hashable, Sendable {
    var account: String
    var project: String

    /// gcloud reads the first two over its active configuration; Google's libraries, the third.
    static let variables = ["CLOUDSDK_CORE_ACCOUNT", "CLOUDSDK_CORE_PROJECT", "GOOGLE_CLOUD_PROJECT"]
}

/// An account gcloud has on this Mac (engine/src/gcp/accounts.rs): its address, whether it is a
/// person's or a service account, and whether it is gcloud's active one.
struct GCPAccount: Decodable, Identifiable, Hashable, Sendable {
    enum Kind: String, Decodable, CaseIterable, Sendable {
        case user, service
        var symbol: String { self == .user ? Symbols.googleAccount : Symbols.serviceAccount }
        var title: String { L("gcp.kind.\(rawValue)") }
    }
    let account: String
    let kind: Kind
    let active: Bool
    var id: String { account }

    func matches(_ text: String) -> Bool { text.isEmpty || account.localizedCaseInsensitiveContains(text) }
}

/// A Google Cloud project an account reaches.
struct GCPProject: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String?
    let number: String?
    var title: String { name ?? id }
}

/// A Stack project linked to an account and a project of Google Cloud.
struct GCPProjectUse: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let account: String
    let project: String
}

/// `gcpAccounts`: gcloud on this Mac (or its absence), its accounts and the links.
struct GCPState: Decodable, Sendable {
    struct CLI: Decodable, Sendable { let installed: Bool; let path: String? }
    let cli: CLI
    let accounts: [GCPAccount]
    let links: [GCPProjectUse]
}

/// The pages of Google's consoles the tool opens for a project, with the account it belongs to
/// (`authuser`), so the browser opens them as that account when it is signed in there. A service
/// account cannot sign in to a browser: its pages open without it.
enum GCPConsolePage: String, CaseIterable, Sendable {
    case dashboard, credentials, firebase, billing

    var symbol: String {
        switch self {
        case .dashboard: Symbols.openInBrowser
        case .credentials: Symbols.oauthClients
        case .firebase: Symbols.firebase
        case .billing: Symbols.billing
        }
    }
    var title: String { L("gcp.console.\(rawValue)") }

    func url(project: String, account: String?) -> URL? {
        var components: URLComponents
        switch self {
        case .firebase:
            components = URLComponents(string: "https://console.firebase.google.com/")!
            components.path = "/project/\(project)/overview"
        default:
            components = URLComponents(string: "https://console.cloud.google.com/")!
            components.path = ["dashboard": "/home/dashboard", "credentials": "/apis/credentials", "billing": "/billing/linkedaccount"][rawValue] ?? "/"
        }
        var items: [URLQueryItem] = self == .firebase ? [] : [URLQueryItem(name: "project", value: project)]
        if let account, !account.hasSuffix(".gserviceaccount.com") { items.append(URLQueryItem(name: "authuser", value: account)) }
        components.queryItems = items.isEmpty ? nil : items
        return components.url
    }
}
