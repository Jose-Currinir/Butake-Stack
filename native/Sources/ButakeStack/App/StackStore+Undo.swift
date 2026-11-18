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

    /// What the notice says; the time it stays depends on its length.
    var notice: String { String(format: L("menu.undoDone"), name) + " · " + L("menu.undoAction") }
    var seconds: Double { StackStore.undoOfferSeconds(forLength: notice.count) }
}

extension StackStore {
    /// How long a notice stays (it also goes away with ⌘Z or the next action's notice): 8 seconds, and
    /// a little more for each character past 30, so a long name can still be read; never over 20.
    nonisolated static func undoOfferSeconds(forLength length: Int) -> Double { min(20, 8 + 0.1 * Double(max(0, length - 30))) }
    /// How often the notice's clock ticks.
    private static let undoTick: Double = 0.25

    /// The one way to say something to VoiceOver (notices, what an undo or redo did). Tests replace
    /// `announcer` to read what would be said.
    static func postAnnouncement(_ text: String) { AccessibilityNotification.Announcement(text).post() }
    func announce(_ text: String) { announcer(text) }

    /// Registers a change that worked. Without a window's manager (the window never opened) nothing is
    /// registered: the action still happened.
    func undoable(_ name: String, undo: @escaping @MainActor () async -> Void, redo: @escaping @MainActor () async -> Void) {
        guard !replayingUndo, let manager = undoManager else { return }
        register(name, on: manager, undo: undo, redo: redo)
        offerUndo(name)
    }

    /// Shows «Hecho: <acción> · Deshacer» while its clock runs; the clock waits while the pointer or
    /// the focus is on the notice (`holdUndoOffer`).
    private func offerUndo(_ name: String) {
        let offer = UndoOffer(name: name)
        undoRemaining = offer.seconds
        undoHeld = false
        Motion.run(.snappy) { undoOffer = offer }
        announce(String(format: L("menu.undoAnnounce"), String(format: L("menu.undoDone"), name)))
        undoTimer?.cancel()
        undoTimer = Task { [weak self] in
            while let self, self.undoOffer == offer {
                try? await Task.sleep(for: .seconds(Self.undoTick))
                if Task.isCancelled || self.advanceUndoOffer(by: Self.undoTick) { return }
            }
        }
    }

    /// The notice's pointer or focus came or went: while held, its time does not run.
    func holdUndoOffer(_ held: Bool) { undoHeld = held }

    /// Runs the notice's clock `seconds` forward; true when it ran out and the notice went away.
    @discardableResult
    func advanceUndoOffer(by seconds: Double) -> Bool {
        guard undoOffer != nil, !undoHeld else { return false }
        undoRemaining -= seconds
        guard undoRemaining <= 0 else { return false }
        Motion.run(.snappy) { undoOffer = nil }
        return true
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
            store.announce(String(format: L(manager.isRedoing ? "menu.redone" : "menu.undone"), name))
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
