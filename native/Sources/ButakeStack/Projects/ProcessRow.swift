import AppKit
import SwiftUI

/// Process with its dot and its state in words, «Automático» when it starts with the project, and one
/// visible action: the start/stop switch. Registros, Reiniciar and the rest are in the «⋯» menu and
/// in the right click of the row.
struct ProcessRow: View {
    let store: StackStore
    let id: String
    let process: ProjectProcess
    let showLog: (String) -> Void
    var body: some View {
        let phase = store.phase(id)
        let live = phase == .running || phase == .starting
        HStack(spacing: 10) {
            StatusDot(color: phase.color, symbol: phase.markSymbol, label: L("state.\(phase.rawValue)"))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(process.name).font(.uiBody.weight(.medium))
                    if process.autostart {
                        Text(L("process.autostartShort")).font(.uiCaption2).foregroundStyle(.secondary)
                            .padding(.horizontal, 5).padding(.vertical, 1).background(Color.primary.opacity(0.07), in: Capsule())
                            .help(L("process.autostart")).accessibilityLabel(L("process.autostart"))
                            .accessibilityIdentifier("process.autostart.\(id)")
                    }
                }
                Text(process.commandLine).font(.uiCaption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 6)
            Text(L("state.\(phase.rawValue)")).font(.uiCaption).foregroundStyle(phase == .crashed ? Brand.dangerText : .secondary)
                .accessibilityIdentifier("process.state.\(id)")
            Menu {
                Button { showLog(id) } label: { Label(L("process.logs"), systemImage: Symbols.logs) }
                    .accessibilityIdentifier("process.logs.\(id)")
                Button { Task { await store.processAction(id, "restart") } } label: { Label(L("process.restart"), systemImage: Symbols.reload) }
                    .disabled(!store.daemonRunning || !live).accessibilityIdentifier("process.restart.\(id)")
            } label: {
                Label(L("process.more"), systemImage: Symbols.more).labelStyle(.iconOnly)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help(L("process.more")).accessibilityIdentifier("process.more.\(id)")
            Toggle(process.name, isOn: Binding(get: { live }, set: { on in Task { await store.processAction(id, on ? "start" : "stop") } }))
                .toggleStyle(.switch).controlSize(.small).labelsHidden()
                .disabled(!store.daemonRunning)
                .accessibilityLabel(process.name)
                .accessibilityValue(L("state.\(phase.rawValue)"))
                .accessibilityIdentifier("process.toggle.\(id)")
        }
        .contextMenu {
            Button { Task { await store.processAction(id, live ? "stop" : "start") } } label: {
                Label(live ? L("palette.stop") : L("palette.start"), systemImage: live ? Symbols.stop : Symbols.start)
            }
            .disabled(!store.daemonRunning).accessibilityIdentifier("process.menu.toggle.\(id)")
            Button { Task { await store.processAction(id, "restart") } } label: { Label(L("process.restart"), systemImage: Symbols.reload) }
                .disabled(!store.daemonRunning || !live).accessibilityIdentifier("process.menu.restart.\(id)")
            Divider()
            Button { showLog(id) } label: { Label(L("process.logs"), systemImage: Symbols.logs) }
                .accessibilityIdentifier("process.menu.logs.\(id)")
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(process.commandLine, forType: .string)
                store.notify(L("process.commandCopied"))
            } label: { Label(L("process.copyCommand"), systemImage: Symbols.copy) }
                .accessibilityIdentifier("process.menu.copy.\(id)")
        }
    }
}

/// «Iniciar todos», «Detener todos» and «Reiniciar todos» of a project's processes, in the menu of
/// the section's title.
struct ProcessBatchMenu: View {
    let store: StackStore
    let project: Project
    /// What each action applies to: start the ones that are off, stop and restart the ones that are on.
    static func targets(_ action: String, ids: [String], live: Set<String>) -> [String] {
        action == "start" ? ids.filter { !live.contains($0) } : ids.filter(live.contains)
    }
    private func run(_ action: String) {
        let ids = project.processes.map { "\(project.id).\($0.name)" }
        let live = Set(store.liveProcessIDs(project))
        let targets = Self.targets(action, ids: ids, live: live)
        Task { for id in targets { await store.processAction(id, action) } }
    }
    var body: some View {
        let live = !store.liveProcessIDs(project).isEmpty
        let allLive = store.liveProcessIDs(project).count == project.processes.count
        Menu {
            Button { run("start") } label: { Label(L("process.startAll"), systemImage: Symbols.start) }
                .disabled(allLive).accessibilityIdentifier("process.startAll")
            Button { run("stop") } label: {
                Label(L("process.stopAll"), systemImage: Symbols.stop)
            }
                .disabled(!live).accessibilityIdentifier("process.stopAll")
            Button { run("restart") } label: { Label(L("process.restartAll"), systemImage: Symbols.reload) }
                .disabled(!live).accessibilityIdentifier("process.restartAll")
        } label: {
            Label(L("process.all"), systemImage: Symbols.more).labelStyle(.iconOnly)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .disabled(!store.daemonRunning)
        .help(L("process.all")).accessibilityIdentifier("process.all")
    }
}
