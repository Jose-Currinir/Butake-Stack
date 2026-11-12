import AppKit
import SwiftUI

/// Header card of a page: logo, title, subtitle and the page's main control.
struct HeaderCard<Trailing: View>: View {
    let tech: Tech
    let title: String
    let subtitle: String
    @ViewBuilder var trailing: Trailing
    var body: some View {
        PageHeader(tech: tech, title: title, subtitle: subtitle) { trailing }
            .padding(.horizontal, 18).padding(.vertical, 12)
            .glassCard(radius: 18)
    }
}

/// Columns that fit the window: one on a narrow window, two side by side on a wide one.
let pageColumns = [GridItem(.adaptive(minimum: 440), spacing: 18, alignment: .top)]

/// A service type (databases, cache and queues…): every engine of that kind, each with its state,
/// connection, sites that use it and versions.
struct CategoryPage: View {
    @Bindable var store: StackStore
    let category: String
    var body: some View {
        PageScroll {
            HeaderCard(tech: .of(category), title: Tech.of(category).title, subtitle: L("category.\(category).summary")) { EmptyView() }
            if category == "broadcasting" { ReverbBlock(store: store) }
            LazyVGrid(columns: pageColumns, alignment: .leading, spacing: 22) {
                ForEach(Route.engines(in: category), id: \.self) { name in EngineBlock(store: store, name: name) }
            }
            let unavailable = Route.unavailable(in: category)
            if !unavailable.isEmpty {
                CardBlock(title: L("category.unavailable"), symbol: "exclamationmark.circle") {
                    ForEach(unavailable, id: \.0) { name, reason in
                        HStack(alignment: .top, spacing: 10) {
                            TechLogo(tech: .of(name.lowercased()), size: 26)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(name)
                                Text(reason).font(.uiCaption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
        }
    }
}

/// One engine inside its category page: state and switch, connection, sites and versions.
private struct EngineBlock: View {
    @Bindable var store: StackStore
    let name: String
    @State private var showLog = false
    var tech: Tech { .of(name) }
    var port: Int? { store.enginePort(name) }
    var body: some View {
        let version = store.engineVersion(name)
        let enabled = store.engineEnabled(name)
        let phase = enabled ? store.phase("stack.\(name)") : .stopped
        let entry = store.process("stack.\(name)")
        VStack(alignment: .leading, spacing: 14) {
            Card {
                HStack(spacing: 12) {
                    TechLogo(tech: tech, size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tech.title).font(.ui(size: 14, weight: .semibold))
                        Text(version ?? L("panel.notInstalled")).font(.uiCaption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if version != nil {
                        Chip(text: L("state.\(phase.rawValue)"), symbol: phase.symbol, tint: phase.color)
                        Button { showLog = true } label: { Image(systemName: "text.alignleft") }
                            .buttonStyle(.borderless).help(L("process.logs")).disabled(!enabled)
                        Toggle("", isOn: Binding(get: { enabled }, set: { on in Task { await store.setEngine(name, enabled: on) } }))
                            .toggleStyle(.switch).labelsHidden()
                            .accessibilityLabel(tech.title).accessibilityIdentifier("engine.toggle.\(name)")
                    }
                }
                if version == nil {
                    Divider()
                    Label(L("engine.notInstalledShort"), systemImage: "arrow.down.circle").font(.uiCallout).foregroundStyle(.secondary)
                } else {
                    Divider()
                    InfoRow(symbol: "network", title: L("engine.address"), value: "127.0.0.1:\(port.map(String.init) ?? "—")")
                    Divider()
                    InfoRow(symbol: "internaldrive", title: L("engine.data"), value: "data/\(name)")
                    if let entry, entry.status.restarts > 0 {
                        Divider()
                        InfoRow(symbol: "arrow.clockwise", title: L("engine.restarts"), value: "\(entry.status.restarts)")
                    }
                    ForEach(store.projects.filter { $0.services.contains(name) }) { project in
                        Divider()
                        SiteLinkRow(project: project, detail: project.tech.title) { store.openSite(project.id) }
                    }
                }
            }
            VersionsSection(store: store, info: ToolInfo.of(name))
        }
        .sheet(isPresented: $showLog) { LogSheet(store: store, id: "stack.\(name)").themedSheet() }
    }
}

/// Caddy and PHP-FPM, with the network the sites are served on.
struct WebPage: View {
    @Bindable var store: StackStore
    @State private var logProcess: String?
    var body: some View {
        let caddy = store.phase("stack.caddy")
        PageScroll {
            HeaderCard(tech: .of("web"), title: L("panel.web"), subtitle: L("engines.caddyDetail")) {
                Chip(text: L("state.\(caddy.rawValue)"), symbol: caddy.symbol, tint: caddy.color)
            }
            LazyVGrid(columns: pageColumns, alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 22) {
                    CardBlock(title: L("web.processes"), symbol: "gearshape.2") {
                        let entries = store.stackProcesses.filter { $0.id == "stack.caddy" || $0.id.hasPrefix("stack.php-") }
                        if entries.isEmpty { Text(L("services.none")).foregroundStyle(.secondary) }
                        ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                            if index > 0 { Divider() }
                            ServiceRow(store: store, entry: entry) { logProcess = $0 }
                        }
                    }
                    CardBlock(title: L("engines.network"), symbol: "network", footer: L("services.portsHelp")) {
                        ForEach(Array(["http", "https", "https-udp", "dns"].enumerated()), id: \.element) { index, name in
                            if index > 0 { Divider() }
                            ListenerRow(store: store, name: name)
                        }
                    }
                }
                VersionsSection(store: store, info: ToolInfo.of("caddy"))
            }
        }
        .sheet(item: Binding(get: { logProcess.map { LogTarget(id: $0) } }, set: { logProcess = $0?.id })) { LogSheet(store: store, id: $0.id).themedSheet() }
    }
}

/// Diagnosis of the stack itself: supervisor, session agent, ports, folders and start at login.
/// Sites and services have their own pages; nothing here repeats them.
struct GeneralPage: View {
    @Bindable var store: StackStore
    var body: some View {
        PageScroll {
            HStack(spacing: 14) {
                BrandMark(size: 52)
                VStack(alignment: .leading, spacing: 3) {
                    Text(L("app.name")).font(.ui(size: 20, weight: .semibold))
                    Text(store.daemonRunning ? L("general.running") : L("general.stopped")).font(.uiCallout).foregroundStyle(.secondary)
                }
                Spacer()
                Button { store.showSetup = true } label: { Label(L("setup.menu"), systemImage: "checklist") }
                    .accessibilityIdentifier("general.setup")
                if store.daemonRunning {
                    Button { Task { await store.reloadStack() } } label: { Label(L("menu.restartAll"), systemImage: "arrow.clockwise") }
                        .accessibilityIdentifier("general.reload")
                } else {
                    Button { Task { await store.startDaemon() } } label: { Label(L("daemon.start"), systemImage: "play.fill") }
                        .buttonStyle(.borderedProminent).accessibilityIdentifier("general.start")
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
            .glassCard(radius: 18)
            LazyVGrid(columns: pageColumns, alignment: .leading, spacing: 22) {
                CardBlock(title: L("general.diagnosis"), symbol: "stethoscope") {
                    StateLine(title: L("general.supervisor"), ok: store.daemonRunning, value: store.daemonRunning ? L("state.running") : L("state.stopped"))
                    Divider()
                    StateLine(title: L("general.agent"), ok: store.agent?.loaded == true, value: store.agent?.loaded == true ? L("status.agent") : L("status.manual"))
                    Divider()
                    InfoRow(symbol: "cylinder.split.1x2", title: L("general.engines"), value: "\(store.runningEngines) / \(store.engineCount)")
                    Divider()
                    InfoRow(symbol: "gearshape.2", title: L("general.siteProcesses"), value: "\(store.runningSiteProcesses)")
                    ForEach([("53", store.ports?.dns), ("80", store.ports?.http), ("443", store.ports?.https)], id: \.0) { port, owner in
                        Divider()
                        InfoRow(symbol: "point.3.connected.trianglepath.dotted", title: String(format: L("general.port"), port), value: owner ?? L("general.portFree"))
                    }
                }
                VStack(alignment: .leading, spacing: 22) {
                    ActivationSection(store: store)
                    CardBlock(title: L("general.folders"), symbol: "folder") {
                        HStack(spacing: 8) {
                            Button { Folder.open("data") } label: { Label(L("general.folder.data"), systemImage: "internaldrive") }
                            Button { Folder.open("logs") } label: { Label(L("general.folder.logs"), systemImage: "text.alignleft") }
                            Button { Folder.open("config") } label: { Label(L("general.folder.config"), systemImage: "slider.horizontal.3") }
                        }
                    }
                }
            }
        }
        .task { await store.refreshPorts() }
    }
}

private struct StateLine: View {
    let title: String
    let ok: Bool
    let value: String
    var body: some View {
        LabeledContent {
            Label(value, systemImage: ok ? "checkmark.circle.fill" : "exclamationmark.circle").foregroundStyle(ok ? Brand.success : Brand.warning)
        } label: { Text(title).foregroundStyle(.secondary) }
    }
}

struct ServiceRow: View {
    let store: StackStore
    let entry: ProcessEntry
    let showLog: (String) -> Void
    var body: some View {
        let phase = ProcessPhase(entry.status.state)
        let caddy = entry.id == "stack.caddy"
        HStack(spacing: 10) {
            TechLogo(tech: .of(caddy ? "web" : "php"), size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(caddy ? "Caddy" : "PHP-FPM " + entry.id.dropFirst("stack.php-".count).replacingOccurrences(of: "-", with: "."))
                Text(L("state.\(phase.rawValue)")).font(.uiCaption).foregroundStyle(phase.color)
            }
            Spacer()
            Button { showLog(entry.id) } label: { Image(systemName: "text.alignleft") }.buttonStyle(.borderless).help(L("process.logs"))
            Toggle("", isOn: Binding(get: { phase == .running || phase == .starting }, set: { on in Task { await store.processAction(entry.id, on ? "start" : "stop") } }))
                .toggleStyle(.switch).controlSize(.small).labelsHidden().accessibilityIdentifier("web.toggle.\(entry.id)")
        }
    }
}

/// A port the sites are served on. macOS handing it over is the normal case and is said once in
/// the footnote; only a problem gets a chip.
private struct ListenerRow: View {
    let store: StackStore
    let name: String
    var body: some View {
        let listener = store.status?.listeners[name]
        let ok = listener.map { $0.mode != "unavailable" } ?? false
        LabeledContent {
            HStack(spacing: 6) {
                Text(listener.map { "127.0.0.1:\($0.port)" } ?? "—").monospacedDigit().foregroundStyle(.secondary)
                if !ok || listener?.mode != "launchd" {
                    Chip(text: listener.map(modeText) ?? L("daemon.stopped"), symbol: ok ? "checkmark" : "exclamationmark.triangle.fill", tint: ok ? Brand.info : Brand.warning)
                } else {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Brand.success).help(L("mode.launchd"))
                }
            }
        } label: {
            Label(L("listener.\(name)"), systemImage: symbol).foregroundStyle(.secondary)
        }
    }
    var symbol: String {
        switch name {
        case "http": "network"
        case "https": "lock.fill"
        case "https-udp": "hare.fill"
        default: "point.3.connected.trianglepath.dotted"
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

/// Serving `.test` sites on 53/80/443 from login: the session agent gets those ports from macOS.
struct ActivationSection: View {
    @Bindable var store: StackStore
    @State private var confirmOn = false
    @State private var confirmOff = false
    var phpReady: Bool { store.phpRuntimes.contains(where: \.verified) }
    var caddyReady: Bool { !(store.installedTools["caddy"] ?? []).isEmpty }
    var busyPorts: [String] {
        guard let ports = store.ports else { return [] }
        let ours: Set<String> = ["launchd", "butake-stack", "caddy"]
        let pairs: [(String, String?)] = [("53", ports.dns), ("80", ports.http), ("443", ports.https)]
        return pairs.compactMap { port, owner in
            guard let owner, !ours.contains(owner) else { return nil }
            return "\(port): \(owner)"
        }
    }
    var active: Bool { store.agent?.loaded == true }
    var ready: Bool { phpReady && caddyReady && busyPorts.isEmpty && !store.projects.isEmpty }
    var body: some View {
        CardBlock(title: L("settings.login"), symbol: "person.badge.clock") {
            HStack(spacing: 12) {
                IconTile(symbol: active ? "checkmark.seal.fill" : "power", tint: active ? Brand.success : Brand.accent, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("activation.title")).font(.ui(size: 13, weight: .semibold))
                    Text(active ? L("activation.on") : L("activation.help")).font(.uiCaption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if active {
                    Button(L("activation.disable"), role: .destructive) { confirmOff = true }.accessibilityIdentifier("activation.disable")
                } else {
                    Button(L("activation.enable")) { confirmOn = true }.buttonStyle(.borderedProminent).disabled(!ready).accessibilityIdentifier("activation.enable")
                }
            }
            if !active {
                Divider()
                Requirement(ok: phpReady, text: L("activation.php")) { store.route = .language("php") }
                Requirement(ok: caddyReady, text: L("activation.caddy")) { store.route = .service("web") }
                Requirement(ok: !store.projects.isEmpty, text: L("activation.sites")) { store.chooseFolder() }
                Requirement(ok: busyPorts.isEmpty, text: busyPorts.isEmpty ? L("activation.ports") : String(format: L("activation.portsBusy"), busyPorts.joined(separator: ", ")), go: nil)
            }
        }
        .confirmationDialog(L("activation.confirmOn"), isPresented: $confirmOn) {
            Button(L("activation.enable")) { Task { await store.installAgent() } }
        } message: { Text(L("activation.confirmOnDetail")) }
        .confirmationDialog(L("activation.confirmOff"), isPresented: $confirmOff) {
            Button(L("activation.disable"), role: .destructive) { Task { await store.uninstallAgent() } }
        } message: { Text(L("activation.confirmOffDetail")) }
    }
}

private struct Requirement: View {
    let ok: Bool
    let text: String
    var go: (() -> Void)?
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle").foregroundStyle(ok ? Brand.success : .secondary)
            Text(text)
            Spacer()
            if !ok, let go { Button(L("activation.go"), action: go).controlSize(.small) }
        }
    }
}

/// Reverb runs inside each Laravel site; this lists and controls all of them in one place.
private struct ReverbBlock: View {
    @Bindable var store: StackStore
    @State private var logProcess: String?
    var body: some View {
        let items = store.projects.flatMap { project in
            project.processes.filter { $0.args.contains("reverb:start") }.map { (project, $0) }
        }
        CardBlock(title: "Reverb", symbol: "dot.radiowaves.left.and.right", footer: L("broadcasting.help")) {
            if items.isEmpty { Text(L("broadcasting.none")).foregroundStyle(.secondary) }
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                if index > 0 { Divider() }
                HStack(spacing: 10) {
                    TechLogo(tech: item.0.tech, size: 26)
                    ProcessRow(store: store, id: "\(item.0.id).\(item.1.name)", process: item.1) { logProcess = $0 }
                }
            }
        }
        .sheet(item: Binding(get: { logProcess.map { LogTarget(id: $0) } }, set: { logProcess = $0?.id })) { LogSheet(store: store, id: $0.id).themedSheet() }
    }
}
