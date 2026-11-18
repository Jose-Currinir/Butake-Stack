import Foundation
import Testing
@testable import ButakeStack

/// Atrás y Adelante: the pages visited, like a browser's.
@Test func historyGoesBackAndForwardAndForgetsWhatIsAheadOnANewPage() {
    var history = RouteHistory()
    history.visit(.service("database"))
    history.visit(.language("php"))
    history.visit(.language("php"))
    #expect(history.back == [.home, .service("database")])
    #expect(history.goBack() == .service("database"))
    #expect(history.canGoForward)
    #expect(history.goForward() == .language("php"))
    _ = history.goBack()
    history.visit(.utilities("ai"))
    #expect(!history.canGoForward)
    #expect(history.goBack() == .service("database"))
    #expect(history.goBack() == .home)
    #expect(history.goBack() == nil)
}

@Test func historyKeepsOnlyTheLastPages() {
    var history = RouteHistory()
    for index in 0..<(RouteHistory.limit + 10) { history.visit(.site("p\(index)")) }
    #expect(history.back.count == RouteHistory.limit)
}

@MainActor @Test func goingBackSkipsAProjectThatNoLongerExists() {
    let store = StackStore()
    store.history.visit(.site("gone"))
    store.history.visit(.language("php"))
    store.route = .language("php")
    store.goBack()
    #expect(store.route == .home)
    #expect(!store.history.canGoBack)
}

/// ⌘Z: what an action registers is taken back, and Rehacer repeats it.
@MainActor @Test func undoTakesAnActionBackAndRedoRepeatsIt() async {
    let store = StackStore()
    let manager = UndoManager()
    manager.groupsByEvent = false
    store.undoManager = manager
    var state = "on"
    manager.beginUndoGrouping()
    state = "off"
    store.undoable("Detener Demo", undo: { state = "on" }, redo: { state = "off" })
    manager.endUndoGrouping()
    #expect(manager.canUndo && manager.undoActionName == "Detener Demo")
    manager.undo()
    await store.undoTask?.value
    #expect(state == "on")
    #expect(manager.canRedo)
    manager.redo()
    await store.undoTask?.value
    #expect(state == "off")
    #expect(manager.canUndo)
}

@MainActor @Test func anActionRepeatedByAnUndoDoesNotRegisterAgain() async {
    let store = StackStore()
    let manager = UndoManager()
    manager.groupsByEvent = false
    store.undoManager = manager
    manager.beginUndoGrouping()
    store.undoable("Mover Demo", undo: { store.undoable("otra", undo: {}, redo: {}) }, redo: {})
    manager.endUndoGrouping()
    manager.undo()
    await store.undoTask?.value
    #expect(!manager.canUndo)
    #expect(manager.canRedo)
}

@MainActor @Test func withoutAWindowNothingIsRegistered() {
    let store = StackStore()
    store.undoable("Detener Demo", undo: {}, redo: {})
    #expect(store.undoManager == nil)
}

/// Errors: said where the action was asked, with the cause and the button that helps.
@MainActor @Test func aPanelFailureStaysInThePanelAndNeverOpensTheWindowsAlert() {
    let store = StackStore()
    store.report(EngineFailure(code: "folder_missing"), title: "No se pudo iniciar Demo", from: .panel)
    #expect(store.panelFailure?.title == "No se pudo iniciar Demo")
    #expect(store.windowFailure == nil)
    store.report(EngineFailure(code: "folder_missing"))
    #expect(store.windowFailure != nil)
    store.dismissFailure()
    #expect(store.windowFailure == nil)
}

@Test func aKnownCauseOffersNoLogsAndAnUnknownOneDoes() {
    let known = ActionFailure(error: EngineFailure(code: "folder_missing"))
    #expect(!known.offersLogs)
    #expect(known.message == L("error.folder_missing"))
    let withCause = ActionFailure(error: EngineFailure(code: "new_code", messageKey: "error.new_code", detail: "puerto 80 ocupado"))
    #expect(withCause.message.contains("puerto 80 ocupado"))
    let unknown = ActionFailure(error: EngineFailure(code: "engine", messageKey: "engine.requestFailed"))
    #expect(unknown.offersLogs)
    #expect(unknown.message == L("engine.requestFailed"))
}

@MainActor @Test func aFailedActionOffersToRunItAgain() async {
    let store = StackStore()
    var attempts = 0
    await store.run("Probando", from: .panel, failureTitle: "No se pudo") { attempts += 1; throw EngineFailure(code: "folder_missing") }
    #expect(attempts == 1)
    await store.panelFailure?.retry?()
    #expect(attempts == 2)
    await store.run("Probando", canRetry: false) { throw EngineFailure(code: "folder_missing") }
    #expect(store.failure?.retry == nil)
}
