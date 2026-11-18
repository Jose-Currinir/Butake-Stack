import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Ayuda › «Informar de un problema…»: the report written out for the user to read, copy or save. It says
/// what was taken out and sends nothing anywhere (E-04).
struct ReportProblemSheet: View {
    @Bindable var store: StackStore
    @State private var note = ""
    @State private var log: [String] = []
    @State private var saved: String?

    private var text: String { ProblemReport.build(note: note, failures: store.recentFailures, log: log) }

    var body: some View {
        SheetFrame(title: L("error.report.title"), symbol: Symbols.debugDump, detail: L("error.report.detail"),
                   note: L("error.report.note.removed"), width: 560, height: 520,
                   actionTitle: L("common.copy"), actionSymbol: Symbols.copy, actionID: "report.copy", cancelID: "report.close",
                   cancelTitle: L("common.close"),
                   action: { ProblemReport.copy(text); saved = L("error.report.copied"); return false },
                   content: {
            VStack(alignment: .leading, spacing: 10) {
                Text(L("error.report.whatHappened")).font(.uiCallout.weight(.medium))
                TextField(L("error.report.whatHappenedPrompt"), text: $note, axis: .vertical)
                    .lineLimit(2...4).textFieldStyle(.roundedBorder).accessibilityIdentifier("report.note")
                ScrollView {
                    Text(text).font(.uiMonospaced).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                }
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: Radius.row))
                .accessibilityIdentifier("report.text")
            }
        }, status: {
            HStack(spacing: 8) {
                Button(L("error.report.save")) { save() }.accessibilityIdentifier("report.save")
                if let saved { Text(saved).font(.uiCaption).foregroundStyle(.secondary) }
            }
        })
        .task {
            log = await Task.detached { ProblemReport.recentLog() }.value
        }
    }

    private func save() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = L("error.report.fileName")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try text.write(to: url, atomically: true, encoding: .utf8); saved = L("error.report.savedFile") }
        catch { store.report(error, title: L("error.report.saveFailed")) }
    }
}
