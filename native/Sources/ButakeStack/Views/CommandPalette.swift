import AppKit
import SwiftUI

/// ⌘K: one row per thing (page, site, engine, action), grouped by kind. Return opens it,
/// ⌘Return opens a site in the browser, ⌥Return turns a site or engine on or off.
struct CommandPalette: View {
    @Bindable var store: StackStore
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selection = 0
    @FocusState private var focused: Bool

    struct Command: Identifiable {
        let id: String
        let section: String
        let title: String
        let detail: String
        let tech: Tech?
        var symbol: String = ""
        let run: @MainActor () -> Void
        /// ⌘Return.
        var secondary: (title: String, run: @MainActor () -> Void)?
        /// ⌥Return.
        var toggle: (title: String, run: @MainActor () -> Void)?
    }

    var commands: [Command] {
        var list: [Command] = []
        for project in store.projects {
            let phase = store.sitePhase(project)
            list.append(Command(
                id: "site.\(project.id)", section: L("route.sites"), title: project.title,
                detail: project.enabled ? L("state.\(phase.rawValue)") : L("site.off"), tech: project.tech,
                run: { store.openSite(project.id) },
                secondary: (L("palette.openBrowser"), { if let url = project.url { NSWorkspace.shared.open(url) } }),
                toggle: (project.enabled ? L("palette.stop") : L("palette.start"), { Task { await store.setSite(project, enabled: !project.enabled) } })
            ))
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
        let pages: [(String, Route, Tech?, String)] = [("home", .home, nil, "house")]
            + Route.services.map { ($0, Route.service($0), Tech.of($0), "") }
            + Route.languages.map { ($0, Route.language($0), Tech.of($0), "") }
            + [("general", .general, nil, "gearshape.2")]
        for (id, route, tech, symbol) in pages {
            list.append(Command(id: "page.\(id)", section: L("palette.pages"), title: route.title, detail: "", tech: tech, symbol: symbol, run: { store.route = route }))
        }
        list.append(Command(id: "new", section: L("palette.actions"), title: L("new.menu"), detail: "", tech: .of("static"), run: { store.showNewProject = true }))
        list.append(Command(id: "add", section: L("palette.actions"), title: L("sites.addExisting"), detail: "", tech: nil, symbol: "folder.badge.plus", run: { store.chooseFolder() }))
        list.append(Command(id: "setup", section: L("palette.actions"), title: L("setup.title"), detail: "", tech: nil, symbol: "checklist", run: { store.showSetup = true }))
        list.append(Command(id: "restart", section: L("palette.actions"), title: L("menu.restartAll"), detail: "", tech: nil, symbol: "arrow.clockwise", run: { Task { await store.reloadStack() } }))
        let words = query.lowercased().split(separator: " ")
        return words.isEmpty ? list : list.filter { command in
            let haystack = (command.title + " " + command.detail).lowercased()
            return words.allSatisfy { haystack.contains($0) }
        }
    }

    var body: some View {
        let items = commands
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.system(size: 16, weight: .semibold)).foregroundStyle(Brand.accent)
                TextField(L("palette.prompt"), text: $query)
                    .textFieldStyle(.plain).font(.system(size: 18, design: .rounded))
                    .focused($focused)
                    .onKeyPress(.return, phases: .down) { press in
                        run(items, modifiers: press.modifiers)
                        return .handled
                    }
                    .accessibilityIdentifier("palette.query")
            }
            .padding(16)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        // One identity per row (the command's id), header included, so filtering never reuses stale rows.
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, command in
                            VStack(alignment: .leading, spacing: 2) {
                                if index == 0 || items[index - 1].section != command.section {
                                    Text(command.section.uppercased()).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
                                        .padding(.horizontal, 12).padding(.top, index == 0 ? 2 : 10).padding(.bottom, 2)
                                }
                                row(command, selected: index == selection)
                                    .onTapGesture { selection = index; run(items, modifiers: []) }
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
                hint("↩", L("palette.hint.open"))
                hint("⌘↩", L("palette.openBrowser"))
                hint("⌥↩", L("palette.hint.toggle"))
                Spacer()
                hint("esc", L("action.close"))
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
        }
        .frame(width: 580)
        .onAppear { focused = true }
        .onChange(of: query) { _, _ in selection = 0 }
        .onKeyPress(.downArrow) { selection = min(selection + 1, max(items.count - 1, 0)); return .handled }
        .onKeyPress(.upArrow) { selection = max(selection - 1, 0); return .handled }
        .onKeyPress(.escape) { dismiss(); return .handled }
    }

    private func row(_ command: Command, selected: Bool) -> some View {
        HStack(spacing: 12) {
            if let tech = command.tech { TechLogo(tech: tech, size: 24) } else { IconTile(symbol: command.symbol, size: 24) }
            Text(command.title).font(.system(size: 13.5, weight: .medium))
            if !command.detail.isEmpty { Text(command.detail).font(.uiCaption).foregroundStyle(.secondary) }
            Spacer()
            if selected {
                if let toggle = command.toggle { Text("⌥↩ " + toggle.title).font(.uiCaption).foregroundStyle(.secondary) }
                if command.secondary != nil { Text("⌘↩").font(.uiCaption).foregroundStyle(.secondary) }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(selected ? Brand.accent.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
    }

    private func hint(_ key: String, _ text: String) -> some View {
        HStack(spacing: 4) {
            Text(key).font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
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
        dismiss()
        action()
    }
}
