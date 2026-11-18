import SwiftUI

/// «Hecho: <acción> · Deshacer». Its clock waits while the pointer is over it or the keyboard focus is
/// on its button, so it never leaves from under the hand that is about to press it.
struct UndoOfferBar: View {
    let offer: UndoOffer
    let store: StackStore
    @State private var hovering = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 12) {
            Label(String(format: L("menu.undoDone"), offer.name), systemImage: Symbols.success).font(.uiCallout.weight(.medium))
            Button(L("menu.undoAction")) { store.undoOffered() }
                .buttonStyle(.borderless).font(.uiCallout.weight(.semibold))
                .focused($focused)
                .accessibilityIdentifier("toast.undo")
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .chromeGlass()
        .onHover { hovering = $0; store.holdUndoOffer(hovering || focused) }
        .onChange(of: focused) { store.holdUndoOffer(hovering || focused) }
        .onDisappear { store.holdUndoOffer(false) }
        .accessibilityIdentifier("toast.undoOffer")
    }
}
