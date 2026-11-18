import AppKit
import SwiftUI

/// A service type (databases, cache and queues…): one row per installed service with its state,
/// version, Iniciar/Detener and its menu; the rest under «Disponibles», installed through the same
/// version picker as the languages. The title lives in the window's bar.
struct CategoryPage: View {
    @Bindable var store: StackStore
    let category: String
    @State private var picking: String?
    @State private var removing: String?
    @State private var logProcess: String?
    @State private var reinstalling: String?
    var scope: String { "service.\(category)" }
    var engines: [String] { Route.engines(in: category) }
    var installed: [String] { engines.filter { store.engineVersion($0) != nil } }
    var available: [String] { engines.filter { store.engineVersion($0) == nil } }
    var unavailable: [(String, String)] { Route.unavailable(in: category) }
    /// Projects that use a service of this type, with the services they use.
    var users: [(Project, [String])] {
        store.projects.compactMap { project in
            let used = project.services.filter(engines.contains)
            return used.isEmpty ? nil : (project, used)
        }
    }

    var body: some View {
        Form {
            PartialFailureNotice(store: store, area: .runtimes).listRowBackground(Color.clear).listRowInsets(EdgeInsets())
            if category == "broadcasting" { ReverbSection(store: store) { logProcess = $0 } }
            if installed.contains("postgres"), store.postgresWithoutExtensions, let version = store.engineVersion("postgres") {
                Section {
                    Notice(.warning, L("engine.noExtensions"), detail: L("engine.noExtensionsDetail")) {
                        Button { reinstalling = version } label: { Label(L("engine.reinstallExtensionsMenu"), systemImage: Symbols.install) }
                            .buttonStyle(.bordered).disabled(store.busy != nil)
                            .accessibilityIdentifier("\(scope).postgres.reinstall")
                    }
                }
            }
            if !installed.isEmpty {
                Section(L("category.installed")) {
                    ForEach(installed, id: \.self) { name in
                        EngineRow(store: store, name: name, scope: "\(scope).\(name)",
                                  pick: { picking = name }, remove: { removing = name }, logs: { logProcess = "stack.\(name)" })
                    }
                }
            }
            if installed.contains("postgres") { ServiceExtensionsSection(store: store, scope: "\(scope).postgres.ext") }
            if !available.isEmpty {
                Section(L("category.available")) {
                    ForEach(available, id: \.self) { name in
                        LogoRow {
                            Button { picking = name } label: { Label(L("category.install"), systemImage: Symbols.install) }
                                .disabled(store.busy != nil)
                                .accessibilityIdentifier("\(scope).\(name).install")
                        } label: {
                            EngineLabel(name: name, detail: DownloadInfo.of(name).source)
                        }
                        .contextMenu {
                            Button { picking = name } label: { Label(L("category.install"), systemImage: Symbols.install) }
                                .disabled(store.busy != nil)
                                .accessibilityIdentifier("\(scope).\(name).install.context")
                        }
                    }
                }
            }
            if !unavailable.isEmpty {
                Section(L("category.unavailable")) {
                    ForEach(unavailable, id: \.0) { name, reason in
                        EngineLabel(name: name.lowercased(), detail: reason).help(reason)
                    }
                }
            }
            if !users.isEmpty {
                Section(L("engine.sites")) {
                    ForEach(users, id: \.0.id) { project, used in
                        ProjectLinkRow(project: project, detail: used.map { Tech.of($0).title }.joined(separator: " · ")) { store.openSite(project.id) }
                            .accessibilityIdentifier("\(scope).project.\(project.id)")
                    }
                }
            }
        }
        .formStyle(.grouped).themedScroll()
        .task {
            await store.refreshRuntimes()
            #if DEBUG
            if let id = QAHooks.versionPicker, engines.contains(id) { picking = id }
            #endif
        }
        .sheet(item: Binding(get: { picking.map { LogTarget(id: $0) } }, set: { picking = $0?.id })) { target in
            VersionPickerSheet(store: store, provider: .tool(store, target.id), scope: "\(scope).\(target.id)").themedSheet()
        }
        .sheet(item: Binding(get: { reinstalling.map { LogTarget(id: $0) } }, set: { reinstalling = $0?.id })) { target in
            ReinstallExtensionsSheet(store: store, version: target.id).themedSheet()
        }
        .showsLogs($logProcess, store: store)
        .confirmationDialog(removing.map { String(format: L("runtimes.confirmRemove"), "\(Tech.of($0).title) \(store.engineVersion($0) ?? "")") } ?? "",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), presenting: removing) { name in
            Button(L("common.remove"), role: .destructive) {
                if let version = store.engineVersion(name) { Task { await store.removeTool(name, version) } }
            }
            .accessibilityIdentifier("\(scope).\(name).confirmRemove")
            Button(L("common.cancel"), role: .cancel) {}
        } message: { _ in Text(L("engine.removeDetail")) }
    }
}

/// A service's logo, name and one line under it.
private struct EngineLabel: View {
    let name: String
    let detail: String
    var body: some View {
        HStack(spacing: 10) {
            TechLogo(tech: .of(name), size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(Tech.of(name).title)
                Text(detail).font(.uiCaption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }
}

/// An installed service: version and address, its state, Iniciar/Detener and the menu with its
/// logs, its data folder, the database client and the rest of its versions.
private struct EngineRow: View {
    @Bindable var store: StackStore
    let name: String
    let scope: String
    let pick: () -> Void
    let remove: () -> Void
    let logs: () -> Void
    var enabled: Bool { store.engineEnabled(name) }
    var phase: ProcessPhase { enabled ? store.phase("stack.\(name)") : .stopped }
    var detail: String {
        var parts = [store.engineVersion(name) ?? ""]
        if let port = store.enginePort(name) { parts.append("127.0.0.1:\(port)") }
        if let restarts = store.process("stack.\(name)")?.status.restarts, restarts > 0 { parts.append(String(format: L("engine.restartsCount"), restarts)) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        // The switch keeps its whole title while the row fits whole; otherwise only its symbol
        // (with its help), and the name keeps its width.
        ViewThatFits(in: .horizontal) {
            LogoRow { controls(titled: true) } label: { EngineLabel(name: name, detail: detail) }
            LogoRow { controls(titled: false) } label: { EngineLabel(name: name, detail: detail) }
        }
        .accessibilityIdentifier(scope)
        // The same actions as the row's buttons and its «⋯» menu.
        .contextMenu {
            Button { Task { await store.setEngine(name, enabled: !enabled) } } label: {
                Label(enabled ? L("engine.stop") : L("engine.start"), systemImage: enabled ? Symbols.stop : Symbols.start)
            }
            .disabled(store.busy != nil)
            .accessibilityIdentifier("\(scope).\(enabled ? "stop" : "start").context")
            if let port = store.enginePort(name) {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("127.0.0.1:\(port)", forType: .string)
                } label: { Label(L("engine.copyAddress"), systemImage: Symbols.copy) }
                    .accessibilityIdentifier("\(scope).copyAddress")
            }
            Divider()
            menuItems
        }
    }

    private func controls(titled: Bool) -> some View {
        HStack(spacing: 8) {
            Chip(text: L("state.\(phase.rawValue)"), symbol: phase.symbol, tint: phase.color)
            Button { Task { await store.setEngine(name, enabled: !enabled) } } label: {
                if titled {
                    Label(enabled ? L("engine.stop") : L("engine.start"), systemImage: enabled ? Symbols.stop : Symbols.start)
                } else {
                    Label(enabled ? L("engine.stop") : L("engine.start"), systemImage: enabled ? Symbols.stop : Symbols.start)
                        .labelStyle(.iconOnly)
                }
            }
            .disabled(store.busy != nil)
            .help(enabled ? L("engine.stop") : L("engine.start"))
            .accessibilityIdentifier("\(scope).\(enabled ? "stop" : "start")")
            menu
        }
        .fixedSize()
    }

    private var menu: some View {
        Menu { menuItems } label: {
            Label(L("runtimes.actions"), systemImage: Symbols.more).labelStyle(.iconOnly)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help(L("runtimes.actions"))
        .accessibilityIdentifier("\(scope).menu")
    }

    @ViewBuilder private var menuItems: some View {
            Button(action: logs) { Label(L("engine.logs"), systemImage: Symbols.logs) }
                .disabled(!enabled)
            Button { Folder.open("data/\(name)") } label: { Label(L("engine.showData"), systemImage: Symbols.folder) }
            if Route.category(of: name) == "database" && store.pluginEnabled("database-client") {
                Button { store.route = .tool("database-client") } label: { Label(L("engine.openClient"), systemImage: Symbols.database) }
            }
            Button(action: pick) { Label(L("engine.otherVersion"), systemImage: Symbols.install) }
            Divider()
            Button(role: .destructive, action: remove) { Label(L("engine.remove"), systemImage: Symbols.delete) }
                .disabled(enabled || store.busy != nil)
                .help(enabled ? L("engine.removeRunning") : "")
    }
}

/// Reverb runs inside each Laravel project; this lists and controls all of them in one place.
private struct ReverbSection: View {
    @Bindable var store: StackStore
    let showLog: (String) -> Void
    var body: some View {
        let items = store.projects.flatMap { project in
            project.processes.filter { $0.args.contains("reverb:start") }.map { (project, $0) }
        }
        Section {
            if items.isEmpty {
                ContentUnavailableView(L("broadcasting.none"), systemImage: Tech.of("reverb").symbol)
            }
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(spacing: 10) {
                    TechLogo(tech: item.0.tech, size: 26)
                    ProcessRow(store: store, id: "\(item.0.id).\(item.1.name)", process: item.1, showLog: showLog)
                }
            }
        } header: {
            Text(Tech.of("reverb").title)
        } footer: {
            Text(L("broadcasting.help")).font(.uiCaption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
