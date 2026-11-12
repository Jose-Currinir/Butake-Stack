import AppKit
import SwiftUI

/// Menu bar icon: the Butake mark as a template image, tinted by the system like other menu extras.
enum MenuBarIcon {
    static let image: NSImage = {
        let image = Bundle.module.image(forResource: "MenuBarIcon") ?? NSImage(systemSymbolName: "server.rack", accessibilityDescription: nil)!
        image.isTemplate = true
        image.size = NSSize(width: 18, height: 18)
        image.accessibilityDescription = "Butake Stack"
        return image
    }()
}

/// The app's home: engines switch on and off right here, sites open with one click.
struct MenuPanel: View {
    @Bindable var store: StackStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().padding(.vertical, 6)
            if !store.projects.isEmpty {
                PanelSection(title: L("route.sites")) {
                    ForEach(store.projects) { project in SiteMenuRow(store: store, project: project) }
                }
            }
            Divider().padding(.vertical, 6)
            PanelSection(title: L("panel.engines")) {
                ForEach(Route.allEngines.filter { store.engineVersion($0) != nil }, id: \.self) { name in
                    EngineRow(store: store, name: name, title: Tech.of(name).title, port: store.enginePort(name))
                }
                ForEach(store.stackProcesses.filter { $0.id.hasPrefix("stack.php-") || $0.id == "stack.caddy" }) { entry in
                    PanelServiceRow(store: store, entry: entry)
                }
                DnsRow(store: store)
            }
            Divider().padding(.vertical, 6)
            HStack(spacing: 8) {
                Button { open(.home) } label: { Label(L("menu.open"), systemImage: "macwindow") }
                    .accessibilityIdentifier("panel.open")
                Spacer()
                Button { Task { await store.reloadStack() } } label: { Image(systemName: "arrow.clockwise") }
                    .help(L("menu.restartAll")).disabled(!store.daemonRunning).accessibilityIdentifier("panel.restart")
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                    .help(L("menu.quitHelp")).accessibilityIdentifier("panel.quit")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 12).padding(.bottom, 10).padding(.top, 2)
        }
        .frame(width: 330)
        .tint(Brand.accent)
        .task { store.startPolling(); await store.refreshRuntimes() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 10) {
            BrandMark(size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(L("app.name")).font(.headline)
                HStack(spacing: 5) {
                    Circle().fill(store.health).frame(width: 7, height: 7)
                    Text(store.daemonRunning ? (store.agent?.loaded == true ? L("panel.serving") : L("daemon.running")) : L("daemon.stopped"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if !store.daemonRunning {
                Button(L("daemon.start")) { Task { await store.startDaemon() } }.controlSize(.small)
            }
        }
        if !store.setupComplete {
            Button {
                open(.home)
                store.showSetup = true
            } label: {
                Label(L("setup.pending"), systemImage: "checklist").font(.caption.weight(.semibold)).frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderless).foregroundStyle(Brand.warning).accessibilityIdentifier("panel.setup")
        }
        // A newer verified release: one click opens the window with the update sheet.
        if UpdateService.shared.updateAvailable, let latest = UpdateService.shared.latest {
            Button {
                open(.home)
                UpdateService.shared.showingSheet = true
            } label: {
                Label(String(format: L("updateAvailableShort"), latest.version), systemImage: "arrow.down.circle.fill")
                    .font(.caption.weight(.semibold)).frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderless).foregroundStyle(Brand.accent).accessibilityIdentifier("panel.update")
        }
        }
        .padding(.horizontal, 12).padding(.top, 12)
    }

    func open(_ route: Route) {
        store.route = route
        MenuPanelWindow.close()
        openWindow(id: "main")
        NSApp.activate()
    }
}

private struct PanelSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 12).padding(.bottom, 2)
            content
        }
    }
}

private struct PanelRow<Trailing: View>: View {
    let icon: String
    let title: String
    let detail: String
    let phase: ProcessPhase?
    var tech: Tech?
    @ViewBuilder let trailing: Trailing
    var body: some View {
        HStack(spacing: 10) {
            if let tech { TechLogo(tech: tech, size: 26) } else { IconTile(symbol: icon, size: 26) }
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            if let phase { StateDot(phase: phase) }
            trailing
        }
        .padding(.horizontal, 12).padding(.vertical, 3)
        .contentShape(Rectangle())
    }
}

private struct EngineRow: View {
    @Bindable var store: StackStore
    let name: String
    let title: String
    let port: Int?
    var body: some View {
        let version = store.engineVersion(name)
        let phase = store.engineEnabled(name) ? store.phase("stack.\(name)") : nil
        PanelRow(
            icon: name == "mysql" ? "cylinder.split.1x2" : "bolt.horizontal.fill",
            title: title,
            detail: version.map { "\($0) · \(L("panel.port")) \(port.map(String.init) ?? "—")" } ?? L("panel.notInstalled"),
            phase: phase,
            tech: .of(name)
        ) {
            if version == nil {
                Button(L("runtimes.install")) { store.route = .service(Route.category(of: name)); openMain() }.controlSize(.small)
            } else {
                Toggle("", isOn: Binding(get: { store.engineEnabled(name) }, set: { on in Task { await store.setEngine(name, enabled: on) } }))
                    .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                    .accessibilityIdentifier("panel.engine.\(name)")
                    .accessibilityLabel(title)
            }
        }
    }
    @Environment(\.openWindow) private var openWindow
    func openMain() { MenuPanelWindow.close(); openWindow(id: "main"); NSApp.activate() }
}

private struct PanelServiceRow: View {
    @Bindable var store: StackStore
    let entry: ProcessEntry
    var body: some View {
        let phase = ProcessPhase(entry.status.state)
        let isCaddy = entry.id == "stack.caddy"
        let ports = [store.status?.listeners["http"]?.port, store.status?.listeners["https"]?.port].compactMap { $0 }.map(String.init).joined(separator: "/")
        PanelRow(
            icon: isCaddy ? "globe" : "chevron.left.forwardslash.chevron.right",
            title: isCaddy ? L("panel.web") : "PHP-FPM " + entry.id.dropFirst("stack.php-".count).replacingOccurrences(of: "-", with: "."),
            detail: isCaddy ? "Caddy · \(L("panel.port")) \(ports)" : L("state.\(phase.rawValue)"),
            phase: phase,
            tech: .of(isCaddy ? "web" : "php")
        ) {
            Toggle("", isOn: Binding(get: { phase == .running || phase == .starting }, set: { on in Task { await store.processAction(entry.id, on ? "start" : "stop") } }))
                .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                .accessibilityIdentifier("panel.service.\(entry.id)")
        }
    }
}

private struct DnsRow: View {
    let store: StackStore
    var body: some View {
        if let dns = store.status?.listeners["dns"] {
            PanelRow(icon: "point.3.connected.trianglepath.dotted", title: "DNS .test", detail: "\(L("panel.port")) \(dns.port)", phase: dns.mode == "unavailable" ? .crashed : .running, tech: .of("dns")) { EmptyView() }
        }
    }
}

private struct SiteMenuRow: View {
    let store: StackStore
    let project: Project
    var detail: String {
        let branch = store.git[project.id].map { $0.branch.isEmpty ? L("git.detached") : $0.branch }
        return [project.php.map { "PHP \($0)" } ?? L("kind.\(project.kind)"), branch].compactMap { $0 }.joined(separator: " · ")
    }
    var body: some View {
        Button {
            MenuPanelWindow.close()
            if let url = project.url { NSWorkspace.shared.open(url) }
        } label: {
            PanelRow(icon: "safari", title: project.title, detail: detail, phase: store.sitePhase(project), tech: project.tech) {
                Toggle("", isOn: Binding(get: { project.enabled }, set: { on in Task { await store.setSite(project, enabled: on) } }))
                    .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                    .accessibilityLabel(String(format: L("site.powerFor"), project.title))
            }
        }
        .buttonStyle(.plain)
        .contextMenu { SiteMenuItems(store: store, project: project) }
        .accessibilityIdentifier("panel.site.\(project.id)")
    }
}

/// The menu bar panel is a system-managed window; it must close when an action takes the user elsewhere.
@MainActor enum MenuPanelWindow {
    static func close() {
        // The only window of this app floating above normal level is the menu bar panel.
        for window in NSApp.windows where window.isVisible && window.level.rawValue > NSWindow.Level.normal.rawValue {
            window.orderOut(nil)
        }
    }
}
