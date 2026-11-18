import AppKit
import SwiftUI

/// Menu bar icon: the Butake mark as a template image, tinted by the system like other menu extras.
/// While Stack is not «Todo en marcha» a dot sits at its corner. It is part of the template (the
/// system tints a template, so color cannot carry it): a solid dot with a clear ring around it, read
/// as a shape in light, dark and tinted menu bars.
enum MenuBarIcon {
    /// The dot shows for every state but running (the state the store already computes).
    static func showsDot(for state: StackState) -> Bool { state != .running }

    /// What VoiceOver says: the app and, with the dot, the state.
    static func description(for state: StackState) -> String {
        showsDot(for: state) ? "\(L("app.name")): \(state.title)" : L("app.name")
    }

    static let image: NSImage = base(description: L("app.name"))
    private static let dotted: NSImage = {
        let size = NSSize(width: 18, height: 18)
        let source = base(description: nil)
        let image = NSImage(size: size, flipped: false) { rect in
            source.draw(in: rect)
            let dot = NSRect(x: rect.maxX - 7.5, y: rect.maxY - 7.5, width: 6.5, height: 6.5)
            // A clear ring around the dot keeps it apart from the mark.
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(ovalIn: dot.insetBy(dx: -1.5, dy: -1.5)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            NSColor.black.setFill()
            NSBezierPath(ovalIn: dot).fill()
            return true
        }
        image.isTemplate = true
        return image
    }()

    static func image(for state: StackState) -> NSImage {
        let image = showsDot(for: state) ? dotted : Self.image
        // The description is set on a copy: the cached image is shared by every state.
        let copy = image.copy() as? NSImage ?? image
        copy.isTemplate = true
        copy.accessibilityDescription = description(for: state)
        return copy
    }

    private static func base(description: String?) -> NSImage {
        let image = Bundle.module.image(forResource: "MenuBarIcon") ?? NSImage(systemSymbolName: "server.rack", accessibilityDescription: nil)!
        image.isTemplate = true
        image.size = NSSize(width: 18, height: 18)
        image.accessibilityDescription = description
        return image
    }
}

/// The menu bar panel: the projects (favorites first; switch, open), the stack's services in a
/// compact grid and the repositories with something pending. Height is bounded, so the panel never grows past the screen
/// and lands under the pointer (a row that ended up there used to catch the opening click).
struct MenuPanel: View {
    @Bindable var store: StackStore
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    @State private var filter = ""

    /// Rows of the project list on screen; the rest scroll.
    static let visibleProjects = 5
    /// Favorites first, then the rest, filtered by what is typed.
    var listed: [Project] {
        let query = filter.trimmingCharacters(in: .whitespaces).lowercased()
        let matching = query.isEmpty ? store.projects : store.projects.filter { $0.title.lowercased().contains(query) || ($0.domains.first ?? "").contains(query) }
        return matching.filter { store.isFavorite($0.id) } + matching.filter { !store.isFavorite($0.id) }
    }

    var panelServices: [String] { Route.allEngines.filter { store.engineVersion($0) != nil } }
    var panelProcesses: [ProcessEntry] { store.stackProcesses.filter { $0.id.hasPrefix("stack.php-") || $0.id == "stack.caddy" } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            PanelDivider()
            // One list of a fixed height, favorites first: the panel never changes size while it is
            // open (a menu bar window that grows does not shrink back).
            if !store.projects.isEmpty {
                PanelSection(title: L("panel.projects"), trailing: "\(store.projects.count)") {
                    if store.projects.count > Self.visibleProjects {
                        TextField(L("favorites.search"), text: $filter).textFieldStyle(.roundedBorder).controlSize(.small)
                            .padding(.horizontal, 12).accessibilityIdentifier("panel.search")
                    }
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(listed) { ProjectMenuRow(store: store, project: $0, favorite: store.isFavorite($0.id)) }
                        }
                    }
                    .frame(height: CGFloat(min(store.projects.count, Self.visibleProjects)) * ProjectMenuRow.height)
                    .accessibilityIdentifier("panel.allSites")
                }
            }
            if !panelServices.isEmpty || !panelProcesses.isEmpty {
                PanelDivider()
                PanelSection(title: L("panel.engines"), trailing: nil) {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 4), GridItem(.flexible(), spacing: 4)], spacing: 4) {
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
            // The state of the local domains, said in words.
            if let dns = store.status?.listeners["dns"] {
                let unavailable = dns.mode == "unavailable"
                Label(String(format: L(unavailable ? "panel.dnsOff" : "panel.dnsOn"), store.config?.tld.first ?? "test"),
                      systemImage: unavailable ? Symbols.warning : Symbols.success)
                    .font(.caption2).foregroundStyle(unavailable ? Brand.warningText : .secondary)
                    .help(L("panel.dnsHelp")).padding(.horizontal, 14).padding(.bottom, 2)
                    .accessibilityIdentifier("panel.dns")
            }
            // One line, like the end of a menu: the window, the app's settings and quitting it.
            HStack(spacing: 2) {
                Button { open() } label: { PanelMenuRow(title: L("menu.open")) }
                    .accessibilityIdentifier("panel.open")
                Spacer(minLength: 4)
                SettingsLink { PanelMenuRow(title: L("menu.settings")) }
                    .accessibilityIdentifier("panel.settings")
                Button { NSApp.terminate(nil) } label: { PanelMenuRow(title: L("panel.quit"), shortcut: "⌘Q") }
                    .keyboardShortcut("q").help(L("menu.quitHelp")).accessibilityIdentifier("panel.quit")
            }
            .buttonStyle(HighlightButtonStyle(radius: Radius.small))
            .padding(.horizontal, 6).padding(.bottom, 6)
        }
        .frame(width: 320)
        .themedTint()
        .serviceStopConfirmation(store, on: .panel)
        // A failed action says so here, over the footer; it never opens the window.
        .overlay(alignment: .bottom) {
            if let failure = store.panelFailure {
                PanelFailureBanner(failure: failure, open: open) { store.panelFailure = nil }
                    .padding(.horizontal, 8).padding(.bottom, 36)
            }
        }
        .onDisappear { store.panelFailure = nil }
        .task { await store.bootstrap() }
    }

    /// The app and its state: the same indicator as the window's status bar, with the same «Estado».
    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                BrandMark(size: 18)
                Text(L("app.name")).font(.callout.weight(.semibold))
                Spacer()
                StackStateIndicator(store: store).font(.caption)
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
        .padding(.leading, 14).padding(.trailing, 8).padding(.top, 9).padding(.bottom, 0)
    }

    /// The window opens on the page it showed last.
    func open() {
        dismiss()
        openWindow(id: "main")
        NSApp.activate()
    }
}

private struct PanelDivider: View {
    var body: some View { Divider().padding(.horizontal, 12).padding(.vertical, 4) }
}

private struct PanelSection<Content: View>: View {
    let title: String
    let trailing: String?
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
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
        HStack(spacing: 5) {
            TechLogo(tech: tech, size: 16)
            // One line: the dot says whether it runs; the port is in the tooltip.
            if let phase { StatusDot(color: phase.color, symbol: phase.markSymbol, label: L("state.\(phase.rawValue)"), size: 5) }
            Text(title).font(.caption).lineLimit(1).minimumScaleFactor(0.75)
            Spacer(minLength: 0)
            Toggle("", isOn: isOn).toggleStyle(.switch).controlSize(.mini).labelsHidden().accessibilityIdentifier(identifier)
                .accessibilityLabel(title)
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7, style: .continuous))  // radius 7: outside the Radius scale, kept as it was
        .help(detail.isEmpty ? title : "\(title) · \(detail)")
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
                        isOn: Binding(get: { on }, set: { value in Task { await store.setEngine(name, enabled: value, from: .panel) } }),
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
                        isOn: Binding(get: { phase == .running || phase == .starting }, set: { on in Task { await store.processAction(entry.id, on ? "start" : "stop", from: .panel) } }),
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
    /// One line per project.
    static let height: CGFloat = 29
    var detail: String {
        let branch = store.git[project.id].map { $0.branch.isEmpty ? L("git.detached") : $0.branch }
        return [project.domains.first, branch].compactMap { $0 }.joined(separator: " · ")
    }
    var body: some View {
        HStack(spacing: 7) {
            TechLogo(tech: project.tech, size: 18)
            Text(project.title).font(.callout).lineLimit(1).layoutPriority(1)
            Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            // Always visible: a favorite in the secondary tone, the rest fainter.
            Button { store.toggleFavorite(project.id) } label: {
                Label(String(format: L(favorite ? "favorites.removeFor" : "favorites.addFor"), project.title), systemImage: Symbols.favorite).labelStyle(.iconOnly)
                    .foregroundStyle(Color(nsColor: favorite ? .secondaryLabelColor : .tertiaryLabelColor))
            }
            .buttonStyle(.borderless)
            .help(String(format: L(favorite ? "favorites.removeFor" : "favorites.addFor"), project.title))
            .accessibilityIdentifier("panel.favorite.\(project.id)")
            if project.enabled, let url = project.url {
                Button { dismiss(); NSWorkspace.shared.open(url) } label: { Label(String(format: L("favorites.openSiteFor"), project.title), systemImage: Symbols.openInBrowser).labelStyle(.iconOnly) }
                    .buttonStyle(.borderless).help(String(format: L("favorites.openSiteFor"), project.title))
                    .accessibilityIdentifier("panel.openSite.\(project.id)")
            }
            // A project without a server has no switch.
            if project.isServed {
                Toggle("", isOn: Binding(get: { project.enabled }, set: { on in Task { await store.setSite(project, enabled: on, from: .panel) } }))
                    .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                    .disabled(project.isMissing)
                    .help(project.isMissing ? L("missing.title") : String(format: L("site.powerFor"), project.title))
                    .accessibilityLabel(String(format: L("site.powerFor"), project.title))
                    .accessibilityIdentifier("panel.site.\(project.id)")
            }
        }
        .padding(.horizontal, 8).frame(height: Self.height)
        .help("\(project.title) · \(detail)")
        .background(hover ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
        .padding(.horizontal, 4)
        .onHover { hover = $0 }
        .contextMenu { ProjectMenuItems(store: store, project: project) }
    }
}

/// A row at the end of the panel that reads like a menu item.
private struct PanelMenuRow: View {
    let title: String
    /// The key that does the same, shown after the text like in a menu.
    var shortcut: String?
    var body: some View {
        HStack(spacing: 5) {
            Text(title).font(.callout)
            if let shortcut { Text(shortcut).font(.caption).foregroundStyle(.secondary) }
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
    }
}

/// What failed in the panel, with its cause and the buttons that help; «Abrir Registros» opens the window.
private struct PanelFailureBanner: View {
    let failure: ActionFailure
    let open: () -> Void
    let dismiss: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(failure.title, systemImage: Symbols.warning).font(.callout.weight(.semibold)).foregroundStyle(Brand.dangerText)
            Text(failure.message).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                if let retry = failure.retry {
                    Button(L("error.retry")) { dismiss(); Task { await retry() } }.accessibilityIdentifier("panel.error.retry")
                }
                if failure.offersLogs {
                    Button(L("error.openLogs")) { dismiss(); open(); StackStore.shared.route = .tool("logs") }.accessibilityIdentifier("panel.error.logs")
                }
                Spacer()
                Button(L("common.close"), action: dismiss).accessibilityIdentifier("panel.error.close")
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.row, style: .continuous).strokeBorder(Brand.danger.opacity(0.5)))
        .accessibilityElement(children: .contain).accessibilityIdentifier("panel.error")
    }
}
