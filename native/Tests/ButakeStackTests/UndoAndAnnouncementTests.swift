import Foundation
import Testing
@testable import ButakeStack

// Barrido KiroCrew → Stack, grupo I: aviso de deshacer que espera, anuncios a VoiceOver, deshacer de carpetas y grupos de hosts, menú de Skills.

@MainActor private func windowStore() -> (StackStore, UndoManager) {
    let store = StackStore()
    let manager = UndoManager()
    manager.groupsByEvent = false
    store.undoManager = manager
    return (store, manager)
}

/// Runs `body` as one undo group, like an action asked in the window.
@MainActor private func inGroup(_ manager: UndoManager, _ body: () -> Void) {
    manager.beginUndoGrouping()
    body()
    manager.endUndoGrouping()
}

@Test func theNoticeStaysLongerTheLongerItsText() {
    #expect(StackStore.undoOfferSeconds(forLength: 10) == 8)
    #expect(StackStore.undoOfferSeconds(forLength: 30) == 8)
    #expect(StackStore.undoOfferSeconds(forLength: 80) == 13)
    #expect(StackStore.undoOfferSeconds(forLength: 5_000) == 20)
    #expect(UndoOffer(name: "Iniciar Tienda").seconds < UndoOffer(name: String(repeating: "Tienda grande ", count: 6)).seconds)
}

@MainActor @Test func theNoticeClockWaitsWhileThePointerOrFocusIsOnIt() {
    let (store, manager) = windowStore()
    inGroup(manager) { store.undoable("Iniciar Demo", undo: {}, redo: {}) }
    let total = store.undoRemaining
    #expect(total == 8)
    store.holdUndoOffer(true)
    #expect(!store.advanceUndoOffer(by: 100))
    #expect(store.undoRemaining == total && store.undoOffer != nil)
    store.holdUndoOffer(false)
    #expect(!store.advanceUndoOffer(by: 7.5))
    #expect(store.undoRemaining == 0.5)
    #expect(store.advanceUndoOffer(by: 0.5))
    #expect(store.undoOffer == nil)
}

@MainActor @Test func aNewNoticeStartsItsOwnClockFree() {
    let (store, manager) = windowStore()
    inGroup(manager) { store.undoable("Iniciar Demo", undo: {}, redo: {}) }
    store.holdUndoOffer(true)
    inGroup(manager) { store.undoable("Detener Demo", undo: {}, redo: {}) }
    #expect(!store.undoHeld)
    #expect(store.undoRemaining == store.undoOffer?.seconds)
}

@MainActor @Test func noticesAndUndoneActionsAreSaidOnceThroughOneWay() async {
    let (store, manager) = windowStore()
    var said: [String] = []
    store.announcer = { said.append($0) }
    store.notify("Guardado")
    #expect(said == ["Guardado"])
    inGroup(manager) { store.undoable("Iniciar Demo", undo: {}, redo: {}) }
    #expect(said == ["Guardado", "Hecho: Iniciar Demo. Puedes deshacerlo."])
    manager.undo()
    await store.undoTask?.value
    manager.redo()
    await store.undoTask?.value
    #expect(said.suffix(2) == ["Deshecho: Iniciar Demo", "Rehecho: Iniciar Demo"])
}

@MainActor @Test func movingAProjectToAFolderCanBeUndoneAndRedone() async {
    let (store, manager) = windowStore()
    store.groups = [ProjectGroup(id: "a", name: "A", sites: ["tienda"]), ProjectGroup(id: "b", name: "B", sites: [])]
    inGroup(manager) { store.move("tienda", to: "b") }
    #expect(store.groups.map(\.sites) == [[], ["tienda"]])
    #expect(store.undoOffer?.name == "Mover tienda de carpeta")
    manager.undo()
    await store.undoTask?.value
    #expect(store.groups.map(\.sites) == [["tienda"], []])
    manager.redo()
    await store.undoTask?.value
    #expect(store.groups.map(\.sites) == [[], ["tienda"]])
}

@MainActor @Test func deletingAFolderBringsBackItsProjectsOnUndo() async {
    let (store, manager) = windowStore()
    store.groups = [ProjectGroup(id: "a", name: "Clientes", sites: ["tienda", "blog"]), ProjectGroup(id: "b", name: "B", sites: [])]
    inGroup(manager) { store.deleteGroup("a") }
    #expect(store.groups.map(\.id) == ["b"])
    #expect(store.undoOffer?.name == "Quitar la carpeta Clientes")
    manager.undo()
    await store.undoTask?.value
    #expect(store.groups.map(\.id) == ["a", "b"] && store.groups[0].sites == ["tienda", "blog"])
}

@MainActor @Test func aMoveThatChangesNothingOffersNoUndo() {
    let (store, manager) = windowStore()
    store.groups = [ProjectGroup(id: "a", name: "A", sites: ["tienda"])]
    inGroup(manager) { store.move("tienda", to: "a") }
    #expect(store.undoOffer == nil)
}

@MainActor @Test func movingAHostToAnotherGroupCanBeUndone() async throws {
    // Needs the engine on a temporary store (scripts/test-native.sh sets BUTAKE_STACK_HOME).
    guard ProcessInfo.processInfo.environment["BUTAKE_STACK_HOME"] != nil else { return }
    let terminal = SSHTerminal()
    let store = StackStore.shared
    let manager = UndoManager()
    manager.groupsByEvent = false
    store.undoManager = manager
    defer { store.undoManager = nil }
    let _: [ToolInfo] = try await store.call(["method": "pluginSetEnabled", "id": "ssh-terminal", "enabled": true])
    var host = SSHHost(); host.name = "Servidor demo"; host.host = "demo.example.com"; host.user = "demo"; host.group = "Uno"
    #expect(await terminal.save(host), "\(String(describing: store.failure?.message))")
    let id = try #require(terminal.hosts.first { $0.name == "Servidor demo" }?.id)
    manager.beginUndoGrouping()
    await terminal.move(id, to: "Dos")
    manager.endUndoGrouping()
    #expect(terminal.host(id)?.group == "Dos")
    #expect(store.undoOffer?.name == "Mover el host Servidor demo de grupo")
    manager.undo()
    await store.undoTask?.value
    #expect(terminal.host(id)?.group == "Uno")
    manager.redo()
    await store.undoTask?.value
    #expect(terminal.host(id)?.group == "Dos")
    await terminal.delete(try #require(terminal.host(id)))
}

@MainActor @Test func theSkillRowMenuHasTheToolbarActions() {
    #expect(SkillRowMenu.actionIdentifiers == ["skills.rowMenu.duplicate", "skills.menu.exportCopy", "skills.menu.exportSave",
                                               "skills.menu.move", "skills.menu.rename", "skills.menu.toggle", "skills.menu.delete"])
}
