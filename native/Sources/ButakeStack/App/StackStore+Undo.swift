import Foundation

/// Undo for what can be reverted (Edición › Deshacer, ⌘Z), on the window's `UndoManager`.
///
/// An action that worked calls `undoable` with the name the menu shows («Deshacer Iniciar Tienda»)
/// and the two ways of the change: `undo` takes it back and `redo` makes it again. Undoing registers
/// the reverse on its own, so Rehacer (⇧⌘Z) works with no more code. While an undo or a redo runs,
/// the actions it repeats do not register again. What cannot be taken back (a deleted database,
/// a removed project's Keychain items) keeps its confirmation instead.
extension StackStore {
    /// Registers a change that worked. Without a window's manager (the window never opened) nothing is
    /// registered: the action still happened.
    func undoable(_ name: String, undo: @escaping @MainActor () async -> Void, redo: @escaping @MainActor () async -> Void) {
        guard !replayingUndo, let manager = undoManager else { return }
        register(name, on: manager, undo: undo, redo: redo)
    }

    private func register(_ name: String, on manager: UndoManager, undo: @escaping @MainActor () async -> Void, redo: @escaping @MainActor () async -> Void) {
        manager.registerUndo(withTarget: self) { store in
            // The reverse is registered now, inside the undo, so it becomes the redo.
            store.register(name, on: manager, undo: redo, redo: undo)
            store.undoTask = Task { @MainActor in
                store.replayingUndo = true
                await undo()
                store.replayingUndo = false
            }
        }
        if !manager.isUndoing && !manager.isRedoing { manager.setActionName(name) }
    }
}
