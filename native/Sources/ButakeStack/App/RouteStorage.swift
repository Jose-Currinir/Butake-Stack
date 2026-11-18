import Foundation

/// The window's page as text, for `@SceneStorage`: "home", "site:<id>", "service:<name>", "utilities:<section>"…
extension Route {
    var storageValue: String {
        switch self {
        case .home: "home"
        case .site(let id): "site:\(id)"
        case .composite(let id): "composite:\(id)"
        case .service(let name): "service:\(name)"
        case .language(let name): "language:\(name)"
        case .tool(let id): "tool:\(id)"
        case .utilities(let group): "utilities:\(group)"
        }
    }

    /// Values saved by older versions read as today's page: the tools that were services or a page
    /// of their own are tools; the pages that became Ajustes ("general", "plugins", "service:web")
    /// read as nothing, so the window opens on Inicio.
    init?(storageValue: String) {
        let parts = storageValue.split(separator: ":", maxSplits: 1).map(String.init)
        let value = parts.count > 1 ? parts[1] : ""
        switch parts.first {
        case "home": self = .home
        // "utilities" alone (one page before its sections had their own) opens the first section.
        case "utilities": self = UtilityCatalog.group(value) == nil ? UtilityCatalog.route() : .utilities(value)
        case "site" where !value.isEmpty: self = .site(value)
        case "composite" where !value.isEmpty: self = .composite(value)
        case "service" where ["mail", "dumps", "logs"].contains(value): self = .tool(value)
        case "service" where Route.services.contains(value): self = .service(value)
        case "language" where !value.isEmpty: self = .language(value)
        case "tool" where !value.isEmpty: self = .tool(value)
        case "vault": self = .tool("vault")
        default: return nil
        }
    }
}

extension StackStore {
    /// Whether a saved page still exists: the project is there, the tool is on.
    func canShow(_ route: Route) -> Bool {
        switch route {
        case .home: true
        case .site(let id): projects.contains { $0.id == id }
        case .composite(let id): composite(id) != nil
        case .service(let name): Route.services.contains(name)
        case .language(let name): Route.languages.contains(name)
        case .tool(let id): id == "logs" || pluginEnabled(id)
        case .utilities(let group): UtilityCatalog.group(group) != nil
        }
    }

    /// The page saved by the window, or Inicio when it no longer exists. A page already chosen
    /// (a link, Ir, the panel) wins over the saved one.
    func restore(_ saved: String) {
        guard route == .home, let route = Route(storageValue: saved), route != .home else { return }
        if canShow(route) {
            if case .site(let id) = route { openSite(id) } else { self.route = route }
        }
    }
}
