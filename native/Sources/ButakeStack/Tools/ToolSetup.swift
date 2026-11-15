import AppKit
import SwiftUI

/// What a project needs so its mail or its dumps come here: lines for its `.env` (Stack never writes
/// it) and a button that copies them. In an empty page and in the toolbar's popover.
struct ToolSetup: View {
    let lines: [String]
    let footer: String
    let identifier: String
    @State private var copied = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // One text per line: its height does not depend on the width it is offered, so the page's
            // minimum height stays small (a text fixed to its wrapped height made the whole window
            // taller than the screen's frame and slid every column under the title bar).
            VStack(alignment: .leading, spacing: 2) {
                ForEach(lines, id: \.self) { Text($0).lineLimit(1).truncationMode(.middle).help($0) }
            }
            .font(.uiCallout.monospaced()).textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityIdentifier("\(identifier).lines")
            Text(footer).font(.uiCaption).foregroundStyle(.secondary)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(lines.joined(separator: "\n") + "\n", forType: .string)
                copied = true
            } label: {
                Label(copied ? L("snippet.copied") : L("snippet.copy"), systemImage: copied ? Symbols.success : Symbols.copy)
            }
            .buttonStyle(.bordered).accessibilityIdentifier("\(identifier).copy")
        }
        .frame(maxWidth: 440, alignment: .leading)
    }
}

/// The toolbar's «Configurar proyecto»: the same lines in a popover.
struct ToolSetupButton: View {
    let lines: [String]
    let footer: String
    let identifier: String
    @State private var showing = false
    var body: some View {
        Button { showing.toggle() } label: { Label(L("plugins.setup"), systemImage: Symbols.info) }
            .help(L("plugins.setupHelp"))
            .accessibilityIdentifier("\(identifier).toolbar.setup")
            .popover(isPresented: $showing, arrowEdge: .bottom) {
                ToolSetup(lines: lines, footer: footer, identifier: "\(identifier).setup").padding(16)
            }
    }
}

/// Another program holds the receiver's port: who, and that nothing arrives until it is free. (The
/// supervisor's own state is in the status bar only.)
struct ReceiverConflict: View {
    let port: Int
    let owner: String
    var body: some View {
        Notice(.warning, String(format: L("mail.busy"), port, owner.isEmpty ? "?" : owner))
            .padding([.horizontal, .top], 12)
    }
}
