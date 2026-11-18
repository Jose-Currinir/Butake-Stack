import Foundation
import Testing
@testable import ButakeStack

// Barrido de UI/UX, grupo F: filtro de Inicio, atajos de pestañas, Retorno, aviso de deshacer y asistente.

private func demo(_ id: String, kind: String = "static", name: String? = nil, technology: String? = nil, missing: Bool = false) -> Project {
    Project(id: id, name: name ?? id, path: "/tmp/\(id)", domains: ["\(id).test"], https: false, kind: kind, runtime: [:], docroot: ".",
            services: [], databases: [], processes: [], enabled: false, upstream: nil, env: nil, gcp: nil, missing: missing ? true : nil, technology: technology)
}

@Test func homeFilterMatchesNameAddressAndKind() {
    let shop = demo("tienda", kind: "laravel", name: "Mi Tienda")
    #expect(HomeFilter.admits(shop, query: "tienda"))
    #expect(HomeFilter.admits(shop, query: "TIENDA.test"))
    #expect(HomeFilter.admits(shop, query: "laravel"))
    #expect(HomeFilter.admits(shop, query: "  "))
    #expect(!HomeFilter.admits(shop, query: "blog"))
}

@Test func aFolderWhoseNameMatchesKeepsAllItsProjects() {
    let projects = [demo("a"), demo("b")]
    #expect(HomeFilter.shown(projects, folder: "Clientes", query: "client").count == 2)
    #expect(HomeFilter.shown(projects, folder: "Clientes", query: "a.test").map(\.id) == ["a"])
    #expect(HomeFilter.shown(projects, folder: nil, query: "zzz").isEmpty)
    #expect(HomeFilter.shown(projects, folder: "Clientes", query: "").count == 2)
}

@Test func theProjectTabsHaveFourDistinctKeys() {
    let keys = ProjectPage.Tab.allCases.map(\.shortcutKey)
    #expect(keys == ["1", "2", "3", "4"])
}

@Test func returnRenamesTheSelectedProjectOrProjectFolderOnly() {
    let shop = demo("tienda")
    let groups = [ProjectGroup(id: "salud", name: "Salud", sites: [], kind: .project)]
    #expect(SidebarRename.target(for: .site("tienda"), projects: [shop], groups: groups) == .project(shop))
    #expect(SidebarRename.target(for: .composite("salud"), projects: [shop], groups: groups) == .folder("salud"))
    #expect(SidebarRename.target(for: .composite("otra"), projects: [shop], groups: groups) == nil)
    #expect(SidebarRename.target(for: .site("gone"), projects: [shop], groups: groups) == nil)
    #expect(SidebarRename.target(for: .home, projects: [shop], groups: groups) == nil)
}

@MainActor @Test func anUndoableActionOffersUndoAndTheButtonTakesItBack() async {
    let store = StackStore()
    let manager = UndoManager()
    manager.groupsByEvent = false
    store.undoManager = manager
    var state = "off"
    manager.beginUndoGrouping()
    state = "on"
    store.undoable("Iniciar Demo", undo: { state = "off" }, redo: { state = "on" })
    manager.endUndoGrouping()
    #expect(store.undoOffer?.name == "Iniciar Demo")
    store.undoOffered()
    await store.undoTask?.value
    #expect(state == "off")
    #expect(store.undoOffer == nil)
}

@MainActor @Test func undoingWithTheKeyboardAlsoClearsTheOffer() async {
    let store = StackStore()
    let manager = UndoManager()
    manager.groupsByEvent = false
    store.undoManager = manager
    manager.beginUndoGrouping()
    store.undoable("Detener Demo", undo: {}, redo: {})
    manager.endUndoGrouping()
    #expect(store.undoOffer != nil)
    manager.undo()
    await store.undoTask?.value
    #expect(store.undoOffer == nil)
}

@MainActor @Test func withoutAWindowThereIsNoUndoOffer() {
    let store = StackStore()
    store.undoable("Detener Demo", undo: {}, redo: {})
    #expect(store.undoOffer == nil)
}

@Test func detectedProjectsMarkOnlyWhatTheyAsk() {
    let projects = [demo("tienda", kind: "laravel", name: "Tienda"), demo("blog", kind: "laravel", name: "Blog"),
                    demo("web", kind: "astro", name: "Web"), demo("fija", kind: "static"),
                    demo("app", kind: Project.unserved, technology: "swift"), demo("perdida", kind: "django", missing: true)]
    let suggestions = ProfileDetection.suggestions(for: projects)
    #expect(suggestions.map(\.profile) == ["laravel", "web", "swift"])
    #expect(suggestions.first?.projects == ["Tienda", "Blog"])
    #expect(ProfileDetection.marked(["github"], adding: suggestions) == ["github", "laravel", "web", "swift"])
    #expect(ProfileDetection.suggestions(for: []).isEmpty)
}

@Test func everySuggestedProfileExists() {
    let known = Set(WorkProfile.all.map(\.id))
    #expect(Set(ProfileDetection.profileOfKind.values).isSubset(of: known))
}
