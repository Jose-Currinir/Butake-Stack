import AppKit
import SwiftUI

/// Terminal, the detail of the page. Without a session shown it is the card of what is selected in
/// the list: a program of this Mac (`LocalProgramCard`) or a host (`SSHHostCard`); with one, its
/// tabs and the terminal or the remote files fill the detail, and the host's card can open beside
/// them as an inspector (hidden until asked for, and only while the window leaves the session
/// room). «Este Mac» and the hosts are in the window's content column (`SSHHostList`).
struct SSHTerminalView: View {
    @Bindable var terminal = SSHTerminal.shared
    @Bindable var keyring = SSHKeyring.shared
    @Bindable var workspace = SSHWorkspace.shared
    @State private var pickingSnippet = false
    @State private var editingThemes = false
    /// The detail's width with the inspector: it opens only when the session keeps `minimumSession`.
    @State private var width: CGFloat = 0
    static let minimumSession: CGFloat = 480
    static let inspectorWidth: CGFloat = 280

    /// The program of this Mac whose card is shown: the one chosen, or «Consola» while no host is.
    private var selectedProgram: LocalProgram? {
        if let id = workspace.localSelection { return LocalConsoles.program(id) ?? .shell }
        return terminal.host(terminal.selection) == nil ? .shell : nil
    }
    private var selectedHost: SSHHost? { selectedProgram == nil ? terminal.host(terminal.selection) : nil }
    /// The host of the tab shown, or the selected one on its card (nil for a local session).
    private var shownHost: SSHHost? {
        if let tab = workspace.current { return terminal.host(tab.hostID) }
        return selectedHost
    }
    private var terminalTab: WorkspaceTab? { workspace.current.flatMap { $0.browser == nil ? $0 : nil } }
    /// The inspector is offered beside a session of a saved host, when the window is wide enough.
    private var canInspect: Bool {
        workspace.current != nil && shownHost != nil && width >= Self.minimumSession + Self.inspectorWidth
    }

    var body: some View {
        VStack(spacing: 0) {
            if !workspace.tabs.isEmpty { WorkspaceTabBar(workspace: workspace) }
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
                #if DEBUG
                .overlay(alignment: .topTrailing) { TerminalQA.usagePanel(workspace) }
                #endif
        }
        .inspector(isPresented: Binding(get: { workspace.inspector && canInspect }, set: { workspace.inspector = $0 })) {
            if let host = shownHost {
                SSHHostCard(terminal: terminal, keyring: keyring, host: host)
                    .inspectorColumnWidth(min: 240, ideal: Self.inspectorWidth, max: 340)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .toolbar { toolbar }
        .background { shortcuts }
        .focusedSceneValue(\.textFinder, TextFinderRequest {
            if let session = terminalTab?.focusedSession { session.searchVisible = true } else { workspace.searchRequests += 1 }
        })
        .task {
            // What «Este Mac» offers is what the Utilidades page found.
            if StackStore.shared.devTools.isEmpty { Task { await StackStore.shared.refreshDevTools() } }
            await keyring.load()
            await terminal.load()
            await SSHSnippets.shared.load()
            terminal.startKeepAlive()
            #if DEBUG
            await QAHooks.ssh(terminal: terminal, workspace: workspace, keyring: keyring)
            await TerminalQA.start(workspace: workspace)
            #endif
        }
        .sheet(item: $terminal.editing) { host in SSHHostEditor(terminal: terminal, keys: keyring, original: host).themedSheet() }
        .sheet(item: $workspace.sheet) { sheet in
            switch sheet {
            case .importConfig: SSHConfigImportSheet().themedSheet()
            case .snippets: SnippetsSheet(hostID: shownHost?.id).themedSheet()
            case .groups: SSHGroupsSheet(terminal: terminal).themedSheet()
            }
        }
        .sheet(isPresented: $pickingSnippet) { SnippetPicker(session: terminalTab?.focusedSession).themedSheet() }
        .sheet(isPresented: $editingThemes) { TerminalThemeEditor(workspace: workspace).themedSheet() }
        .sheet(item: $terminal.trustRequest) { request in SSHTrustSheet(terminal: terminal, request: request).themedSheet() }
        // While another sheet is up (editor, trust), that one shows the prompt.
        .sheet(item: Binding(get: { terminal.editing != nil || terminal.trustRequest != nil ? nil : keyring.prompt },
                             set: { keyring.prompt = $0 })) { request in PassphraseSheet(request: request).themedSheet() }
        .confirmationDialog(String(format: L("ssh.deleteConfirm"), terminal.deleting?.name ?? ""),
                            isPresented: Binding(get: { terminal.deleting != nil }, set: { if !$0 { terminal.deleting = nil } }),
                            presenting: terminal.deleting) { host in
            Button(L("ssh.delete"), role: .destructive) { Task { await terminal.delete(host) } }
                .disabled(!terminal.jumpers(of: host).isEmpty).accessibilityIdentifier("ssh.confirmDelete")
            Button(L("common.cancel"), role: .cancel) {}
        } message: { host in
            let jumpers = terminal.jumpers(of: host)
            Text(jumpers.isEmpty ? L("ssh.deleteDetail") : String(format: L("ssh.deleteJumpDetail"), jumpers.map(\.name).joined(separator: ", ")))
        }
        .confirmationDialog(String(format: L("ssh.tabs.closeConfirm"), workspace.closing?.title ?? ""),
                            isPresented: Binding(get: { workspace.closing != nil }, set: { if !$0 { workspace.closing = nil } }),
                            presenting: workspace.closing) { tab in
            Button(L("ssh.tabs.close"), role: .destructive) { workspace.close(tab) }.accessibilityIdentifier("ssh.tabs.confirmClose")
            Button(L("common.cancel"), role: .cancel) {}
        } message: { tab in
            Text(L(tab.browser == nil ? "ssh.tabs.closeDetail" : "ssh.tabs.closeTransfersDetail"))
        }
        .confirmationDialog(String(format: L("ssh.tabs.closeConfirm"), workspace.closingPane?.session.title ?? ""),
                            isPresented: Binding(get: { workspace.closingPane != nil }, set: { if !$0 { workspace.closingPane = nil } }),
                            presenting: workspace.closingPane) { pane in
            Button(L("ssh.tabs.close"), role: .destructive) { workspace.closePane(pane.tab, pane.session) }.accessibilityIdentifier("ssh.panes.confirmClose")
            Button(L("common.cancel"), role: .cancel) {}
        } message: { _ in
            Text(L("ssh.tabs.closeDetail"))
        }
    }

    @ViewBuilder private var content: some View {
        if let tab = workspace.current {
            if let browser = tab.browser { SSHFilesView(browser: browser).id(tab.id) } else { TerminalTabView(tab: tab).id(tab.id) }
        } else if let host = selectedHost {
            SSHHostCard(terminal: terminal, keyring: keyring, host: host).id(host.id)
        } else if let program = selectedProgram, terminal.loaded || workspace.localSelection != nil {
            LocalProgramCard(program: program, workspace: workspace).id(program.id)
        } else {
            ProgressView()
        }
    }

    // MARK: Toolbar

    /// The toolbar keeps the system's size whatever the text size of the page (`.font(nil)`).
    /// One group on the detail: Archivos and Reenvíos, the page's main action with its title (Conectar,
    /// or «Nueva sesión» beside an open one), «Más acciones» (with the terminal's own tools while one
    /// is shown) and, beside a session, the inspector.
    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        if let browser = workspace.current?.browser { SFTPToolbar(browser: browser) }
        ToolbarItemGroup(placement: .primaryAction) {
            if let host = shownHost {
                // Beside the files, their own actions take the room.
                if workspace.current?.browser == nil {
                    Button { Task { await terminal.openFiles(host) } } label: { Label(L("ssh.sftp.open"), systemImage: Symbols.folder) }
                        .labelStyle(.titleAndIcon).font(nil).disabled(terminal.checking.contains(host.id))
                        .help(L("ssh.sftp.openHelp")).accessibilityIdentifier("ssh.toolbar.files")
                    forwardsMenu(host)
                }
            }
            Button { newSession() } label: {
                Label(L(workspace.current != nil ? "ssh.tabs.new" : shownHost == nil ? "ssh.local.open" : "ssh.connect"), systemImage: Symbols.terminal)
            }
            .labelStyle(.titleAndIcon).font(nil).buttonStyle(.borderedProminent)
            .disabled(shownHost.map { terminal.checking.contains($0.id) } ?? false)
            .help(L(shownHost == nil && workspace.current == nil ? "ssh.local.openHelp" : "ssh.connectHelp"))
            .accessibilityIdentifier("ssh.toolbar.connect")
            moreMenu
            if canInspect {
                Button { workspace.inspector.toggle() } label: { Label(L("ssh.inspector.toggle"), systemImage: Symbols.inspector) }
                    .keyboardShortcut("i", modifiers: [.command, .option])
                    .help(L("ssh.inspector.help")).accessibilityIdentifier("ssh.toolbar.inspector")
            }
        }
    }

    /// The port forwards of the host, started and stopped from here too.
    private func forwardsMenu(_ host: SSHHost) -> some View {
        Menu {
            ForEach(host.forwards) { forward in
                let on = terminal.since(host, forward) != nil || terminal.dropped(host, forward)?.keepAlive == true
                Toggle(isOn: Binding(get: { on }, set: { start in
                    Task { if start { await terminal.start(host, forward) } else { await terminal.stop(host, forward) } }
                })) { Text(verbatim: "\(forward.title) · \(forward.route)") }
            }
            if host.forwards.contains(where: \.autostart) {
                Button { Task { await terminal.startAll(host) } } label: { Label(L("ssh.startAll"), systemImage: Symbols.active) }
            }
            if !host.forwards.isEmpty { Divider() }
            Button { terminal.editing = host } label: { Label(L("ssh.addForwardEllipsis"), systemImage: Symbols.add) }
        } label: {
            Label(L("ssh.forwardsShort"), systemImage: Symbols.forwards)
        }
        .labelStyle(.titleAndIcon)
        .help(L("ssh.forwardsHelp")).accessibilityIdentifier("ssh.toolbar.forwards")
    }

    /// A terminal tab's own tools: search its scrollback (⌘F), insert a snippet, split it, its theme.
    @ViewBuilder private func terminalTools(_ tab: WorkspaceTab) -> some View {
        Section(L("ssh.terminal.menu")) {
            Button { tab.focusedSession?.searchVisible = true } label: { Label(L("ssh.terminal.search"), systemImage: Symbols.search) }
                .accessibilityIdentifier("ssh.toolbar.terminal.search")
            Button { pickingSnippet = true } label: { Label(L("ssh.snippets.insertEllipsis"), systemImage: Symbols.snippets) }
                .accessibilityIdentifier("ssh.toolbar.terminal.snippets")
            Divider()
            Button { workspace.split(tab, axis: .horizontal) } label: { Label(L("ssh.terminal.splitRight"), systemImage: Symbols.splitRight) }
                .accessibilityIdentifier("ssh.toolbar.terminal.splitRight")
            Button { workspace.split(tab, axis: .vertical) } label: { Label(L("ssh.terminal.splitDown"), systemImage: Symbols.splitDown) }
                .accessibilityIdentifier("ssh.toolbar.terminal.splitDown")
            if let session = tab.focusedSession, tab.sessions.count > 1 {
                Button { workspace.requestClosePane(tab, session) } label: { Label(L("ssh.terminal.closePane"), systemImage: Symbols.close) }
                    .accessibilityIdentifier("ssh.toolbar.terminal.closePane")
            }
            Divider()
            Picker(selection: $workspace.themeID) {
                ForEach(workspace.themes) { theme in Text(theme.name).tag(theme.id) }
            } label: { Label(L("ssh.terminal.theme"), systemImage: Symbols.appearance) }
            Button { editingThemes = true } label: { Label(L("ssh.terminal.editThemesEllipsis"), systemImage: Symbols.edit) }
                .accessibilityIdentifier("ssh.toolbar.terminal.editThemes")
        }
    }

    /// The rest: the host's actions, the page's sheets and a shell of this Mac.
    private var moreMenu: some View {
        Menu {
            if let tab = terminalTab {
                terminalTools(tab)
                Divider()
            }
            if let host = shownHost {
                SSHHostMenu(terminal: terminal, host: host)
                Divider()
            }
            Button { workspace.sheet = .importConfig } label: { Label(L("ssh.config.titleEllipsis"), systemImage: Symbols.importing) }
                .accessibilityIdentifier("ssh.toolbar.more.import")
            Button { workspace.sheet = .groups } label: { Label(L("ssh.groups.titleEllipsis"), systemImage: Symbols.tags) }
                .disabled(terminal.hosts.isEmpty).accessibilityIdentifier("ssh.toolbar.more.groups")
            Button { workspace.sheet = .snippets } label: { Label(L("ssh.snippets.manageEllipsis"), systemImage: Symbols.snippets) }
                .accessibilityIdentifier("ssh.toolbar.more.snippets")
        } label: {
            Label(L("ssh.moreActions"), systemImage: Symbols.more)
        }
        .help(L("ssh.moreActions")).accessibilityIdentifier("ssh.toolbar.more")
    }

    // MARK: Keyboard

    /// ⌘T a new session (of the tab's host, the selected host or a local shell), ⌘W closes the tab
    /// shown (the window's ⌘W while none is), ⌃Tab and ⌃⇧Tab move between tabs, ⌘D and ⇧⌘D split,
    /// ⌘F (Edición › Buscar) searches the terminal's scrollback, or the hosts while no terminal is
    /// shown; ⌥⌘F always searches the hosts.
    @ViewBuilder private var shortcuts: some View {
        Group {
            Button(L("ssh.tabs.new")) { newSession() }.keyboardShortcut("t")
            if let tab = workspace.current {
                Button(L("ssh.terminal.closeTab")) { workspace.requestClose(tab) }.keyboardShortcut("w")
            }
            if !workspace.tabs.isEmpty {
                Button(L("ssh.tabs.next")) { workspace.cycle(1) }.keyboardShortcut(.tab, modifiers: .control)
                Button(L("ssh.tabs.previous")) { workspace.cycle(-1) }.keyboardShortcut(.tab, modifiers: [.control, .shift])
            }
            if let tab = terminalTab {
                Button(L("ssh.terminal.splitRight")) { workspace.split(tab, axis: .horizontal) }.keyboardShortcut("d")
                Button(L("ssh.terminal.splitDown")) { workspace.split(tab, axis: .vertical) }.keyboardShortcut("d", modifiers: [.command, .shift])
            }
            Button(L("ssh.searchHosts")) { workspace.searchRequests += 1 }.keyboardShortcut("f", modifiers: [.command, .option])
        }
        .hidden()
    }

    /// ⌘T and the main button: another session like the one shown (the same program in the same
    /// folder, or the same host), else the program or host chosen in the list.
    private func newSession() {
        if let launch = terminalTab?.focusedSession?.kind.launch { workspace.openLocal(launch); return }
        if let host = shownHost { Task { await terminal.open(host) } } else { workspace.openLocal(selectedProgram ?? .shell) }
    }
}
