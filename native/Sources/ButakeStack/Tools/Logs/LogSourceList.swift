import SwiftUI

/// Registros' column of sources, grouped by origin (web server, PHP-FPM, services, projects, the
/// vault) and filtered by the origin chosen in the toolbar.
struct LogSourceList: View {
    @Bindable var store: StackStore
    @Bindable var browser = LogsBrowser.shared
    var body: some View {
        let groups = browser.groups(store)
        List(selection: $browser.selection) {
            ForEach(groups) { group in
                Section(group.origin.title) {
                    ForEach(group.sources, id: \.self) { source in
                        row(source).tag(source).accessibilityIdentifier("logs.source.\(source)")
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
        .accessibilityIdentifier("logs.list")
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
        }
    }
}
