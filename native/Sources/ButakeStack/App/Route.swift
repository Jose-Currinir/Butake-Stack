import AppKit
import SwiftUI

/// Sidebar destinations: each project, each service type, each language and each tool has its own
/// page. Preferences are not pages: they live in Ajustes (`SettingsTab`).
enum Route: Hashable {
    case home
    case site(String)
    /// The page of a project of several parts (a folder marked as a project, P-39).
    case composite(String)
    case service(String)
    case language(String)
    /// A tool's page: the catalog's tools (see docs/herramientas.md) and the logs, part of the base.
    case tool(String)
    /// A section of Utilidades (`UtilityCatalog.groups`): the programs Stack installs from their
    /// makers, outside any language.
    case utilities(String)

    var title: String {
        switch self {
        case .home: L("route.home")
        case .site: L("route.sites")
        case .composite: L("composite.title")
        case .service(let name): Tech.of(name).title
        case .language(let name): Tech.of(name).title
        // «AWS» is the tool of the profiles; «AWS CLI», the utility it works with.
        case .tool("aws"): L("plugin.aws.title")
        case .tool(let id): Tech.of(id).title
        case .utilities(let group): UtilityCatalog.group(group)?.title ?? L("route.utilities")
        }
    }
    /// Service types, like a catalog: each groups the engines of that kind.
    static let services = ["database", "cache", "broadcasting", "search", "storage"]
    static func engines(in category: String) -> [String] {
        switch category {
        case "database": ["mysql", "postgres", "mongodb"]
        case "cache": ["redis", "valkey"]
        case "search": ["meilisearch", "typesense"]
        case "storage": ["rustfs"]
        default: []
        }
    }
    static let allEngines = services.flatMap { engines(in: $0) }
    /// Engines that cannot be offered with a one-click install, with the honest reason.
    static func unavailable(in category: String) -> [(String, String)] {
        category == "database" ? [("MariaDB", L("unavailable.mariadb"))] : []
    }
    static func category(of engine: String) -> String {
        services.first { engines(in: $0).contains(engine) } ?? services[0]
    }
    static let languages = ["php", "node", "python", "java", "rust", "swift"]
}
