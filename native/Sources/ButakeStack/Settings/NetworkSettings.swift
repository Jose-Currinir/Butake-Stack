import AppKit
import SwiftUI

/// Ajustes › Red: the `.test` domains and the local certificate, the web server that serves the
/// projects (Caddy and PHP-FPM) and its ports, and the watched folders.
struct NetworkSettings: View {
    @Bindable var store: StackStore
    var body: some View {
        Form {
            TrustSection(store: store)
            WebServerSection(store: store)
            WatchedFoldersSection(store: store)
        }
        .formStyle(.grouped).themedScroll()
    }
}

/// The resolver file for the local domains and the local certificate authority. Each change asks
/// first; then macOS asks for authorization in its own dialog. The password is never seen.
private struct TrustSection: View {
    @Bindable var store: StackStore
    @State private var confirmResolver = false
    @State private var confirmCa = false
    var trust: LocalTrust? { store.localTrust }
    var body: some View {
        Section {
            row(symbol: Symbols.network, title: L("trust.resolver.title"), detail: LocalTrust.resolverDetail(trust), ok: trust?.resolversReady == true) {
                Button { confirmResolver = true } label: { Label(LocalTrust.resolverAction(trust), systemImage: Symbols.network) }
                    .buttonStyle(.borderedProminent)
                    .disabled(trust == nil || store.busy != nil).accessibilityIdentifier("trust.resolver")
            }
            row(symbol: Symbols.certificate, title: L("trust.ca.title"), detail: LocalTrust.caDetail(trust), ok: trust?.authority.trusted == true) {
                Button { confirmCa = true } label: { Label(L("trust.ca.action"), systemImage: Symbols.certificate) }
                    .disabled(trust?.authority.exists != true || store.busy != nil).accessibilityIdentifier("trust.ca")
            }
            if trust?.simulated == true {
                Text(L("trust.simulated")).font(.uiCaption).foregroundStyle(.secondary)
            }
        } header: {
            HStack {
                Text(L("trust.title"))
                Spacer()
                Button { Task { await store.refreshTrust() } } label: { Label(L("trust.recheck"), systemImage: Symbols.reload).labelStyle(.iconOnly) }
                    .buttonStyle(.borderless).help(L("trust.recheck")).accessibilityIdentifier("trust.refresh")
            }
        } footer: {
            SettingsFooter(L("trust.footer"))
        }
        .task { await store.refreshTrust() }
        .trustConfirmations(store: store, resolver: $confirmResolver, ca: $confirmCa)
    }

    private func row<Action: View>(symbol: String, title: String, detail: String, ok: Bool, @ViewBuilder action: () -> Action) -> some View {
        LabeledContent {
            if ok {
                Label(L("setup.ready"), systemImage: Symbols.success).foregroundStyle(Brand.success)
            } else {
                action()
            }
        } label: {
            Label {
                Text(title)
                Text(detail)
            } icon: {
                IconTile(symbol: symbol, size: 22)
            }
        }
    }
}

/// Caddy and PHP-FPM: state, version, the ports the projects are served on, restart and logs.
private struct WebServerSection: View {
    @Bindable var store: StackStore
    @State private var logProcess: String?
    @State private var showVersions = false
    var caddy: ProcessPhase { store.phase("stack.caddy") }
    var version: String? {
        let installed = (store.installedTools["caddy"] ?? []).map(\.version)
        if let chosen = store.globalVersion("caddy"), installed.contains(chosen) { return chosen }
        return installed.max { $0.compare($1, options: .numeric) == .orderedAscending }
    }
    var body: some View {
        Section {
            LabeledContent {
                HStack(spacing: 8) {
                    Text(version ?? L("panel.notInstalled")).monospacedDigit().foregroundStyle(.secondary)
                    Button { showVersions = true } label: { Label(L("settings.web.versions"), systemImage: Symbols.versions) }
                        .accessibilityIdentifier("settings.web.versions")
                }
            } label: {
                Label { Text(L("version")) } icon: { TechLogo(tech: .of("web"), size: 22) }
            }
            let entries = store.stackProcesses.filter { $0.id == "stack.caddy" || $0.id.hasPrefix("stack.php-") }
            if entries.isEmpty {
                Text(L("services.none")).foregroundStyle(.secondary)
            }
            ForEach(entries) { entry in
                WebProcessRow(store: store, entry: entry) { logProcess = $0 }
            }
            ForEach(["http", "https", "https-udp", "dns"], id: \.self) { name in
                ListenerRow(store: store, name: name)
            }
            HStack {
                Button { Task { await store.processAction("stack.caddy", "restart") } } label: { Label(L("settings.web.restart"), systemImage: Symbols.reload) }
                    .disabled(!store.daemonRunning || version == nil || store.busy != nil)
                    .accessibilityIdentifier("settings.web.restart")
                Button { logProcess = "stack.caddy" } label: { Label(L("settings.web.logs"), systemImage: Symbols.logs) }
                    .disabled(version == nil)
                    .accessibilityIdentifier("settings.web.logs")
                Spacer()
            }
        } header: {
            HStack {
                Text(L("panel.web"))
                Spacer()
                Chip(text: L("state.\(caddy.rawValue)"), symbol: caddy.symbol, tint: caddy.color)
            }
        } footer: {
            SettingsFooter(L("services.portsHelp"))
        }
        .showsLogs($logProcess, store: store)
        .sheet(isPresented: $showVersions) { WebVersionsSheet(store: store).themedSheet() }
    }
}

/// Caddy or one PHP-FPM: its state, its log at the end of the row and its switch.
private struct WebProcessRow: View {
    let store: StackStore
    let entry: ProcessEntry
    let showLog: (String) -> Void
    var body: some View {
        let phase = ProcessPhase(entry.status.state)
        let caddy = entry.id == "stack.caddy"
        let title = caddy ? "Caddy" : "PHP-FPM " + entry.id.dropFirst("stack.php-".count).replacingOccurrences(of: "-", with: ".")
        LabeledContent {
            HStack(spacing: 10) {
                Button { showLog(entry.id) } label: { Label(L("process.logs"), systemImage: Symbols.logs).labelStyle(.iconOnly) }
                    .buttonStyle(.borderless).help(L("process.logs")).accessibilityIdentifier("settings.web.log.\(entry.id)")
                Toggle(title, isOn: Binding(get: { phase == .running || phase == .starting }, set: { on in Task { await store.processAction(entry.id, on ? "start" : "stop") } }))
                    .toggleStyle(.switch).labelsHidden().accessibilityIdentifier("web.toggle.\(entry.id)")
            }
        } label: {
            Label {
                Text(title)
                Text(L("state.\(phase.rawValue)")).foregroundStyle(phase.color)
            } icon: {
                TechLogo(tech: .of(caddy ? "web" : "php"), size: 22)
            }
        }
    }
}

/// A port the projects are served on. macOS handing it over is the normal case and is said once
/// in the footnote; only a problem gets a chip.
private struct ListenerRow: View {
    let store: StackStore
    let name: String
    var body: some View {
        let listener = store.status?.listeners[name]
        let ok = listener.map { $0.mode != "unavailable" } ?? false
        LabeledContent {
            HStack(spacing: 6) {
                if let listener {
                    Text("127.0.0.1:\(listener.port)").monospacedDigit().foregroundStyle(.secondary)
                }
                // Without the supervisor there is nothing to say per port: the section's state says it once.
                if listener == nil {
                    Text(verbatim: "—").foregroundStyle(.secondary)
                } else if !ok || listener?.mode != "launchd" {
                    Chip(text: listener.map(modeText) ?? "", symbol: ok ? Symbols.success : Symbols.warning, tint: ok ? Brand.info : Brand.warning)
                } else {
                    Image(systemName: Symbols.success).foregroundStyle(Brand.success).help(L("mode.launchd"))
                }
            }
        } label: {
            Text(L("listener.\(name)"))
        }
    }
    func modeText(_ listener: ListenerStatus) -> String {
        switch listener.mode {
        case "launchd": L("mode.launchd")
        case "bound": L("mode.bound")
        default: listener.owner.map { String(format: L("mode.busy"), $0) } ?? L("mode.unavailable")
        }
    }
}

/// Caddy's versions, the same list as every service's, in a sheet of Red.
private struct WebVersionsSheet: View {
    @Bindable var store: StackStore
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ScrollView { VersionsSection(store: store, info: DownloadInfo.of("caddy")).padding(2) }
            HStack {
                Spacer()
                Button(L("common.done")) { dismiss() }.keyboardShortcut(.defaultAction).accessibilityIdentifier("settings.web.versionsDone")
            }
        }
        .padding(20)
        .frame(minWidth: 520, idealWidth: 600, minHeight: 360, idealHeight: 520)
    }
}

/// The watched folders, each one removable; new projects in them are offered, never added alone.
private struct WatchedFoldersSection: View {
    @Bindable var store: StackStore
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Section {
            if store.watchedFolders.isEmpty {
                Text(L("watch.none")).foregroundStyle(.secondary)
            }
            // The projects folder of Ajustes › Avanzado is offered first; watching it makes it.
            if !store.watchedFolders.contains(where: { $0.path == Folder.projects }) {
                LabeledContent {
                    Button { Task { await store.setWatched(Folder.ensureProjects().path, true) } } label: { Label(L("watch.projectsFolder"), systemImage: Symbols.newFolder) }
                        .accessibilityIdentifier("watch.projectsFolder")
                } label: {
                    Label {
                        Text(L("settings.projectsFolder"))
                        Text(Folder.projects.replacingOccurrences(of: NSHomeDirectory(), with: "~")).lineLimit(1).truncationMode(.middle).help(Folder.projects)
                    } icon: {
                        IconTile(symbol: Symbols.project, size: 22)
                    }
                }
            }
            ForEach(Array(store.watchedFolders.enumerated()), id: \.element.id) { index, folder in
                LabeledContent {
                    HStack(spacing: 8) {
                        if let pending = store.watchedPending.first(where: { $0.root == folder.path }) {
                            Button { openWindow(id: "main"); store.reviewWatched(pending) } label: { Label(String(format: L("watch.reviewCount"), pending.projects.count), systemImage: Symbols.importFolder) }
                                .accessibilityIdentifier("watch.review.\(index)")
                        }
                        Button { Task { await store.setWatched(folder.path, false) } } label: { Label(L("watch.stop"), systemImage: Symbols.remove).labelStyle(.iconOnly) }
                            .buttonStyle(.borderless).help(L("watch.stop")).accessibilityIdentifier("watch.stop.\(index)")
                    }
                } label: {
                    Label {
                        Text(URL(fileURLWithPath: folder.path).lastPathComponent)
                        Text(folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).lineLimit(1).truncationMode(.middle).help(folder.path)
                    } icon: {
                        IconTile(symbol: Symbols.folder, size: 22)
                    }
                }
            }
        } header: {
            Text(L("watch.title"))
        } footer: {
            SettingsFooter(L("watch.footer"))
        }
        .task { await store.refreshWatched() }
    }
}
