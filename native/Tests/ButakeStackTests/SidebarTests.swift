import Foundation
import Testing
@testable import ButakeStack

// The sidebar in four blocks (P-37): every route of before keeps opening the same page, and selects
// its row of the sidebar and, for Componentes, its category in the content column.

private let allTools = ["vault", "database-client", "ssh-terminal", "mail", "dumps", "aws", "gcp", "git", "skills"]

/// The row of the sidebar and the category of the content column a route leaves selected.
private func selected(_ route: Route) -> (SidebarRow, String?) {
    (SidebarRow.of(route), Component.of(route)?.category)
}

/// Every route there was before: its row and its category.
@Test func everyRouteSelectsItsRowAndCategory() {
    #expect(selected(.home) == (.home, nil))
    #expect(selected(.site("qa")) == (.site("qa"), nil))
    for category in Route.services {
        #expect(selected(.service(category)) == (.component(.services), category))
        #expect(Route.service(category).hasContentColumn)
    }
    for language in Route.languages {
        #expect(selected(.language(language)) == (.component(.languages), language))
        #expect(Route.language(language).hasContentColumn)
    }
    for group in UtilityCatalog.groups.map(\.id) {
        #expect(selected(.utilities(group)) == (.component(.utilities), group))
        #expect(Route.utilities(group).hasContentColumn)
    }
    for tool in allTools + ["logs"] {
        #expect(selected(.tool(tool)) == (.tool(tool), nil))
    }
    // The content column lists, for each component, exactly the pages there were.
    #expect(Component.services.categories.map(Component.services.route) == Route.services.map(Route.service))
    #expect(Component.languages.categories.map(Component.languages.route) == Route.languages.map(Route.language))
    #expect(Component.utilities.categories.map(Component.utilities.route) == UtilityCatalog.groups.map { Route.utilities($0.id) })
    // A page's title is still its category's.
    #expect(Route.service("cache").title == L("category.cache"))
    #expect(Route.utilities("cloud").title == L("utilities.section.cloud"))
}

/// butakestack:// links and the pages saved by older versions land on the same page and row.
@Test @MainActor func linksAndSavedPagesLandOnTheirRow() {
    let store = StackStore()
    store.plugins = allTools.map { ToolInfo(id: $0, installed: true, enabled: true, hasData: false) }
    store.pluginsLoaded = true
    let links: [(String, Route, SidebarRow)] = [
        ("butakestack://service/cache", .service("cache"), .component(.services)),
        ("butakestack://service/database", .service("database"), .component(.services)),
        ("butakestack://service/mail", .tool("mail"), .tool("mail")),
        ("butakestack://service/logs", .tool("logs"), .tool("logs")),
        ("butakestack://tool/aws", .tool("aws"), .tool("aws")),
        ("butakestack://tool/gcp", .tool("gcp"), .tool("gcp")),
        ("butakestack://tool/git", .tool("git"), .tool("git")),
        ("butakestack://vault", .tool("vault"), .tool("vault")),
    ]
    for (link, route, row) in links {
        store.route = .home
        store.handle(URL(string: link)!)
        #expect(store.route == route, "\(link)")
        #expect(SidebarRow.of(store.route) == row, "\(link)")
    }
    let saved: [(String, Route, SidebarRow)] = [
        ("service:search", .service("search"), .component(.services)),
        ("language:java", .language("java"), .component(.languages)),
        ("utilities", .utilities("ai"), .component(.utilities)),
        ("utilities:repos", .utilities("repos"), .component(.utilities)),
        ("service:dumps", .tool("dumps"), .tool("dumps")),
        ("tool:ssh-terminal", .tool("ssh-terminal"), .tool("ssh-terminal")),
    ]
    for (value, route, row) in saved {
        #expect(Route(storageValue: value) == route)
        #expect(SidebarRow.of(route) == row)
    }
}

/// Ir › Servicios, Lenguajes and Utilidades open the first category, then the last one seen.
@Test func componentsOpenOnTheLastCategorySeen() throws {
    let defaults = try #require(UserDefaults(suiteName: "cl.butake.stack.qa.sidebar.\(UUID().uuidString)"))
    #expect(Component.services.lastRoute(defaults) == .service("database"))
    #expect(Component.languages.lastRoute(defaults) == .language("php"))
    #expect(Component.utilities.lastRoute(defaults) == .utilities("ai"))
    Component.remember(.service("cache"), in: defaults)
    Component.remember(.language("rust"), in: defaults)
    Component.remember(.tool("git"), in: defaults)
    #expect(Component.services.lastRoute(defaults) == .service("cache"))
    #expect(Component.languages.lastRoute(defaults) == .language("rust"))
    #expect(Component.utilities.lastRoute(defaults) == .utilities("ai"))
    // A category that no longer exists opens the first one.
    defaults.set("gone", forKey: Component.utilities.memoryKey)
    #expect(Component.utilities.lastRoute(defaults) == .utilities("ai"))
}

/// Herramientas in its fixed order with Registros last; Nube only with an account on.
@Test func toolsAndCloudFollowTheirOrder() {
    #expect(SidebarLayout.toolRows(enabled: allTools) == ["git", "ssh-terminal", "database-client", "vault", "skills", "mail", "dumps", "logs"])
    #expect(SidebarLayout.cloudRows(enabled: allTools) == ["aws", "gcp"])
    // Everything off: only Registros, and no Nube.
    #expect(SidebarLayout.toolRows(enabled: []) == ["logs"])
    #expect(SidebarLayout.cloudRows(enabled: []).isEmpty)
    #expect(SidebarLayout.cloudRows(enabled: ["gcp"]) == ["gcp"])
    // A tool the order doesn't know yet still shows, before Registros.
    #expect(SidebarLayout.toolRows(enabled: ["mail", "new-tool"]) == ["mail", "new-tool", "logs"])
}

/// The palette keeps every page of before, with the same id and route, grouped as the sidebar.
@Test @MainActor func paletteKeepsEveryPage() {
    let pages = CommandPalette.pages(enabled: allTools)
    let byID = Dictionary(uniqueKeysWithValues: pages.map { ($0.id, $0) })
    var expected: [String: Route] = [:]
    for category in Route.services { expected[category] = .service(category) }
    for language in Route.languages { expected[language] = .language(language) }
    for group in UtilityCatalog.groups { expected["utilities.\(group.id)"] = .utilities(group.id) }
    for tool in allTools + ["logs"] { expected[tool] = .tool(tool) }
    for (id, route) in expected { #expect(byID[id]?.route == route, "\(id)") }
    #expect(pages.count == expected.count)
    #expect(byID["aws"]?.section == L("sidebar.cloud") && byID["git"]?.section == L("sidebar.tools"))
    #expect(byID["cache"]?.section == L("sidebar.components") && byID["cache"]?.detail == L("sidebar.services"))
    // Off, a tool is not offered.
    #expect(CommandPalette.pages(enabled: []).filter { if case .tool = $0.route { true } else { false } }.map(\.id) == ["logs"])
}

/// The search finds a category by its name or by something it holds.
@Test func searchFindsCategoriesByWhatTheyHold() {
    #expect(SidebarLayout.categories(matching: "Redis") == [.service("cache")])
    #expect(SidebarLayout.categories(matching: "caché") == [.service("cache")])
    #expect(SidebarLayout.categories(matching: "PostgreSQL") == [.service("database")])
    #expect(SidebarLayout.categories(matching: "Python") == [.language("python")])
    #expect(SidebarLayout.categories(matching: "Wrangler") == [.utilities("cloud")])
    #expect(SidebarLayout.categories(matching: "Codex") == [.utilities("ai")])
    #expect(SidebarLayout.categories(matching: "GitHub") == [.utilities("repos")])
    #expect(SidebarLayout.categories(matching: "").isEmpty)
    #expect(SidebarLayout.categories(matching: "zzz").isEmpty)
}

/// Sections closed by an older version: only Proyectos can still close; the rest open again.
@Test func closedSectionsOfBeforeHideNothing() {
    #expect(SidebarLayout.migrateClosedSections("services,languages,utilities,tools") == [])
    #expect(SidebarLayout.migrateClosedSections("languages,sites") == ["sites"])
    #expect(SidebarLayout.migrateClosedSections("") == [])
}

/// No two rows of the sidebar share a tile: the same mark in the same color.
@Test func noTwoSidebarRowsShareAnIcon() {
    let techs = SidebarLayout.toolRows(enabled: allTools).map(Tech.of) + SidebarLayout.cloudRows(enabled: allTools).map(Tech.of)
        + Component.allCases.map(\.tech)
    let marks = techs.map { $0.simple ?? $0.svg ?? $0.symbol }
    #expect(Set(marks).count == marks.count, "\(marks)")
    // Nor in the content column of Utilidades: the command lines don't take a tool's mark.
    let utilities = UtilityCatalog.groups.map(\.tech.symbol)
    #expect(Set(utilities + marks).count == utilities.count + marks.count)
    // Google Cloud has its provider's logo, not the cloud.
    #expect(Tech.of("gcp").svg == "gcp" && Tech.of("aws").symbol != Symbols.cloud)
}
