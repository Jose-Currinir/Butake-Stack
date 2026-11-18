import Foundation
import SwiftUI
import Testing
@testable import ButakeStack

/// No two shortcuts that can be active together press the same chord (⌘[ and ⌘R had two owners).
@Test func noTwoShortcutsShareAChord() {
    let pairs = Shortcuts.collisions().map { "\($0.0.id) = \($0.1.id) (\($0.0.display))" }
    #expect(pairs.isEmpty, "\(pairs)")
    #expect(Set(Shortcuts.all.map(\.id)).count == Shortcuts.all.count)
}

@Test func theCollisionCheckSeesGlobalAndSameScopeDuplicates() {
    let reload = Shortcuts.reload
    let page = AppShortcut(id: "pageReload", group: .database, titleKey: "common.refresh", key: "r")
    let other = AppShortcut(id: "terminalReload", group: .terminal, titleKey: "common.refresh", key: "r")
    #expect(!Shortcuts.collisions(in: [reload, page]).isEmpty)
    #expect(Shortcuts.collisions(in: [page, other]).isEmpty)
    let twin = AppShortcut(id: "twin", group: .database, titleKey: "db.run", key: "r")
    #expect(Shortcuts.collisions(in: [page, twin]).count == 1)
}

@Test func theTwoOldCollisionsHaveOneOwnerEach() {
    #expect(Shortcuts.all.filter { $0.display == "⌘[" }.map(\.id) == ["back"])
    #expect(Shortcuts.all.filter { $0.display == "⌘R" }.map(\.id) == ["reload"])
    #expect(Shortcuts.dbReload.display == "⌥⌘R" && Shortcuts.vaultBack.display == "⎋")
}

@Test func theSheetGroupsByMenuAndSearchesWithoutAccents() {
    let all = Shortcuts.sections(matching: "")
    #expect(all.first?.group == .app && all.map(\.group).contains(.go))
    let found = Shortcuts.sections(matching: "EDICION", in: [AppShortcut(id: "x", group: .edit, label: "Edición", key: "e")])
    #expect(found.count == 1)
    #expect(Shortcuts.sections(matching: "⇧⌘O").flatMap(\.items).map(\.id) == ["quickOpen"])
    #expect(Shortcuts.sections(matching: "zzzz").isEmpty)
}

@Test func theMatchIgnoresAccentsAndCapitals() {
    #expect(PaletteMatch.score(query: "configuracion", title: "Configuración") != nil)
    #expect(PaletteMatch.score(query: "CONFIGURACIÓN", title: "configuracion") != nil)
    #expect(PaletteMatch.score(query: "xyz", title: "Configuración", detail: "Ajustes") == nil)
    #expect(PaletteMatch.score(query: "ajus", title: "Nuevo", detail: "Ajustes") == 0)
}

@Test func theMatchOrdersByRelevanceAndKeepsTheOrderOfTies() {
    let titles = ["Detalle de git", "Servicio Git", "Gitea", "Git", "Otro (git)"]
    let ranked = PaletteMatch.rank(titles, query: "git", title: { $0 }, detail: { _ in "" })
    #expect(ranked.first == "Git")
    #expect(ranked == ["Git", "Gitea", "Detalle de git", "Servicio Git", "Otro (git)"])
    #expect(PaletteMatch.rank(titles, query: "  ", title: { $0 }, detail: { _ in "" }) == titles)
}

@Test func theMatchedPartOfATitleIsMarked() {
    let pieces = PaletteMatch.segments(of: "Configuración general", query: "configuracion gen")
    #expect(pieces.map(\.text) == ["Configuración", " ", "gen", "eral"])
    #expect(pieces.map(\.matched) == [true, false, true, false])
    #expect(PaletteMatch.segments(of: "Inicio", query: "").map(\.text) == ["Inicio"])
}

@Test func theRecentsKeepIdsOnlyNewestFirstWithoutDuplicates() throws {
    let defaults = try #require(UserDefaults(suiteName: "palette.test.\(UUID().uuidString)"))
    for id in ["a", "b", "c", "a"] { PaletteRecents.record(id, defaults) }
    #expect(PaletteRecents.ids(defaults) == ["a", "c", "b"])
    PaletteRecents.record("recent.b", defaults)
    #expect(PaletteRecents.ids(defaults) == ["b", "a", "c"])
    for index in 0..<20 { PaletteRecents.record("id\(index)", defaults) }
    #expect(PaletteRecents.ids(defaults).count == PaletteRecents.limit && PaletteRecents.ids(defaults).first == "id19")
    PaletteRecents.clear(defaults)
    #expect(PaletteRecents.ids(defaults).isEmpty)
}

@MainActor @Test func thePaletteShowsRecentsFirstAndASettingsRowPerTab() throws {
    let defaults = try #require(UserDefaults(suiteName: "palette.test.\(UUID().uuidString)"))
    let store = StackStore.shared
    var palette = CommandPalette(store: store)
    palette.defaults = defaults
    let plain = palette.commands
    for tab in SettingsTab.allCases { #expect(plain.contains { $0.id == "settings.\(tab.rawValue)" }) }
    #expect(plain.allSatisfy { !$0.id.hasPrefix("recent.") })
    #expect(plain.first { $0.id == "new" }?.shortcut == "⌘N")
    PaletteRecents.record("clone", defaults)
    PaletteRecents.record("new", defaults)
    let withRecents = palette.commands
    #expect(withRecents.prefix(2).map(\.id) == ["recent.new", "recent.clone"])
    #expect(withRecents.prefix(2).allSatisfy { $0.section == L("palette.recent") })
    #expect(Set(withRecents.map(\.id)).count == withRecents.count)
}
