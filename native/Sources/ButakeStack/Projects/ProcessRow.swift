import AppKit
import SwiftUI

/// Process with its state, log button and start/stop switch.
struct ProcessRow: View {
    let store: StackStore
    let id: String
    let process: ProjectProcess
    let showLog: (String) -> Void
    var body: some View {
        let phase = store.phase(id)
        HStack(spacing: 10) {
            Image(systemName: phase.symbol).foregroundStyle(phase.color).font(.uiSubheadline)
                .help(L("state.\(phase.rawValue)")).accessibilityLabel(L("state.\(phase.rawValue)"))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(process.name).font(.uiBody.weight(.medium))
                    if process.autostart {
                        Image(systemName: Symbols.active).font(.uiCaption2).foregroundStyle(.secondary)
                            .help(L("process.autostart")).accessibilityLabel(L("process.autostart"))
                    }
                }
                Text(process.commandLine).font(.uiCaption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 6)
            Button { showLog(id) } label: { Label(L("process.logs"), systemImage: Symbols.logs).labelStyle(.iconOnly) }
                .buttonStyle(.borderless).help(L("process.logs")).accessibilityIdentifier("process.logs.\(id)")
            Toggle(process.name, isOn: Binding(get: { phase == .running || phase == .starting }, set: { on in Task { await store.processAction(id, on ? "start" : "stop") } }))
                .toggleStyle(.switch).controlSize(.small).labelsHidden()
                .disabled(!store.daemonRunning)
                .accessibilityLabel(process.name)
                .accessibilityValue(L("state.\(phase.rawValue)"))
                .accessibilityIdentifier("process.toggle.\(id)")
        }
    }
}
