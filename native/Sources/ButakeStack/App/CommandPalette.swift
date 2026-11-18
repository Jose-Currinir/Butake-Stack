import AppKit
import SwiftUI

/// Ir › Abrir rápidamente… (⇧⌘O, also ⌘K): one row per thing (page, site, project of several parts, engine, database connection, SSH host, action), grouped by kind. Return opens it,
/// ⌘Return opens a site in the browser, ⌥Return turns a site or engine on or off.
struct CommandPalette: View {
    @Bindable var store: StackStore
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selection = 0
    @FocusState private var focused: Bool
    /// Where the recents are kept (the tests give their own).
    var defaults = UserDefaults.standard

    struct Command: Identifiable {
        var id: String
        var section: String
        let title: String
        let detail: String
        let tech: Tech?
        var symbol: String = ""
        /// The chord of the same action in the menus, drawn on the right ("" = none).
        var shortcut = ""
        let run: @MainActor () -> Void
        /// ⌘Return.
        var secondary: (title: String, run: @MainActor () -> Void)?
        /// ⌥Return.
        var toggle: (title: String, run: @MainActor () -> Void)?
    }

    /// Start or stop a project from the palette.
    private func toggle(_ project: Project) -> (title: String, run: @MainActor () -> Void) {
        (project.enabled ? L("palette.stop") : L("palette.start"), { Task { await store.setSite(project, enabled: !project.enabled) } })
    }

    /// A page of the sidebar in the palette, grouped as the sidebar: Herramientas, Nube and
    /// Componentes (each category, with the row that holds it). The ids are the ones of before.
    struct Page {
        let id: String
        let section: String
        let route: Route
        let tech: Tech
        var detail = ""
    }
    static func pages(enabled: [String]) -> [Page] {
        var pages = SidebarLayout.toolRows(enabled: enabled).map { Page(id: $0, section: L("sidebar.tools"), route: .tool($0), tech: .of($0)) }
        pages += SidebarLayout.cloudRows(enabled: enabled).map { Page(id: $0, section: L("sidebar.cloud"), route: .tool($0), tech: .of($0)) }
        for component in Component.allCases {
            pages += component.categories.map { category in
                Page(id: component == .utilities ? "utilities.\(category)" : category, section: L("sidebar.components"),
                     route: component.route(category), tech: component.tech(of: category), detail: component.title)
            }
        }
        return pages
    }

    var commands: [Command] {
        var list: [Command] = []
        for project in store.projects {
            let phase = store.sitePhase(project)
            list.append(Command(
                id: "site.\(project.id)", section: L("route.sites"), title: project.title,
                detail: project.isMissing ? L("missing.title") : project.enabled ? L("state.\(phase.rawValue)") : L("site.off"), tech: project.tech,
                run: { store.openSite(project.id) },
                secondary: (L("palette.openBrowser"), { if let url = project.url { NSWorkspace.shared.open(url) } }),
                toggle: project.isMissing || !project.isServed ? nil : toggle(project)
            ))
        }
        // Projects of several parts open their own page, apart from their parts.
        for group in store.composites {
            list.append(Command(id: "composite.\(group.id)", section: L("route.sites"), title: group.name,
                                detail: L("palette.composite"), tech: nil, symbol: Symbols.compositeProject,
                                run: { store.openComposite(group.id) }))
        }
        // Switch a site's environment (Production only from the site page, with its confirmation).
        for project in store.projects {
            let state = store.envs[project.id]?.site
            for env in state?.environments ?? [] where env.kind != .production && state?.active != env.id {
                list.append(Command(id: "env.\(project.id).\(env.id)", section: L("palette.envs"), title: "\(project.title) → \(env.title)",
                                    detail: L("palette.envActivate"), tech: project.tech, run: { Task { await store.activateEnvironment(project, env) } }))
            }
        }
        for name in Route.allEngines where store.engineVersion(name) != nil {
            let on = store.engineEnabled(name)
            list.append(Command(
                id: "engine.\(name)", section: L("sidebar.services"), title: Tech.of(name).title,
                detail: on ? L("state.\(store.phase("stack.\(name)").rawValue)") : L("state.stopped"), tech: .of(name),
                run: { store.route = .service(Route.category(of: name)) },
                toggle: (on ? L("palette.stop") : L("palette.start"), { Task { await store.setEngine(name, enabled: !on) } })
            ))
        }
        // Saved database connections and SSH hosts: open them straight from ⌘K.
        if store.pluginEnabled("database-client") {
            let client = DatabaseClient.shared
            for connection in client.connections {
                list.append(Command(
                    id: "db.\(connection.id)", section: L("palette.connections"), title: connection.name,
                    detail: Tech.of(connection.kind).title, tech: .of(connection.kind),
                    run: {
                        store.route = .tool("database-client")
                        client.selection = DBSelection(connection: connection.id)
                        Task { await client.connect(connection) }
                    }
                ))
            }
        }
        if store.pluginEnabled("ssh-terminal") {
            let terminal = SSHTerminal.shared
            for host in terminal.hosts {
                list.append(Command(
                    id: "ssh.\(host.id)", section: L("palette.hosts"), title: host.name,
                    detail: ([host.user.isEmpty ? host.host : "\(host.user)@\(host.host)"] + host.tags).joined(separator: " · "),
                    tech: .of("ssh-terminal"),
                    run: { store.route = .tool("ssh-terminal"); Task { await terminal.open(host) } },
                    secondary: (L("palette.openFiles"), { store.route = .tool("ssh-terminal"); Task { await terminal.openFiles(host) } })
                ))
                for forward in host.forwards {
                    list.append(Command(
                        id: "fwd.\(host.id).\(forward.id)", section: L("palette.forwards"),
                        title: forward.name.isEmpty ? "\(host.name) :\(forward.listenPort)" : "\(host.name) → \(forward.name)",
                        detail: L("palette.forwardStart"), tech: nil, symbol: Symbols.forwards,
                        run: { Task { await terminal.start(host, forward) } }
                    ))
                }
            }
            list.append(Command(id: "terminal.local", section: L("palette.actions"), title: L("ssh.local.newConsole"), detail: "", tech: nil, symbol: Symbols.terminal,
                                run: { store.route = .tool("ssh-terminal"); SSHWorkspace.shared.openLocal() }))
        }
        list.append(Command(id: "page.home", section: L("palette.pages"), title: L("route.home"), detail: "", tech: nil, symbol: Symbols.home, shortcut: Shortcuts.home.display, run: { store.route = .home }))
        // Preferences are not pages: one row per tab of Ajustes.
        for tab in SettingsTab.allCases {
            list.append(Command(id: "settings.\(tab.rawValue)", section: L("palette.pages"), title: String(format: L("palette.settingsTab"), tab.title),
                                detail: L("palette.settings"), tech: nil, symbol: tab.symbol,
                                shortcut: tab == .general ? Shortcuts.settings.display : "", run: { SettingsRouter.shared.open(tab) }))
        }
        for page in Self.pages(enabled: store.enabledPlugins.map(\.id)) {
            list.append(Command(id: "page.\(page.id)", section: page.section, title: page.route.title, detail: page.detail, tech: page.tech,
                                run: { store.route = page.route }))
        }
        list.append(Command(id: "new", section: L("palette.actions"), title: L("menu.newProject"), detail: "", tech: .of("static"), shortcut: Shortcuts.newProject.display, run: { store.showNewProject = true }))
        list.append(Command(id: "add", section: L("palette.actions"), title: L("menu.addExisting"), detail: "", tech: nil, symbol: Symbols.folder, shortcut: Shortcuts.addExisting.display, run: { store.chooseFolder() }))
        list.append(Command(id: "import", section: L("palette.actions"), title: L("menu.importFolder"), detail: "", tech: nil, symbol: Symbols.importFolder,
                            run: { store.chooseFolder(scan: true) }))
        list.append(Command(id: "clone", section: L("palette.actions"), title: L("menu.cloneRepository"), detail: "", tech: nil, symbol: Symbols.gitClone,
                            run: { store.showClone = true }))
        list.append(Command(id: "restart", section: L("palette.actions"), title: L("menu.restartAll"), detail: "", tech: nil, symbol: Symbols.reload, run: { Task { await store.reloadStack() } }))
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            // The last rows used, first; the rest keeps its own sections below.
            let recent: [Command] = PaletteRecents.ids(defaults).compactMap { id in
                list.first { $0.id == id }.map { command in
                    var copy = command
                    copy.id = PaletteRecents.prefix + id
                    copy.section = L("palette.recent")
                    return copy
                }
            }
            return recent + list
        }
        return PaletteMatch.rank(list, query: query, title: \.title, detail: { $0.detail })
    }

    var body: some View {
        let items = commands
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: Symbols.search).font(.uiTitle3.weight(.semibold)).foregroundStyle(.secondary)
                TextField(L("palette.prompt"), text: $query)
                    .textFieldStyle(.plain).font(.uiTitle2).fontDesign(.rounded)
                    .focused($focused)
                    .onKeyPress(.return, phases: .down) { press in
                        run(items, modifiers: press.modifiers)
                        return .handled
                    }
                    .accessibilityIdentifier("palette.query")
            }
            .padding(12)
            .chromeGlass(interactive: true)
            .padding(8)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        // One identity per row (the command's id), header included, so filtering never reuses stale rows.
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, command in
                            VStack(alignment: .leading, spacing: 2) {
                                if index == 0 || items[index - 1].section != command.section {
                                    HStack {
                                        Text(command.section).font(.uiCaption.weight(.semibold)).foregroundStyle(.secondary)
                                        Spacer()
                                        if command.id.hasPrefix(PaletteRecents.prefix) {
                                            Button(L("palette.clearRecent")) { PaletteRecents.clear(defaults); selection = 0 }
                                                .buttonStyle(.borderless).font(.uiCaption).foregroundStyle(.secondary)
                                                .help(L("palette.clearRecentHelp")).accessibilityIdentifier("palette.clearRecent")
                                        }
                                    }
                                    .padding(.horizontal, 12).padding(.top, index == 0 ? 2 : 10).padding(.bottom, 2)
                                }
                                Button { selection = index; run(items, modifiers: []) } label: { row(command, selected: index == selection) }
                                    .buttonStyle(HighlightButtonStyle(radius: Radius.small))
                                    // The query field keeps the keyboard: arrows and Return move and open.
                                    .focusable(false)
                                    .accessibilityIdentifier("palette.command.\(command.id)")
                            }
                        }
                        if items.isEmpty {
                            Text(L("palette.empty")).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(30)
                        }
                    }
                    .padding(8)
                }
                .onChange(of: selection) { _, value in if items.indices.contains(value) { proxy.scrollTo(items[value].id) } }
            }
            .frame(height: 360)
            Divider()
            HStack(spacing: 14) {
                hint("↩", L("common.open"))
                hint("⌘↩", L("palette.openBrowser"))
                hint("⌥↩", L("palette.hint.toggle"))
                Spacer()
                hint("esc", L("common.close"))
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
        }
        .frame(width: 580)
        .onAppear { focused = true; if let text = PaletteQA.query { query = text } }
        .task {
            if store.pluginEnabled("database-client"), DatabaseClient.shared.connections.isEmpty { await DatabaseClient.shared.loadConnections() }
            if store.pluginEnabled("ssh-terminal"), SSHTerminal.shared.hosts.isEmpty { await SSHTerminal.shared.load() }
        }
        .onChange(of: query) { _, _ in selection = 0 }
        .onKeyPress(.downArrow) { selection = min(selection + 1, max(items.count - 1, 0)); return .handled }
        .onKeyPress(.upArrow) { selection = max(selection - 1, 0); return .handled }
        .onKeyPress(.escape) { dismiss(); return .handled }
    }

    private func row(_ command: Command, selected: Bool) -> some View {
        HStack(spacing: 12) {
            if let tech = command.tech { TechLogo(tech: tech, size: 24) } else { IconTile(symbol: command.symbol, size: 24) }
            titleText(command.title).font(.uiBody.weight(.medium))
            if !command.detail.isEmpty { Text(command.detail).font(.uiCaption).foregroundStyle(.secondary) }
            Spacer()
            if selected {
                if let toggle = command.toggle { Text("⌥↩ " + toggle.title).font(.uiCaption).foregroundStyle(.secondary) }
                if command.secondary != nil { Text("⌘↩").font(.uiCaption).foregroundStyle(.secondary) }
            }
            if !command.shortcut.isEmpty {
                Text(command.shortcut).font(.uiCaption).fontDesign(.rounded).foregroundStyle(.secondary)
                    .accessibilityIdentifier("palette.shortcut.\(command.id)")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(selected ? Brand.accent.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
        .contentShape(Rectangle())
    }

    /// The title with what matched the query in semibold.
    private func titleText(_ title: String) -> Text {
        PaletteMatch.segments(of: title, query: query).reduce(Text("")) { text, piece in
            text + (piece.matched ? Text(piece.text).fontWeight(.bold) : Text(piece.text))
        }
    }

    private func hint(_ key: String, _ text: String) -> some View {
        HStack(spacing: 4) {
            Text(key).font(.uiCaption.weight(.semibold)).fontDesign(.rounded)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))  // radius 4: outside the Radius scale, kept as it was
            Text(text).font(.uiCaption)
        }
        .foregroundStyle(.secondary)
    }

    func run(_ items: [Command], modifiers: EventModifiers) {
        guard items.indices.contains(selection) else { return }
        let command = items[selection]
        let action: @MainActor () -> Void
        if modifiers.contains(.command), let secondary = command.secondary { action = secondary.run }
        else if modifiers.contains(.option), let toggle = command.toggle { action = toggle.run }
        else { action = command.run }
        PaletteRecents.record(command.id, defaults)
        dismiss()
        action()
    }
}
