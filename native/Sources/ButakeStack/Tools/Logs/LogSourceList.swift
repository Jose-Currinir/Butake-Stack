import SwiftUI

/// Registros' column of sources, grouped by origin (web server, PHP-FPM, services, projects, the
/// vault) and filtered by the origin chosen in the toolbar.
struct LogSourceList: View {
    @Bindable var store: StackStore
    @Bindable var browser = LogsBrowser.shared
    @FocusState private var searchFocused: Bool
    var body: some View {
        let groups = browser.groups(store)
        List(selection: $browser.selection) {
            ForEach(groups) { group in
                Section(group.origin.title) {
                    ForEach(group.sources, id: \.self) { source in
                        row(source).tag(source)
                            .contextMenu { menu(source) }
                            .accessibilityIdentifier("logs.source.\(source)")
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .font(.uiBody)
        .themedScroll()
        .overlay {
            if groups.isEmpty {
                if browser.search.isEmpty {
                    ContentUnavailableView(L("logs.none"), systemImage: Symbols.logs, description: Text(L("logs.noneDetail")))
                }
                else { ContentUnavailableView.search(text: browser.search) }
            }
        }
        .searchable(text: $browser.search, placement: .sidebar, prompt: L("logs.search"))
        .searchFocused($searchFocused)
        .onChange(of: browser.searchRequests) { searchFocused = true }
        .accessibilityIdentifier("logs.list")
    }

    /// The page's actions on a source, the same as its toolbar (the vault's log is read only).
    @ViewBuilder private func menu(_ source: String) -> some View {
        if source != LogsBrowser.vaultSource {
            let paused = browser.isPaused(source)
            Button { browser.setPaused(source, !paused, store: store) } label: {
                Label(L(paused ? "logs.resume" : "logs.pause"), systemImage: paused ? Symbols.resume : Symbols.pause)
            }
            .accessibilityIdentifier("logs.source.menu.pause")
            Button { browser.clear(source, store: store) } label: { Label(L("logs.clear"), systemImage: Symbols.clearView) }
                .accessibilityIdentifier("logs.source.menu.clear")
            Divider()
            Button { browser.copy(store, source) } label: { Label(L("common.copy"), systemImage: Symbols.copy) }
                .accessibilityIdentifier("logs.source.menu.copy")
            Button { LogViewer.reveal(source) } label: { Label(L("logs.reveal"), systemImage: Symbols.folder) }
                .accessibilityIdentifier("logs.source.menu.reveal")
        }
    }

    private func row(_ source: String) -> some View {
        HStack(spacing: 8) {
            if source == LogsBrowser.vaultSource {
                Image(systemName: Symbols.vault).foregroundStyle(.secondary).font(.uiCaption)
            } else {
                let phase = store.phase(source)
                Image(systemName: phase.symbol).foregroundStyle(phase.color).font(.uiCaption)
                    .help(L("state.\(phase.rawValue)"))
            }
            Text(browser.title(store, source)).font(.uiBody).lineLimit(1)
            if source != LogsBrowser.vaultSource, browser.isPaused(source) {
                Spacer(minLength: 4)
                Text(L("logs.paused")).font(.uiCaption).foregroundStyle(.secondary)
            }
        }
    }
}
