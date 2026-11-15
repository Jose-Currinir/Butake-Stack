import Foundation

// The sidebar in four blocks, in this order (P-37): Inicio, Proyectos, Herramientas (what is used,
// daily use first and debugging last), Nube (the providers' accounts) and Componentes (what is
// installed on the Mac). Routes keep their meaning: a page of a service type, a language or a
// section of Utilidades selects its row of Componentes and its category in the content column.

/// A row of Componentes: one page with its categories in the window's content column.
enum Component: String, CaseIterable, Hashable {
    case services, languages, utilities

    var title: String {
        switch self {
        case .services: L("sidebar.services")
        case .languages: L("sidebar.languages")
        case .utilities: L("route.utilities")
        }
    }
    /// Its tile in the sidebar: one symbol and one color, none shared with another row.
    var tech: Tech {
        switch self {
        case .services: Tech(id: "components.services", title: title, symbol: Symbols.service, color: 0x30B0C7)
        case .languages: Tech(id: "components.languages", title: title, symbol: Symbols.languages, color: 0xFF2D55)
        case .utilities: Tech(id: "components.utilities", title: title, symbol: Symbols.utilities, color: 0xA2845E)
        }
    }
    /// Its categories, in the order of the content column.
    var categories: [String] {
        switch self {
        case .services: Route.services
        case .languages: Route.languages
        case .utilities: UtilityCatalog.groups.map(\.id)
        }
    }
    func route(_ category: String) -> Route {
        switch self {
        case .services: .service(category)
        case .languages: .language(category)
        case .utilities: .utilities(category)
        }
    }
    /// The tile and the name of a category.
    func tech(of category: String) -> Tech {
        self == .utilities ? (UtilityCatalog.group(category)?.tech ?? Tech.of(category)) : Tech.of(category)
    }
    /// What a category holds, by name: the search finds the category by any of them.
    func members(of category: String) -> [String] {
        switch self {
        case .services: Route.engines(in: category).map { Tech.of($0).title } + (category == "broadcasting" ? [Tech.of("reverb").title] : [])
        case .languages: []
        case .utilities: (UtilityCatalog.group(category)?.tools ?? []).map { Tech.of($0).title }
        }
    }

    /// The component and the category of a route, if it is the page of one.
    static func of(_ route: Route) -> (component: Component, category: String)? {
        switch route {
        case .service(let category): (.services, category)
        case .language(let category): (.languages, category)
        case .utilities(let category): (.utilities, category)
        default: nil
        }
    }

    // The last category seen of each one: its row opens there.
    var memoryKey: String { "sidebar.component.\(rawValue)" }
    /// The category its row opens: the last one seen, or the first.
    func lastCategory(_ defaults: UserDefaults = .standard) -> String {
        defaults.string(forKey: memoryKey).flatMap { categories.contains($0) ? $0 : nil } ?? categories[0]
    }
    func lastRoute(_ defaults: UserDefaults = .standard) -> Route { route(lastCategory(defaults)) }
    /// Notes the category of a page on screen (nothing for any other page).
    static func remember(_ route: Route, in defaults: UserDefaults = .standard) {
        guard let (component, category) = of(route), component.categories.contains(category) else { return }
        defaults.set(category, forKey: component.memoryKey)
    }
}

/// What the sidebar's list selects. A page of Componentes selects its component's row; while the
/// search shows a category on its own, that row.
enum SidebarRow: Hashable {
    case home
    case site(String)
    /// A project of several parts: its folder row opens its page.
    case composite(String)
    case tool(String)
    case component(Component)
    /// A category found by the search, shown as a row of its own.
    case category(Route)

    /// The row of a route outside a search.
    static func of(_ route: Route) -> SidebarRow {
        switch route {
        case .home: .home
        case .site(let id): .site(id)
        case .composite(let id): .composite(id)
        case .tool(let id): .tool(id)
        case .service, .language, .utilities: .component(Component.of(route)!.component)
        }
    }
}

enum SidebarLayout {
    /// Herramientas, in a fixed order: daily use first, debugging last. Registros (base) closes it.
    static let tools = ["git", "ssh-terminal", "database-client", "vault", "mail", "dumps"]
    /// Nube: the accounts of each provider.
    static let clouds = ["aws", "gcp"]
    /// Only these can be closed; Herramientas, Nube and Componentes are short and always open.
    static let collapsible: Set<String> = ["sites"]

    /// The tools that are on, in the order of Herramientas (one this list doesn't know goes before
    /// Registros), then Registros.
    static func toolRows(enabled: [String]) -> [String] {
        let known = tools.filter(enabled.contains)
        let other = enabled.filter { !tools.contains($0) && !clouds.contains($0) }
        return known + other + ["logs"]
    }
    /// The cloud accounts that are on; none, and Nube is not shown.
    static func cloudRows(enabled: [String]) -> [String] { clouds.filter(enabled.contains) }

    /// The closed sections saved by an older version (Servicios, Lenguajes, Utilidades,
    /// Herramientas could be closed): only those that can still close stay closed, so nothing is
    /// hidden after an update.
    static func migrateClosedSections(_ raw: String) -> Set<String> {
        Set(raw.split(separator: ",").map(String.init)).intersection(collapsible)
    }

    /// The categories of Componentes a search finds, by their name or the name of something they
    /// hold («Redis» finds Servicios › Caché y colas).
    static func categories(matching search: String) -> [Route] {
        guard !search.isEmpty else { return [] }
        let found = { (text: String) in text.localizedCaseInsensitiveContains(search) }
        return Component.allCases.flatMap { component in
            component.categories.filter { found(component.tech(of: $0).title) || component.members(of: $0).contains(where: found) }
                .map(component.route)
        }
    }
}
