import AppKit
import SwiftUI

/// The system's token field for a host's tags: each tag is a token, written with a comma or Return,
/// and the existing ones are offered as the user types.
struct SSHTagField: NSViewRepresentable {
    @Binding var tags: [String]
    let suggestions: [String]
    var prompt: String = ""

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTokenField {
        let field = NSTokenField()
        field.delegate = context.coordinator
        field.tokenStyle = .rounded
        field.completionDelay = 0.1
        field.placeholderString = prompt
        field.bezelStyle = .roundedBezel
        field.isBezeled = true
        field.font = .preferredFont(forTextStyle: .body)
        field.lineBreakMode = .byWordWrapping
        field.cell?.wraps = true
        field.cell?.isScrollable = false
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setAccessibilityIdentifier("ssh.editor.tags")
        field.objectValue = tags
        return field
    }

    func updateNSView(_ field: NSTokenField, context: Context) {
        context.coordinator.parent = self
        // Only from outside: while the user types, the field is the source.
        if field.currentEditor() == nil, (field.objectValue as? [String]) != tags { field.objectValue = tags }
    }

    @MainActor final class Coordinator: NSObject, NSTokenFieldDelegate {
        var parent: SSHTagField
        init(_ parent: SSHTagField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) { read(notification) }
        func controlTextDidEndEditing(_ notification: Notification) { read(notification) }
        private func read(_ notification: Notification) {
            guard let field = notification.object as? NSTokenField else { return }
            let values = (field.objectValue as? [Any] ?? []).compactMap { $0 as? String }
            parent.tags = SSHHost.cleanTags(values)
        }

        func tokenField(_ tokenField: NSTokenField, completionsForSubstring substring: String, indexOfToken tokenIndex: Int,
                        indexOfSelectedItem selectedIndex: UnsafeMutablePointer<Int>?) -> [Any]? {
            let used = Set(parent.tags.map { $0.lowercased() })
            return parent.suggestions.filter { !used.contains($0.lowercased()) && $0.localizedCaseInsensitiveContains(substring) }
        }
    }
}
