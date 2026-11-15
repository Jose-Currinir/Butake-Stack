import AppKit
import SwiftUI

fileprivate struct ConfigCandidate: Codable, Identifiable, Sendable {
    var alias: String
    var host: SSHHost
    var jumpAlias: String?
    var warnings: [String]
    var importable: Bool
    var existing: String?
    var id: String { alias }
}
fileprivate struct ConfigImportResult: Codable, Sendable {
    struct Skipped: Codable, Sendable { var alias: String; var reason: String }
    var imported: [String]
    var skipped: [Skipped]
}

/// Preview of ~/.ssh/config (or another file): the user picks which hosts to bring. The file is
/// only read; nothing in it changes.
struct SSHConfigImportSheet: View {
    @State private var path = ""
    @State private var candidates: [ConfigCandidate] = []
    @State private var chosen: Set<String> = []
    @State private var loading = true
    @State private var failure: String?
    @State private var result: ConfigImportResult?
    let store = StackStore.shared
    var body: some View {
        SheetFrame(title: L("ssh.config.title"), symbol: Symbols.importing, detail: path.isEmpty ? "~/.ssh/config" : path,
                   note: L("ssh.config.privacy"), width: 640, height: 560, actionTitle: String(format: L("ssh.config.importButton"), chosen.count),
                   actionID: "ssh.config.import", canAct: !chosen.isEmpty && !loading, cancelID: "ssh.config.cancel",
                   cancelTitle: result == nil ? nil : L("common.done")) {
            await runImport()
            return false
        } content: {
            Form {
                Section {
                    if loading {
                        ProgressView().frame(maxWidth: .infinity)
                    } else if let failure {
                        ContentUnavailableView(L("ssh.config.unreadable"), systemImage: Symbols.warning, description: Text(failure))
                    } else if candidates.isEmpty {
                        ContentUnavailableView(L("ssh.config.empty"), systemImage: Symbols.file)
                    }
                    ForEach(candidates) { candidate in row(candidate) }
                } header: {
                    HStack {
                        Text(L("ssh.config.hosts"))
                        Spacer()
                        Button { chooseFile() } label: { Label(L("ssh.config.otherFile"), systemImage: Symbols.file) }
                            .buttonStyle(.bordered).accessibilityIdentifier("ssh.config.otherFile")
                    }
                } footer: {
                    SettingsFooter(L("ssh.config.detail"))
                }
                if let result {
                    Section {
                        Label(String(format: L("ssh.config.imported"), result.imported.count), systemImage: Symbols.success).foregroundStyle(Brand.success)
                        ForEach(result.skipped, id: \.alias) { skipped in
                            Label(String(format: L("ssh.config.skipped"), skipped.alias, skipped.reason == "jump_unknown" ? L("ssh.config.reason.jump_unknown") : localized("error.\(skipped.reason)") ?? L("engine.requestFailed")),
                                  systemImage: Symbols.warning)
                                .foregroundStyle(Brand.warning)
                        }
                    }
                    .accessibilityIdentifier("ssh.config.result")
                }
            }
            .formStyle(.grouped).themedScroll()
            .frame(minHeight: 340)
        } status: {
            EmptyView()
        }
        .task {
            #if DEBUG
            if let qa = QAHooks.sshConfigPath { path = qa }
            #endif
            await preview()
        }
    }

    fileprivate func row(_ candidate: ConfigCandidate) -> some View {
        let host = candidate.host
        let extras = [
            candidate.jumpAlias.map { String(format: L("ssh.config.via"), $0) },
            host.identity.map { String(format: L("ssh.config.identity"), ($0 as NSString).lastPathComponent) },
            host.forwards.isEmpty ? nil : String(format: L("ssh.config.forwards"), host.forwards.count),
        ].compactMap { $0 }
        return Toggle(isOn: Binding(get: { chosen.contains(candidate.alias) }, set: { if $0 { chosen.insert(candidate.alias) } else { chosen.remove(candidate.alias) } })) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(candidate.alias)
                    if candidate.existing != nil { Chip(text: L("ssh.config.alreadySaved"), tint: Brand.info) }
                    if !candidate.importable { Chip(text: L("ssh.config.notImportable"), tint: Brand.danger) }
                }
                Text(host.address).font(.uiCaption.monospaced()).foregroundStyle(.secondary)
                if !extras.isEmpty { Text(extras.joined(separator: " · ")).font(.uiCaption).foregroundStyle(.secondary) }
                ForEach(candidate.warnings, id: \.self) { warning in
                    Label(L("ssh.config.warning.\(warning)"), systemImage: Symbols.warning).font(.uiCaption).foregroundStyle(Brand.warning)
                }
            }
        }
        .toggleStyle(.checkbox)
        .disabled(!candidate.importable)
        .accessibilityIdentifier("ssh.config.pick.\(candidate.alias)")
    }

    func preview() async {
        loading = true
        defer { loading = false }
        do {
            candidates = try await store.call(["method": "sshConfigPreview", "path": path])
            chosen = Set(candidates.filter { $0.importable && $0.existing == nil }.map(\.alias))
            failure = nil
        } catch let error as EngineFailure {
            candidates = []
            failure = error.errorDescription
        } catch { failure = L("engine.requestFailed") }
    }

    func runImport() async {
        do {
            let value: ConfigImportResult = try await store.call(["method": "sshConfigImport", "path": path, "aliases": Array(chosen)])
            result = value
            await SSHTerminal.shared.load()
            if let first = value.imported.first { SSHTerminal.shared.selection = first }
            await preview()
        } catch { store.report(error) }
    }

    func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        panel.message = L("ssh.config.chooseMessage")
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        if panel.runModal() == .OK, let url = panel.url {
            path = url.path
            result = nil
            Task { await preview() }
        }
    }
}
