import Foundation

/// `databases[]` of a project (engine: `core/project_database.rs`): a plain name, or the name with
/// the extensions that database needs (`{"name": "geo", "extensions": ["postgis"]}`).
struct ProjectDatabase: Codable, Hashable, Sendable {
    var name: String
    var extensions: [String] = []

    init(name: String, extensions: [String] = []) {
        self.name = name
        self.extensions = extensions
    }

    private enum Keys: String, CodingKey { case name, extensions }

    init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let name = try? single.decode(String.self) {
            self.name = name
            return
        }
        let container = try decoder.container(keyedBy: Keys.self)
        name = try container.decode(String.self, forKey: .name)
        extensions = try container.decodeIfPresent([String].self, forKey: .extensions) ?? []
    }

    func encode(to encoder: Encoder) throws {
        if extensions.isEmpty {
            var single = encoder.singleValueContainer()
            try single.encode(name)
        } else {
            var container = encoder.container(keyedBy: Keys.self)
            try container.encode(name, forKey: .name)
            try container.encode(extensions, forKey: .extensions)
        }
    }
}

/// One extension of a component as the engine lists it (`extensionCatalog`): bundled with it,
/// from the catalog (installed on demand) or built into it (PHP).
struct ComponentExtension: Decodable, Identifiable, Hashable, Sendable {
    struct Download: Decodable, Hashable, Sendable, Identifiable {
        let id: String
        let name: String
        let version: String
        let license: String
        /// `extension`, `library` or `buildTool`.
        let role: String
        let url: String
        let sha256: String
        let size: Int64
        /// Where it comes from, as the user reads it (the origin's host).
        var host: String { URL(string: url)?.host() ?? url }
    }

    let component: String
    let id: String
    let name: String
    /// `bundled`, `catalog` or `builtin`.
    let kind: String
    let version: String
    var license: String?
    var homepage: String?
    let sqlNames: [String]
    let downloads: [Download]
    let downloadSize: Int64
    var installed: String?
    var installedAt: Int?
    var update: String?
    let supported: Bool
    let removable: Bool
    let elsewhere: [String]
    var note: String?

    var fromCatalog: Bool { kind == "catalog" }
    var isInstalled: Bool { installed != nil }
}

struct ExtensionCatalog: Decodable, Sendable {
    let component: String
    let version: String
    let extensions: [ComponentExtension]

    var catalog: [ComponentExtension] { extensions.filter(\.fromCatalog) }
    var bundled: [ComponentExtension] { extensions.filter { !$0.fromCatalog } }
    /// What `CREATE EXTENSION` can take in this copy: bundled ones and installed catalog ones.
    var activatable: [String] {
        extensions.filter(\.isInstalled).flatMap(\.sqlNames).sorted()
    }
}

/// Active in a database (`pg_extension`).
struct ActiveExtension: Decodable, Hashable, Sendable, Identifiable {
    let name: String
    let version: String
    var id: String { name }
}

/// What the server offers to a database (`pg_available_extensions`).
struct OfferedExtension: Decodable, Hashable, Sendable, Identifiable {
    let name: String
    var defaultVersion: String?
    var installedVersion: String?
    var comment: String?
    var id: String { name }
}

struct DatabaseExtensions: Decodable, Sendable {
    let active: [ActiveExtension]
    let offered: [OfferedExtension]
}

/// What a project's databases lack (`projectExtensions`).
struct ExtensionIssue: Decodable, Hashable, Sendable, Identifiable {
    let database: String
    let extensionName: String
    /// `serviceMissing`, `notInstalled`, `unsupported`, `unknown`, `serverStopped`,
    /// `databaseMissing` or `inactive`.
    let problem: String
    var catalog: String?
    var id: String { "\(database).\(extensionName)" }
    var fixable: Bool { problem == "notInstalled" || problem == "inactive" }

    static let problems = ["serviceMissing", "notInstalled", "unsupported", "unknown", "serverStopped", "databaseMissing", "inactive"]

    private enum CodingKeys: String, CodingKey {
        case database, problem, catalog
        case extensionName = "extension"
    }
}

/// What `installExtension` answers besides the record: databases moved to the new version.
struct InstalledExtension: Decodable, Sendable {
    let updatedDatabases: [String]
}
