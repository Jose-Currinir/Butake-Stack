import SwiftUI

/// Undo for what can be reverted (Edición › Deshacer, ⌘Z), on the window's `UndoManager`.
///
/// An action that worked calls `undoable` with the name the menu shows («Deshacer Iniciar Tienda»)
/// and the two ways of the change: `undo` takes it back and `redo` makes it again. Undoing registers
/// the reverse on its own, so Rehacer (⇧⌘Z) works with no more code. While an undo or a redo runs,
/// the actions it repeats do not register again. What cannot be taken back (a deleted database,
/// a removed project's Keychain items) keeps its confirmation instead.
/// The notice that follows an action that can be undone: its name, and a token so a later offer is
/// not hidden by the timer of an earlier one.
struct UndoOffer: Equatable {
    let name: String
    let token = UUID()
}

extension StackStore {
    /// How long the notice stays (it also goes away with ⌘Z or the next action's notice).
    static let undoOfferSeconds: Double = 6

    /// Registers a change that worked. Without a window's manager (the window never opened) nothing is
    /// registered: the action still happened.
    func undoable(_ name: String, undo: @escaping @MainActor () async -> Void, redo: @escaping @MainActor () async -> Void) {
        guard !replayingUndo, let manager = undoManager else { return }
        register(name, on: manager, undo: undo, redo: redo)
        offerUndo(name)
    }

    /// Shows «Hecho: <acción> · Deshacer» for a few seconds.
    private func offerUndo(_ name: String) {
        let offer = UndoOffer(name: name)
        withAnimation(.snappy) { undoOffer = offer }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.undoOfferSeconds))
            withAnimation(.snappy) { if self?.undoOffer == offer { self?.undoOffer = nil } }
        }
    }

    /// The notice's button: the same as ⌘Z.
    func undoOffered() {
        undoOffer = nil
        undoManager?.undo()
    }

    private func register(_ name: String, on manager: UndoManager, undo: @escaping @MainActor () async -> Void, redo: @escaping @MainActor () async -> Void) {
        manager.registerUndo(withTarget: self) { store in
            // The reverse is registered now, inside the undo, so it becomes the redo.
            store.undoOffer = nil
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
