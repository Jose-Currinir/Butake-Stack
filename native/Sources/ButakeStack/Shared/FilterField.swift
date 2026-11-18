import SwiftUI

/// A search field inside a pane (the hosts of the SSH terminal), with its clear button. The
/// window's own search is the system one (`.searchable` in the sidebar).
struct FilterField: View {
    @Binding var text: String
    let identifier: String
    let prompt: String
    /// Bumped by a page (⌘F) to put the keyboard in the field.
    var focusRequests = 0
    @FocusState private var focused: Bool
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: Symbols.search).font(.uiCallout.weight(.medium)).foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain).font(.uiBody)
                .focused($focused)
                .onChange(of: focusRequests) { focused = true }
                .onExitCommand { text = "" }
                .accessibilityIdentifier(identifier)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Label(L("filter.clear"), systemImage: Symbols.clear).labelStyle(.iconOnly).foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help(L("filter.clear"))
                .accessibilityIdentifier("\(identifier).clear")
            }
        }
        .padding(.horizontal, 10).frame(minHeight: 30)
        .background(Capsule().fill(.quaternary))
    }
}
