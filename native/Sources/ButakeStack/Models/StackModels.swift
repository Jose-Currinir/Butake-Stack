import Foundation

/// A site as stored by the engine (`projects/<id>.json`). Encodable so the UI can save edits.
struct Project: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var path: String
    var domains: [String]
    var https: Bool
    var kind: String
    var runtime: [String: String]
    var docroot: String
    var services: [String]
    var databases: [String]
    var processes: [ProjectProcess]
    var enabled: Bool
    /// Port of the site's own server that Caddy proxies to (Astro, EmDash, Next, KMP).
    var upstream: Int?
    /// Environment of the site's processes (`{port}` and `{domain}` filled in by the engine).
    var env: [String: String]?

    var domain: String { domains.first ?? "" }
    /// What the UI shows: the site's name; the `.test` address only appears as its URL.
    var title: String { name.isEmpty ? domain : name }
    var php: String? { runtime["php"] }
    var node: String? { runtime["node"] }
    var url: URL? { URL(string: "\(https ? "https" : "http")://\(domain)") }
}

struct ProjectProcess: Codable, Hashable, Identifiable, Sendable {
    var name: String
    var program: String
    var args: [String]
    var autostart: Bool
    var id: String { name }
    var commandLine: String { ([program] + args).joined(separator: " ") }
}

struct ProcessState: Decodable, Hashable, Sendable {
    let id: String
    let state: String
    let pid: Int?
    let restarts: Int
}
struct ProcessSpecSummary: Decodable, Hashable, Sendable {
    let id: String
    let executable: String
    let args: [String]
    let autostart: Bool
}
struct ProcessEntry: Decodable, Hashable, Identifiable, Sendable {
    let spec: ProcessSpecSummary
    let status: ProcessState
    var id: String { spec.id }
}
struct ListenerStatus: Decodable, Hashable, Sendable {
    let port: Int
    let mode: String
    let owner: String?
}
struct StackStatus: Decodable, Sendable {
    let listeners: [String: ListenerStatus]
    let processes: [ProcessEntry]
}

struct PhpManifestSummary: Decodable, Sendable, Hashable {
    let version: String
    let extensions: [String]
    let missingExtensions: [String]
    enum CodingKeys: String, CodingKey {
        case version, extensions
        case missingExtensions = "missing_extensions"
    }
}
struct PhpRuntimeSummary: Decodable, Identifiable, Sendable, Hashable {
    let series: String
    let installed: Bool
    let verified: Bool
    let manifest: PhpManifestSummary?
    var id: String { series }
}

struct ToolManifest: Decodable, Identifiable, Sendable, Hashable {
    let tool: String
    let version: String
    let url: String
    let sha256: String
    var id: String { "\(tool)-\(version)" }
}
struct AvailableVersion: Decodable, Identifiable, Sendable, Hashable {
    let version: String
    let label: String?
    let date: String?
    var id: String { version }
    var major: String { String(version.split(separator: ".").first ?? "") }
}

struct Detection: Decodable, Sendable {
    var project: Project
    let notes: [String]
}
struct EngineRecipe: Decodable, Sendable, Hashable { let id: String; let category: String; let port: Int }
struct AgentStatus: Decodable, Sendable { let installed: Bool; let loaded: Bool }
/// Process currently listening on 53, 80 and 443 (nil = free).
struct PortOwners: Decodable, Sendable { let dns: String?; let http: String?; let https: String? }

struct EngineConfig: Codable, Sendable, Hashable { var enabled: Bool; var version: String; var port: Int? }
struct StackConfig: Codable, Sendable {
    var tld: [String]
    var ports: Ports
    var versions: [String: String]
    var engines: [String: EngineConfig]? = nil
    struct Ports: Codable, Sendable { var http: Int; var https: Int; var dns: Int; var mysql: Int; var redis: Int }
}

enum ProcessPhase: String {
    case running, starting, stopping, stopped, crashed
    init(_ raw: String) { self = ProcessPhase(rawValue: raw) ?? .stopped }
}

/// A date, a yes/no flag or nothing: endoflife.date uses all three for lts/support/eol.
enum Flex: Decodable, Hashable, Sendable {
    case date(String), flag(Bool), none
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { self = .date(s) }
        else if let b = try? c.decode(Bool.self) { self = .flag(b) }
        else { self = .none }
    }
}

/// One release line (Node 22, PostgreSQL 17…) with its support dates.
struct Cycle: Decodable, Hashable, Sendable {
    let cycle: String
    let lts: Flex
    let support: Flex
    let eol: Flex
    let latest: String?

    enum Status { case lts, active, maintenance, ended }
    var status: Status {
        let today = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate])
        if case .date(let d) = eol, d <= today { return .ended }
        if case .flag(true) = eol { return .ended }
        if case .date(let d) = support, d <= today { return .maintenance }
        if case .flag(false) = support { return .maintenance }
        if case .date(let d) = lts, d <= today { return .lts }
        if case .flag(true) = lts { return .lts }
        return .active
    }
    var eolDate: String? { if case .date(let d) = eol { return d } else { return nil } }
    func matches(_ version: String) -> Bool { version == cycle || version.hasPrefix(cycle + ".") }
}

/// Branch and pending changes of a site's repository.
struct GitInfo: Decodable, Hashable, Sendable {
    let branch: String
    let head: String
    let changes: Int
    let ahead: Int
    let behind: Int
}
/// A linked worktree of a site's repository; `site` is the stack site serving it, if any.
struct Worktree: Decodable, Hashable, Identifiable, Sendable {
    let path: String
    let branch: String
    let site: String?
    var id: String { path }
}
/// What a branch switch changed that the site must catch up with.
struct BranchChanges: Decodable, Hashable, Sendable {
    let composer: Bool
    let npm: Bool
    let migrations: Int
    var any: Bool { composer || npm || migrations > 0 }
}

/// A PHP build offered in the catalog of Butake Stack's `runtimes` release.
struct PhpCatalogEntry: Decodable, Identifiable, Hashable, Sendable {
    let series: String
    let version: String
    let size_bytes: Int?
    let source: String?
    var id: String { version }
}

// MARK: Environments of a site's .env (secret values never come from the engine)
/// Standard environments (the usual `APP_ENV` values) plus a custom one.
enum EnvKind: String, Codable, CaseIterable, Sendable {
    case local, development, testing, staging, production, other
    /// The environment's standard name, used as its id and as `APP_ENV`.
    var standard: String? { self == .other ? nil : rawValue }
    /// Debug output only where nobody else looks at the site.
    var debug: Bool { [.local, .development, .testing].contains(self) }
}
struct EnvEntry: Codable, Hashable, Sendable {
    var key: String
    /// Empty for secrets: their value is in the Keychain.
    var value: String
    var secret: Bool
}
struct EnvEnvironment: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var name: String
    var kind: EnvKind
    var entries: [EnvEntry]
}
extension EnvEnvironment {
    /// Standard environments always show their Spanish name; custom ones the name the user gave.
    var title: String { kind == .other ? name : L("env.kind.\(kind.rawValue)") }
}
struct SiteEnvironments: Codable, Hashable, Sendable {
    var active: String?
    var environments: [EnvEnvironment]
    var activeEnvironment: EnvEnvironment? { environments.first { $0.id == active } }
}
struct EnvGitGuard: Codable, Hashable, Sendable { let ignored: Bool; let tracked: Bool; let repository: Bool }
struct EnvState: Codable, Hashable, Sendable {
    var site: SiteEnvironments
    let gitGuard: EnvGitGuard
    enum CodingKeys: String, CodingKey { case site, gitGuard = "guard", exampleKeys, hasEnv }
    let exampleKeys: [String]
    let hasEnv: Bool
}
struct EnvAuditEntry: Decodable, Hashable, Sendable {
    let ts: Int
    let env: String
    let action: String
    let key: String
    let user: String
}
