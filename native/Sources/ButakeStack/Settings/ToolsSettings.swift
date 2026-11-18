import AppKit
import SwiftUI

/// Ajustes › Herramientas: one row per tool with its switch. Turning one on or off keeps its data;
/// deleting the data is a separate action in the row's menu, and asks first.
struct ToolsSettings: View {
    @Bindable var store: StackStore
    @Bindable var router = SettingsRouter.shared
    @State private var loading = true
    @State private var deleting: ToolInfo?
    var body: some View {
        Form {
            Section {
                if store.plugins.isEmpty {
                    if loading && !store.pluginsLoaded {
                        ProgressView().controlSize(.small).accessibilityIdentifier("plugins.loading")
                    } else {
                        LabeledContent {
                            if !store.pluginsLoaded {
                                Button { Task { await reload() } } label: { Label(L("common.retry"), systemImage: Symbols.reload) }
                                    .accessibilityIdentifier("plugins.retry")
                            }
                        } label: {
                            Text(L(store.pluginsLoaded ? "plugins.none" : "plugins.loadFailed")).foregroundStyle(.secondary)
                        }
                    }
                }
                ForEach(store.plugins) { plugin in
                    ToolSettingsRow(store: store, plugin: plugin, highlighted: router.highlightedTool == plugin.id) { deleting = plugin }
                }
            } footer: {
                SettingsFooter(L("plugins.subtitle"))
            }
        }
        .formStyle(.grouped).themedScroll()
        .gitMigrationSheet(in: .settings)
        .task {
            await reload()
            if store.pluginEnabled("git") { GitMigration.shared.check() }
            #if DEBUG
            if let plugin = QAHooks.pluginDelete(store.plugins) { deleting = plugin }
            #endif
        }
        .confirmationDialog(deleting.map { String(format: L("plugins.deleteDataTitle"), $0.title) } ?? "",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { plugin in
            Button(L("plugins.deleteDataButton"), role: .destructive) { Task { await store.removePlugin(plugin, deleteData: true) } }
                .accessibilityIdentifier("plugins.confirmDelete")
            Button(L("common.cancel"), role: .cancel) {}
        } message: { plugin in
            Text(L("plugin.\(plugin.id).deleteDataDetail"))
        }
    }

    private func reload() async {
        loading = true
        await store.loadPlugins()
        loading = false
    }
}

/// A tool: its tile, name and one line of what it does, the menu with its data and the switch.
private struct ToolSettingsRow: View {
    @Bindable var store: StackStore
    let plugin: ToolInfo
    let highlighted: Bool
    let delete: () -> Void
    var body: some View {
        LabeledContent {
            HStack(spacing: 10) {
                Menu {
                    Button { plugin.revealData() } label: { Label(L("plugins.showData"), systemImage: Symbols.folder) }
                        .disabled(!plugin.hasData || plugin.dataPath == nil)
                        .accessibilityIdentifier("plugins.showData.\(plugin.id)")
                    Button(role: .destructive, action: delete) { Label(L("plugins.deleteData"), systemImage: Symbols.delete) }
                        .disabled(!plugin.canDeleteData)
                        .accessibilityIdentifier("plugins.delete.\(plugin.id)")
                    // Git: what the former Butake Git app listed, while there is something to bring.
                    if plugin.id == "git" && plugin.enabled && GitMigration.shared.offered {
                        Divider()
                        Button { GitMigration.shared.presenter = .settings } label: { Label(L("git.migration.actionEllipsis"), systemImage: Symbols.importing) }
                            .accessibilityIdentifier("plugins.git.migrate")
                    }
                } label: {
                    Label(L("plugins.options"), systemImage: Symbols.more).labelStyle(.iconOnly)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help(L("plugins.options")).accessibilityIdentifier("plugins.options.\(plugin.id)")
                Toggle(plugin.title, isOn: Binding(get: { plugin.enabled }, set: { enabled in
                    Task { await store.setPlugin(plugin, enabled: enabled) }
                }))
                .toggleStyle(.switch).labelsHidden()
                .disabled(store.busy != nil)
                .accessibilityIdentifier("plugins.toggle.\(plugin.id)")
            }
        } label: {
            Label {
                Text(plugin.title)
                Text(localized("plugin.\(plugin.id).row") ?? plugin.summary).lineLimit(1)
            } icon: {
                TechLogo(tech: plugin.tech, size: 22)
            }
        }
        .help(plugin.summary)
        // A link led here to a tool that is off: its row stands out until another tab opens.
        .background {
            if highlighted { RoundedRectangle(cornerRadius: Radius.small).fill(Brand.accent.opacity(0.15)).padding(-6) }
        }
        .accessibilityIdentifier("plugins.row.\(plugin.id)")
    }
}
