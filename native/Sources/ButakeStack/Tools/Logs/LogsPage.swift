import SwiftUI

/// Registros, like Console: its sources are in the window's content column (`LogSourceList`) and
/// this is the log of the one selected, with origin, level, pause, clear and copy in the toolbar.
/// Services, the web server, PHP-FPM and the vault open it already filtered (`StackStore.showLogs`).
struct LogsPage: View {
    @Bindable var store: StackStore
    @Bindable var browser = LogsBrowser.shared

    var body: some View {
        let groups = browser.groups(store)
        Group {
            if let source = browser.selection {
                if source == LogsBrowser.vaultSource {
                    // Also here, not only in the list: the tool turned off shows nothing of its log.
                    if store.pluginEnabled("vault") { VaultAccessLog(vault: .shared).id(source) }
                    else { ContentUnavailableView(L("logs.choose"), systemImage: Symbols.logs) }
                } else {
                    LogViewer(store: store, id: source, browser: browser).id(source)
                }
            } else {
                ContentUnavailableView(L("logs.choose"), systemImage: Symbols.logs)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .toolbar { toolbar }
        .focusedSceneValue(\.textFinder, TextFinderRequest { browser.searchRequests += 1 })
        .onChange(of: groups, initial: true) { _, groups in
            // Keep what was asked for; otherwise the web server, or the first source on screen.
            let sources = groups.flatMap(\.sources)
            if let selection = browser.selection, sources.contains(selection) { return }
            browser.selection = sources.contains("stack.caddy") ? "stack.caddy" : sources.first
        }
    }

    /// The filter that matters most (origin) and the two things done while reading (pause, clear) in
    /// sight; level, copy and Finder in «⋯».
    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        let source = browser.selection
        let isProcess = source.map { $0 != LogsBrowser.vaultSource } ?? false
        if #available(macOS 26, *) {
            // Apart from the window's own «+» (new project).
            ToolbarSpacer(.fixed, placement: .primaryAction)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Picker(selection: $browser.origin) {
                Text(L("logs.origin.all")).tag(LogOrigin?.none)
                Divider()
                ForEach(LogOrigin.allCases) { Text($0.title).tag(LogOrigin?.some($0)) }
            } label: {
                Label(L("logs.originTitle"), systemImage: Symbols.origin)
            }
            .pickerStyle(.menu).help(L("logs.originHelp")).accessibilityIdentifier("logs.toolbar.origin")
            Toggle(isOn: Binding(get: { source.map(browser.isPaused) ?? false },
                                 set: { on in if let source { browser.setPaused(source, on, store: store) } })) {
                let paused = source.map(browser.isPaused) ?? false
                Label(L(paused ? "logs.resume" : "logs.pause"), systemImage: paused ? Symbols.resume : Symbols.pause)
            }
            .toggleStyle(.button).disabled(!isProcess).help(L("logs.pauseHelp")).accessibilityIdentifier("logs.toolbar.pause")
            Button { if let source { browser.clear(source, store: store) } } label: { Label(L("logs.clear"), systemImage: Symbols.clearView) }
                .keyboardShortcut("k", modifiers: [.command, .option])
                .disabled(!isProcess).help(L("logs.clearHelp")).accessibilityIdentifier("logs.toolbar.clear")
            Menu {
                Picker(selection: $browser.level) {
                    ForEach(LogLevel.allCases) { Text($0.title).tag($0) }
                } label: {
                    Label(L("logs.levelTitle"), systemImage: Symbols.level)
                }
                .disabled(!isProcess).help(L("logs.levelHelp")).accessibilityIdentifier("logs.toolbar.level")
                Divider()
                Button { if let source { browser.copy(store, source) } } label: { Label(L("common.copy"), systemImage: Symbols.copy) }
                    .disabled(!isProcess).help(L("logs.copyHelp")).accessibilityIdentifier("logs.toolbar.copy")
                Button { if let source { LogViewer.reveal(source) } } label: { Label(L("logs.reveal"), systemImage: Symbols.folder) }
                    .disabled(!isProcess).help(L("logs.reveal")).accessibilityIdentifier("logs.toolbar.reveal")
            } label: {
                Label(L("logs.moreActions"), systemImage: Symbols.more)
            }
            .help(L("logs.moreActions")).accessibilityIdentifier("logs.toolbar.more")
        }
    }
}
