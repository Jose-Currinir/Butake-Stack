import SwiftUI

/// A tag the host search filters by, written as a token in the search field.
struct SSHTagToken: Identifiable, Hashable {
    let tag: String
    var id: String { tag.lowercased() }
}

/// The SSH terminal's hosts in the window's content column, a section per group («Sin grupo» last).
/// A host is selected with a click or the arrows; Return or a double click connects. Hosts move
/// between groups by dragging them onto another group's header or one of its hosts; each group's
/// header renames or deletes it from its context menu.
struct SSHHostList: View {
    @Bindable var terminal: SSHTerminal
    @Bindable var workspace: SSHWorkspace
    @State private var search = ""
    @State private var tokens: [SSHTagToken] = []
    @State private var renaming: String?
    @State private var deleting: String?
    @FocusState private var searchFocused: Bool

    private var visible: [SSHHost] {
        terminal.hosts.filter { host in host.matches(search) && tokens.allSatisfy { host.has(tag: $0.tag) } }
    }
    private var filtering: Bool { !search.isEmpty || !tokens.isEmpty }
    /// «Consola» and the assistants detected; tags are of hosts, so a tag in the search hides them.
    private var programs: [LocalProgram] {
        guard tokens.isEmpty else { return [] }
        return LocalConsoles.programs(store.devTools).filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }
    }
    private var store: StackStore { .shared }

    /// A program of this Mac and a host share the list's selection: the program's tag is «local:<id>».
    static func tag(local id: String) -> String { "local:" + id }
    static func local(tag: String) -> String? { tag.hasPrefix("local:") ? String(tag.dropFirst(6)) : nil }

    var body: some View {
        VStack(spacing: 0) {
            List(selection: Binding(get: {
                // The row of what the detail shows: the tab on screen, or the card of what was chosen.
                workspace.listSelection(host: terminal.selection)
            }, set: { id in
                guard let id else { return }
                // Choosing a host or a program shows its page, also from one of its sessions.
                if let program = Self.local(tag: id) { workspace.localSelection = program } else {
                    terminal.selection = id
                    workspace.localSelection = nil
                }
                workspace.selected = nil
            })) {
                let local = programs
                if !local.isEmpty {
                    Section(L("ssh.local.section")) {
                        ForEach(local) { program in
                            LocalProgramRow(program: program, workspace: workspace).tag(Self.tag(local: program.id))
                        }
                    }
                }
                let shown = visible
                let groups = terminal.groups.filter { group in shown.contains { $0.group == group } }
                ForEach(groups, id: \.self) { group in
                    Section {
                        ForEach(shown.filter { $0.group == group }) { host in
                            SSHHostRow(terminal: terminal, workspace: workspace, host: host)
                                .tag(host.id)
                                .draggable(host.id)
                                .dropDestination(for: String.self) { items, _ in drop(items, on: group) }
                        }
                    } header: {
                        // Hosts all without a group are just «Hosts», beside «Este Mac».
                        header(group, only: groups.count == 1)
                    }
                }
                if terminal.loaded && terminal.hosts.isEmpty && !filtering { noHosts }
            }
            .listStyle(.sidebar)
            .themedScroll()
            .contextMenu(forSelectionType: String.self) { ids in
                if let id = ids.first, let program = Self.local(tag: id).flatMap(LocalConsoles.program) {
                    LocalProgramMenu(program: program, workspace: workspace)
                } else if let id = ids.first, let host = terminal.host(id) { SSHHostMenu(terminal: terminal, host: host) }
            } primaryAction: { ids in
                if let id = ids.first, let program = Self.local(tag: id).flatMap(LocalConsoles.program) { workspace.openLocal(program) }
                else if let id = ids.first, let host = terminal.host(id) { Task { await terminal.open(host) } }
            }
            .overlay { empty }
            .searchable(text: $search, tokens: $tokens, placement: .sidebar, prompt: L("ssh.search")) { token in
                Label(token.tag, systemImage: Symbols.tags)
            }
            .searchFocused($searchFocused)
            .onChange(of: workspace.searchRequests) { searchFocused = true }
            .searchSuggestions {
                ForEach(tagSuggestions, id: \.self) { tag in
                    Label(tag, systemImage: Symbols.tags).searchCompletion(SSHTagToken(tag: tag))
                        .accessibilityIdentifier("ssh.list.suggestion.\(tag)")
                }
            }
            .accessibilityIdentifier("ssh.list")
            // The height and the line of the window's status bar beside it, so both run as one.
            HStack {
                // The same additions as the window's «+» on this page: consoles, assistants, a host.
                Menu { TerminalNewItems(scope: "ssh.list.new") } label: { Label(L("ssh.local.new"), systemImage: Symbols.add) }
                    .menuStyle(.borderlessButton).fixedSize()
                    .help(L("ssh.local.newHelp")).accessibilityIdentifier("ssh.list.new")
                Spacer()
                Button { SettingsRouter.shared.open(.keys) } label: {
                    Label(L("settings.manageKeys"), systemImage: Symbols.key).labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless).help(L("settings.manageKeys")).accessibilityIdentifier("ssh.list.manageKeys")
            }
            .padding(.horizontal, 10).frame(height: 29)
            .overlay(alignment: .top) { Divider() }
        }
        .sheet(item: Binding(get: { renaming.map(SSHNameRequest.group) }, set: { if $0 == nil { renaming = nil } })) { request in
            SSHNameSheet(request: request, terminal: terminal).themedSheet()
        }
        .confirmationDialog(String(format: L("ssh.groups.deleteConfirm"), deleting ?? ""),
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { group in
            Button(L("ssh.groups.delete"), role: .destructive) { Task { await terminal.deleteGroup(group) } }
                .accessibilityIdentifier("ssh.list.confirmDeleteGroup")
            Button(L("common.cancel"), role: .cancel) {}
        } message: { group in
            Text(String(format: L("ssh.groups.deleteDetail"), terminal.hostCount(group: group)))
        }
        #if DEBUG
        .task { if let preset = QAHooks.sshSearch { search = preset.text; tokens = preset.tags.map { SSHTagToken(tag: $0) } } }
        #endif
    }

    /// Tags not yet in the search that match what is typed (all of them while nothing is).
    private var tagSuggestions: [String] {
        terminal.tags.filter { tag in
            !tokens.contains { $0.id == tag.lowercased() } && (search.isEmpty || tag.localizedCaseInsensitiveContains(search))
        }
    }

    /// Without hosts, their section says so in one short line; adding one is in «+» and the
    /// footer. A full `ContentUnavailableView` does not fit a list column.
    private var noHosts: some View {
        Section(L("ssh.hosts.section")) {
            Text(L("ssh.hosts.none")).font(.uiCallout).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.tail)
                .selectionDisabled()
                .accessibilityIdentifier("ssh.list.noHosts")
        }
    }

    /// A search that finds nothing, or the list while it loads.
    @ViewBuilder private var empty: some View {
        if terminal.loaded && filtering && visible.isEmpty && programs.isEmpty {
            ContentUnavailableView.search(text: search.isEmpty ? tokens.map(\.tag).joined(separator: ", ") : search)
        } else if !terminal.loaded {
            ProgressView()
        }
    }

    private func header(_ group: String, only: Bool) -> some View {
        Text(group.isEmpty ? L(only ? "ssh.hosts.section" : "ssh.noGroup") : group)
            .lineLimit(1).truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .dropDestination(for: String.self) { items, _ in drop(items, on: group) }
            .contextMenu {
                if !group.isEmpty {
                    Button { renaming = group } label: { Label(L("ssh.groups.renameEllipsis"), systemImage: Symbols.edit) }
                        .accessibilityIdentifier("ssh.list.group.rename")
                    Button(role: .destructive) { deleting = group } label: { Label(L("ssh.groups.deleteEllipsis"), systemImage: Symbols.delete) }
                        .accessibilityIdentifier("ssh.list.group.delete")
                }
            }
            .accessibilityIdentifier("ssh.list.group.\(group.isEmpty ? "none" : group)")
    }

    /// Hosts dragged by their id; anything else dropped here is ignored.
    private func drop(_ ids: [String], on group: String) -> Bool {
        let moving = ids.compactMap { terminal.host($0) }.filter { $0.group != group }
        guard !moving.isEmpty else { return false }
        Task { for host in moving { await terminal.move(host.id, to: group) } }
        return true
    }
}

private struct SSHHostRow: View {
    @Bindable var terminal: SSHTerminal
    @Bindable var workspace: SSHWorkspace
    let host: SSHHost
    var body: some View {
        let forwards = terminal.activeCount(host)
        let dropped = terminal.down.contains { $0.host == host.id }
        let sessions = workspace.tabs.flatMap(\.sessions).filter { $0.kind.hostID == host.id && $0.running }.count
        HStack(spacing: 8) {
            IconTile(symbol: Symbols.server, size: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(host.name).font(.uiBody).lineLimit(1).truncationMode(.tail)
                Text(host.address).font(.uiCaption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    .help(host.jump.flatMap { terminal.host($0)?.name }.map { String(format: L("ssh.viaJump"), $0) } ?? host.address)
            }
            Spacer(minLength: 4)
            if sessions > 0 {
                Image(systemName: Symbols.terminal).font(.uiCaption).foregroundStyle(.secondary)
                    .help(String(format: L("ssh.sessionsOpen"), sessions)).accessibilityLabel(String(format: L("ssh.sessionsOpen"), sessions))
            }
            if dropped {
                Image(systemName: Symbols.warning).font(.uiCaption).foregroundStyle(Brand.warning)
                    .help(L("ssh.forwardsDropped")).accessibilityLabel(L("ssh.forwardsDropped"))
            }
            if forwards > 0 {
                Text("\(forwards)").font(.uiCaption.weight(.semibold).monospacedDigit()).foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Brand.success, in: Capsule())
                    .help(String(format: L("ssh.forwardsRunning"), forwards))
            }
        }
        .accessibilityIdentifier("ssh.list.host.\(host.id)")
    }
}

/// The actions on a host, the same in the list's context menu and the toolbar's «Más».
struct SSHHostMenu: View {
    @Bindable var terminal: SSHTerminal
    let host: SSHHost
    var body: some View {
        Button { Task { await terminal.open(host) } } label: { Label(L("ssh.connect"), systemImage: Symbols.terminal) }
            .accessibilityIdentifier("ssh.menu.connect")
        Button { Task { await terminal.openFiles(host) } } label: { Label(L("ssh.sftp.open"), systemImage: Symbols.folder) }
            .accessibilityIdentifier("ssh.menu.files")
        Button { Task { await terminal.openExternal(host) } } label: { Label(L("ssh.openExternal"), systemImage: Symbols.openInApp) }
            .accessibilityIdentifier("ssh.menu.external")
        Button { Task { await terminal.copyCommand(host) } } label: { Label(L("ssh.copyCommand"), systemImage: Symbols.copy) }
            .accessibilityIdentifier("ssh.menu.copyCommand")
        Divider()
        Button { terminal.editing = host } label: { Label(L("ssh.editEllipsis"), systemImage: Symbols.edit) }
            .accessibilityIdentifier("ssh.menu.edit")
        Button { terminal.editing = host.duplicate() } label: { Label(L("ssh.duplicateEllipsis"), systemImage: Symbols.copy) }
            .accessibilityIdentifier("ssh.menu.duplicate")
        Menu {
            Picker(L("ssh.moveTo"), selection: Binding(get: { host.group }, set: { group in Task { await terminal.move(host.id, to: group) } })) {
                ForEach(terminal.groups.filter { !$0.isEmpty }, id: \.self) { Text($0).tag($0) }
                Text(L("ssh.noGroup")).tag("")
            }
            .pickerStyle(.inline)
        } label: {
            Label(L("ssh.moveTo"), systemImage: Symbols.folder)
        }
        .accessibilityIdentifier("ssh.menu.move")
        Divider()
        Button(role: .destructive) { terminal.deleting = host } label: { Label(L("ssh.deleteEllipsis"), systemImage: Symbols.delete) }
            .accessibilityIdentifier("ssh.menu.delete")
    }
}
