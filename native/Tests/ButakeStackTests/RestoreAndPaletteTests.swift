import Foundation
import Testing
@testable import ButakeStack

/// The plan of «Restaurar configuración…» brings the catalog extensions this Mac lacks, so the sheet
/// can offer them as a part of their own; a plan without them still reads.
@Test func theRestorePlanCarriesTheMissingExtensions() throws {
    let base = #""profiles": [], "php": [], "tools": [], "devtools": [], "python": [], "sites": [], "groups": 0, "environments": 0"#
    let plan = try JSONDecoder().decode(RestorePlan.self, from: Data(#"{\#(base), "extensions": [{"component": "postgres", "version": "18.7", "id": "postgis"}]}"#.utf8))
    #expect(plan.extensions == [RestorePlan.Extension(component: "postgres", version: "18.7", id: "postgis")])
    let without = try JSONDecoder().decode(RestorePlan.self, from: Data("{\(base)}".utf8))
    #expect(without.extensions == nil)
}

/// Ir › Abrir rápidamente… lists a project of several parts with its own symbol and opens its page;
/// a plain folder is not a destination.
@MainActor @Test func thePaletteOpensAProjectOfSeveralParts() throws {
    let store = StackStore.shared
    let saved = (store.groups, store.route)
    defer { store.groups = saved.0; store.route = saved.1 }
    store.groups = [ProjectGroup(id: "salud", name: "Salud", sites: [], kind: .project),
                    ProjectGroup(id: "varios", name: "Varios", sites: [], kind: .folder)]
    let commands = CommandPalette(store: store).commands
    let composite = try #require(commands.first { $0.id == "composite.salud" })
    #expect(composite.title == "Salud" && composite.symbol == Symbols.compositeProject && composite.tech == nil)
    #expect(!commands.contains { $0.id == "composite.varios" })
    composite.run()
    #expect(store.route == .composite("salud"))
}
