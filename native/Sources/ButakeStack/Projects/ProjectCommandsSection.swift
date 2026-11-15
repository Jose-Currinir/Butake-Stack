import SwiftUI

/// The commands of a project without a server (P-42): «Comprobar», «Compilar» and any other it
/// has, each run by hand once, with how the last run ended and its log. They are defined in
/// «Ajustes del proyecto…».
struct ProjectCommandsSection: View {
    @Bindable var store: StackStore
    let project: Project
    let showLog: (String) -> Void
    var body: some View {
        Section {
            if project.processes.isEmpty {
                Text(L("commands.none")).foregroundStyle(.secondary)
            }
            ForEach(project.processes) { process in
                ProjectCommandRow(store: store, id: "\(project.id).\(process.name)", process: process, showLog: showLog)
            }
        } header: {
            Text(L("commands.title"))
        } footer: {
            Text(L("commands.help")).font(.uiCaption).foregroundStyle(.secondary)
                .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// «Comprobar» and «Compilar» by their names; any other command by its own.
    static func title(_ name: String) -> String {
        ["check", "build"].contains(name) ? L("commands.\(name)") : name
    }
}

/// What the supervisor is asked for a command (`processAction`).
private enum ProcessAction {
    static let start = "start"
    static let stop = "stop"
}

private struct ProjectCommandRow: View {
    let store: StackStore
    let id: String
    let process: ProjectProcess
    let showLog: (String) -> Void
    var body: some View {
        let phase = store.phase(id)
        let running = phase == .running || phase == .starting || phase == .stopping
        LabeledContent {
            HStack(spacing: 8) {
                if store.process(id) != nil {
                    Chip(text: L(running ? "commands.running" : phase == .crashed ? "commands.failed" : "commands.finished"),
                         symbol: running ? Symbols.start : phase == .crashed ? Symbols.warning : Symbols.success,
                         tint: running ? Brand.info : phase == .crashed ? Brand.warning : Brand.success)
                }
                Button { showLog(id) } label: { Label(L("process.logs"), systemImage: Symbols.logs).labelStyle(.iconOnly) }
                    .buttonStyle(.borderless).help(L("process.logs")).accessibilityIdentifier("commands.logs.\(id)")
                if running {
                    Button { Task { await store.processAction(id, ProcessAction.stop) } } label: {
                        Label(L("commands.stop"), systemImage: Symbols.stop)
                    }
                    .buttonStyle(.bordered).accessibilityIdentifier("commands.stop.\(id)")
                } else {
                    Button { Task { await store.processAction(id, ProcessAction.start); showLog(id) } } label: {
                        Label(L("commands.run"), systemImage: Symbols.start)
                    }
                    .buttonStyle(.bordered).disabled(!store.daemonRunning).accessibilityIdentifier("commands.run.\(id)")
                }
            }
        } label: {
            Text(ProjectCommandsSection.title(process.name))
            Text(process.commandLine).font(.uiCaption.monospaced()).lineLimit(1).truncationMode(.middle).help(process.commandLine)
        }
    }
}
