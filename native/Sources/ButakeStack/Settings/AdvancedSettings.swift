import AppKit
import SwiftUI

/// Ajustes › Avanzado: Stack's folders, exporting and restoring the configuration, the language
/// versions linked in the terminal.
struct AdvancedSettings: View {
    @Bindable var store: StackStore
    @Environment(\.openWindow) private var openWindow
    @State private var restore: RestoreRequest?
    @State private var projectsFolder = Folder.projects
    @State private var movingData = false
    @AppStorage(Folder.sortsKey) private var sortsByPlace = true
    var body: some View {
        Form {
            Section(L("general.folders")) {
                projectsRow
                Toggle(isOn: $sortsByPlace) {
                    Text(L("settings.sortProjects"))
                    Text(L("settings.sortProjectsDetail"))
                }
                .accessibilityIdentifier("settings.projects.sort")
                dataRow
                folder("data", title: L("general.folder.data"), symbol: Symbols.database)
                folder("logs", title: L("general.folder.logs"), symbol: Symbols.logs)
                folder("config", title: L("general.folder.config"), symbol: Symbols.settings)
            }
            Section {
                LabeledContent(L("settings.export")) {
                    Button { Task { await store.exportConfiguration() } } label: { Label(L("backup.export"), systemImage: Symbols.share) }
                        .accessibilityIdentifier("backup.export")
                }
                LabeledContent(L("settings.restoreRow")) {
                    Button { Task { restore = await store.planRestore() } } label: { Label(L("backup.restore"), systemImage: Symbols.importing) }
                        .accessibilityIdentifier("backup.restore")
                }
                if store.pluginEnabled("vault") {
                    LabeledContent(L("settings.vaultBackup")) {
                        Button { VaultSession.shared.requestBackup(); show(.tool("vault")) } label: { Label(L("backup.vaultLink"), systemImage: Symbols.vault) }
                            .accessibilityIdentifier("backup.vault")
                    }
                    .help(L("backup.vaultHint"))
                }
            } header: {
                Text(L("backup.title"))
            } footer: {
                SettingsFooter(L("backup.footer"))
            }
            .disabled(store.busy != nil)
            Section {
                ForEach([("php", "php"), ("node", "node"), ("jdk", "java"), ("python", "python")], id: \.0) { language, page in
                    terminalRow(language, page: page)
                }
            } header: {
                Text(L("terminal.title"))
            } footer: {
                SettingsFooter(L("settings.terminalFooter"))
            }
        }
        .formStyle(.grouped).themedScroll()
        .task { store.terminalLinks = (try? await store.call(["method": "terminalStatus"])) ?? store.terminalLinks }
        .sheet(item: $restore) { request in RestoreSheet(store: store, request: request).themedSheet() }
        .sheet(isPresented: $movingData) { DataMigrationSheet(store: store).themedSheet() }
        .onAppear {
            #if DEBUG
            if QAHooks.dataMigrationSheet { Task { try? await Task.sleep(for: .seconds(1)); movingData = true } }
            #endif
        }
    }

    /// Where new projects go (and where adding or importing opens); made on first use, never here.
    private var projectsRow: some View {
        let path = projectsFolder
        return LabeledContent {
            HStack(spacing: 8) {
                Button(action: chooseProjects) { Label(L("common.choose"), systemImage: Symbols.edit) }
                    .accessibilityIdentifier("settings.projects.choose")
                Button { Folder.revealProjects() } label: { Label(L("menu.showInFinder"), systemImage: Symbols.folder) }
                    .accessibilityIdentifier("settings.projects.reveal")
            }
        } label: {
            Label {
                Text(L("settings.projectsFolder"))
                Text(path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).lineLimit(1).truncationMode(.middle).help(path)
            } icon: {
                IconTile(symbol: Symbols.project, size: 22)
            }
        }
        .help(L("settings.projectsFolderHelp"))
    }

    /// Stack's own folder; while it still has the old name, the action that moves it.
    private var dataRow: some View {
        let path = Folder.base
        return Group {
            LabeledContent {
                Button { NSWorkspace.shared.open(Folder.baseURL) } label: { Label(L("menu.showInFinder"), systemImage: Symbols.folder) }
                    .accessibilityIdentifier("settings.data.reveal")
            } label: {
                Label {
                    Text(L("settings.dataFolder"))
                    Text(path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).lineLimit(1).truncationMode(.middle).help(path)
                } icon: {
                    IconTile(symbol: Symbols.server, size: 22)
                }
            }
            if offerMove {
                LabeledContent(L("migration.oldName")) {
                    Button { movingData = true } label: { Label(L("migration.open"), systemImage: Symbols.importing) }
                        .accessibilityIdentifier("settings.data.move")
                }
                .help(L("migration.openHelp"))
            }
        }
    }

    /// Only while the data is in the folder of the old name (and in its QA screenshot).
    private var offerMove: Bool {
        #if DEBUG
        if QAHooks.dataMigration { return true }
        #endif
        return Folder.usesOldData
    }

    private func chooseProjects() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: FileManager.default.fileExists(atPath: projectsFolder) ? projectsFolder : NSHomeDirectory())
        panel.prompt = L("new.choosePrompt")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Folder.setProjects(url.path)
        projectsFolder = Folder.projects
    }

    private func show(_ route: Route) {
        store.route = route
        openWindow(id: "main")
    }

    private func folder(_ relative: String, title: String, symbol: String) -> some View {
        let path = Folder.base + "/" + relative
        return LabeledContent {
            Button { Folder.open(relative) } label: { Label(L("menu.showInFinder"), systemImage: Symbols.folder) }
                .accessibilityIdentifier("general.folder.\(relative)")
        } label: {
            Label {
                Text(title)
                Text(path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).lineLimit(1).truncationMode(.middle).help(path)
            } icon: {
                IconTile(symbol: symbol, size: 22)
            }
        }
    }

    /// Whether the terminal uses Stack's version of a language; it is changed on the language's page.
    private func terminalRow(_ language: String, page: String) -> some View {
        let tech = Tech.of(language)
        let linked = store.terminalLinks[language]
        return LabeledContent {
            HStack(spacing: 8) {
                Text(linked.map { $0.version ?? L("settings.terminalLinked") } ?? L("settings.terminalNotLinked")).foregroundStyle(.secondary)
                Button { show(.language(page)) } label: { Label(String(format: L("settings.openPage"), tech.title), systemImage: Symbols.forward) }
                    .accessibilityIdentifier("settings.terminal.\(language)")
            }
        } label: {
            Label { Text(tech.title) } icon: { TechLogo(tech: tech, size: 22) }
        }
    }
}
