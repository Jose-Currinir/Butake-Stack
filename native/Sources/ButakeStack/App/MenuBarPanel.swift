import AppKit
import SwiftUI

/// Menu bar icon: the Butake mark as a template image, tinted by the system like other menu extras.
enum MenuBarIcon {
    static let image: NSImage = {
        let image = Bundle.module.image(forResource: "MenuBarIcon") ?? NSImage(systemSymbolName: "server.rack", accessibilityDescription: nil)!
        image.isTemplate = true
        image.size = NSSize(width: 18, height: 18)
        image.accessibilityDescription = L("app.name")
        return image
    }()
}

/// The menu bar panel: favorite sites first (switch, open), the stack's services in a compact grid,
/// every other site one click away. Height is bounded, so the panel never grows past the screen
/// and lands under the pointer (a row that ended up there used to catch the opening click).
struct MenuPanel: View {
    @Bindable var store: StackStore
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    #if DEBUG
    @State private var showAll = QAHooks.menuPanelShowAll
    #else
    @State private var showAll = false
    #endif
    @State private var filter = ""

    var favorites: [Project] { store.projects.filter { store.isFavorite($0.id) } }
    var others: [Project] {
        let rest = store.projects.filter { !store.isFavorite($0.id) }
        let query = filter.trimmingCharacters(in: .whitespaces).lowercased()
        return query.isEmpty ? rest : rest.filter { $0.title.lowercased().contains(query) || ($0.domains.first ?? "").contains(query) }
    }

    var panelServices: [String] { Route.allEngines.filter { store.engineVersion($0) != nil } }
    var panelProcesses: [ProcessEntry] { store.stackProcesses.filter { $0.id.hasPrefix("stack.php-") || $0.id == "stack.caddy" } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            PanelDivider()
            PanelSection(title: L("favorites.title"), trailing: favorites.isEmpty ? nil : "\(favorites.count)") {
                if favorites.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Label(L("favorites.empty"), systemImage: Symbols.favorite).font(.callout.weight(.medium))
                        Text(L("favorites.emptyHelp")).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 6)
                } else {
                    ScrollView {
                        VStack(spacing: 2) { ForEach(favorites) { ProjectMenuRow(store: store, project: $0, favorite: true) } }
                    }
                    .frame(height: min(CGFloat(favorites.count) * 41, 288))
                }
            }
            if !store.projects.isEmpty {
                DisclosureGroup(isExpanded: $showAll) {
                    VStack(spacing: 4) {
                        TextField(L("favorites.search"), text: $filter).textFieldStyle(.roundedBorder).controlSize(.small)
                            .padding(.leading, -8).padding(.trailing, 12)
                        ScrollView {
                            VStack(spacing: 2) { ForEach(others) { ProjectMenuRow(store: store, project: $0, favorite: false) } }
                        }
                        .frame(height: min(CGFloat(max(others.count, 1)) * 41, 205))
                        .padding(.leading, -18)
                    }
                    .padding(.vertical, 4)
                } label: {
                    Text(String(format: L("favorites.allSites"), store.projects.count - favorites.count)).font(.callout).foregroundStyle(.secondary)
                }
                .padding(.leading, 14)
                .accessibilityIdentifier("panel.allSites")
            }
            if !panelServices.isEmpty || !panelProcesses.isEmpty {
                PanelDivider()
                PanelSection(title: L("panel.engines"), trailing: nil) {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                        ForEach(panelServices, id: \.self) { name in
                            EngineTile(store: store, name: name)
                        }
                        ForEach(panelProcesses) { entry in
                            ServiceTile(store: store, entry: entry)
                        }
                    }
                    .padding(.horizontal, 12)
                }
            }
            // The Git tool's repositories, only while it is on.
            if store.pluginEnabled("git") {
                PanelDivider()
                GitStatusSection { path in
                    open()
                    GitTool.shared.show(path)
                }
            }
            PanelDivider()
            HStack(spacing: 10) {
                Button { open() } label: { Label(L("menu.open"), systemImage: Symbols.openWindow) }
                    .accessibilityIdentifier("panel.open")
                Spacer()
                if let dns = store.status?.listeners["dns"] {
                    Label(".test", systemImage: dns.mode == "unavailable" ? Symbols.warning : Symbols.success)
                        .font(.caption).foregroundStyle(dns.mode == "unavailable" ? Brand.warning : .secondary)
                        .help(L("panel.dnsHelp"))
                }
            }
            .padding(.horizontal, 14).padding(.top, 4)
            PanelDivider()
            // Like the end of a menu: the app's settings and quitting it.
            VStack(spacing: 0) {
                SettingsLink { PanelMenuRow(title: L("menu.settings")) }
                    .accessibilityIdentifier("panel.settings")
                Button { NSApp.terminate(nil) } label: { PanelMenuRow(title: L("menu.quit")) }
                    .help(L("menu.quitHelp")).accessibilityIdentifier("panel.quit")
            }
            .buttonStyle(HighlightButtonStyle(radius: 6))
            .padding(.horizontal, 6).padding(.bottom, 6)
        }
        .frame(width: 340)
        .themedTint()
        .serviceStopConfirmation(store)
        .task { await store.bootstrap() }
    }

    /// The app and its state: the same indicator as the window's status bar, with the same «Estado».
    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                BrandMark(size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(L("app.name")).font(.headline)
                    StackStateIndicator(store: store).font(.caption).padding(.leading, -6)
                }
                Spacer()
            }
            // A newer verified release: one click opens the window with the update sheet.
            if UpdateService.shared.updateAvailable, let latest = UpdateService.shared.latest {
                Button {
                    open()
                    UpdateService.shared.showingSheet = true
                } label: {
                    Label(String(format: L("updateAvailableShort"), latest.version), systemImage: Symbols.update)
                }
                .buttonStyle(.bordered).controlSize(.small).accessibilityIdentifier("panel.update")
            }
        }
        .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 4)
    }

    /// The window opens on the page it showed last.
    func open() {
        dismiss()
        openWindow(id: "main")
        NSApp.activate()
    }
}

private struct PanelDivider: View {
    var body: some View { Divider().padding(.horizontal, 12).padding(.vertical, 6) }
}

private struct PanelSection<Content: View>: View {
    let title: String
    let trailing: String?
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if let trailing { Text(trailing).font(.caption2.monospacedDigit()).foregroundStyle(.tertiary) }
            }
            .padding(.horizontal, 14)
            content
        }
    }
}

/// A service as a small tile: logo, name, state and its switch.
private struct ServiceTileView: View {
    let tech: Tech
    let title: String
    let detail: String
    let phase: ProcessPhase?
    let isOn: Binding<Bool>
    let identifier: String
    var body: some View {
        HStack(spacing: 8) {
            TechLogo(tech: tech, size: 22)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.callout).lineLimit(1).minimumScaleFactor(0.8)
                HStack(spacing: 4) {
                    if let phase { Circle().fill(phase.color).frame(width: 5, height: 5) }
                    Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 2)
            Toggle("", isOn: isOn).toggleStyle(.switch).controlSize(.mini).labelsHidden().accessibilityIdentifier(identifier)
                .accessibilityLabel(title)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

private struct EngineTile: View {
    @Bindable var store: StackStore
    let name: String
    var body: some View {
        let on = store.engineEnabled(name)
        ServiceTileView(tech: .of(name), title: Tech.of(name).title,
                        detail: store.enginePort(name).map { ":\($0)" } ?? "",
                        phase: on ? store.phase("stack.\(name)") : nil,
                        isOn: Binding(get: { on }, set: { value in Task { await store.setEngine(name, enabled: value) } }),
                        identifier: "panel.engine.\(name)")
    }
}

private struct ServiceTile: View {
    @Bindable var store: StackStore
    let entry: ProcessEntry
    var body: some View {
        let phase = ProcessPhase(entry.status.state)
        let caddy = entry.id == "stack.caddy"
        ServiceTileView(tech: .of(caddy ? "web" : "php"),
                        title: caddy ? L("panel.web") : "PHP " + entry.id.dropFirst("stack.php-".count).replacingOccurrences(of: "-", with: "."),
                        detail: caddy ? "Caddy" : "FPM",
                        phase: phase,
                        isOn: Binding(get: { phase == .running || phase == .starting }, set: { on in Task { await store.processAction(entry.id, on ? "start" : "stop") } }),
                        identifier: "panel.service.\(entry.id)")
    }
}

/// A site: logo, name and detail, state, open in the browser and its switch. The row itself is
/// not a button: only the explicit controls act, so no stray click opens a site.
private struct ProjectMenuRow: View {
    let store: StackStore
    let project: Project
    let favorite: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var hover = false
    var detail: String {
        let branch = store.git[project.id].map { $0.branch.isEmpty ? L("git.detached") : $0.branch }
        return [project.domains.first, branch].compactMap { $0 }.joined(separator: " · ")
    }
    var body: some View {
        HStack(spacing: 10) {
            TechLogo(tech: project.tech, size: 26)
            VStack(alignment: .leading, spacing: 0) {
                Text(project.title).font(.callout.weight(.medium)).lineLimit(1)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 6)
            // Always visible: a favorite in the secondary tone, the rest fainter.
            Button { store.toggleFavorite(project.id) } label: {
                Label(favorite ? L("favorites.remove") : L("favorites.add"), systemImage: Symbols.favorite).labelStyle(.iconOnly)
                    .foregroundStyle(Color(nsColor: favorite ? .secondaryLabelColor : .tertiaryLabelColor))
            }
            .buttonStyle(.borderless)
            .help(favorite ? L("favorites.remove") : L("favorites.add"))
            .accessibilityIdentifier("panel.favorite.\(project.id)")
            if project.enabled, let url = project.url {
                Button { dismiss(); NSWorkspace.shared.open(url) } label: { Label(L("favorites.openSite"), systemImage: Symbols.openInBrowser).labelStyle(.iconOnly) }
                    .buttonStyle(.borderless).help(L("favorites.openSite"))
                    .accessibilityIdentifier("panel.openSite.\(project.id)")
            }
            // A project without a server has no switch.
            if project.isServed {
                Toggle("", isOn: Binding(get: { project.enabled }, set: { on in Task { await store.setSite(project, enabled: on) } }))
                    .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                    .disabled(project.isMissing)
                    .help(project.isMissing ? L("missing.title") : String(format: L("site.powerFor"), project.title))
                    .accessibilityLabel(String(format: L("site.powerFor"), project.title))
                    .accessibilityIdentifier("panel.site.\(project.id)")
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(hover ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.horizontal, 4)
        .onHover { hover = $0 }
        .contextMenu { ProjectMenuItems(store: store, project: project) }
    }
}

/// A row at the end of the panel that reads like a menu item.
private struct PanelMenuRow: View {
    let title: String
    var body: some View {
        Text(title).font(.body).padding(.horizontal, 8).padding(.vertical, 4)
    }
}
