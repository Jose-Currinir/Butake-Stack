import SwiftUI

/// A section of Utilidades (AI assistants, cloud, repositories), like a pane of System Settings: one
/// grouped form with a row per utility, its state and its one action. Its title is the window's.
struct UtilitiesPage: View {
    @Bindable var store: StackStore
    let group: String
    @State private var loaded = false

    var tools: [String] { UtilityCatalog.group(group)?.tools ?? [] }
    var installedCount: Int { tools.filter { store.devTools[$0]?.installed == true }.count }

    var body: some View {
        Form {
            Section {
                ForEach(tools, id: \.self) { UtilityRow(store: store, tool: $0) }
            } header: {
                // The page's state (error or nothing installed) goes above the rows, on its own
                // surface rather than inside a row.
                notice
            }
        }
        .formStyle(.grouped)
        .themedScroll()
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { Task { await reload(refresh: true) } } label: { Label(L("utilities.check"), systemImage: Symbols.reload).labelStyle(.iconOnly) }
                    .help(L("utilities.checkHelp"))
                    .disabled(store.busy != nil)
                    .accessibilityIdentifier("utilities.check")
            }
        }
        .task { await reload() }
    }

    @ViewBuilder private var notice: some View {
        if loaded && store.devTools.isEmpty {
            Notice(.error, L("utilities.loadFailed"), detail: L("utilities.loadFailedDetail")) {
                Button { Task { await reload() } } label: { Label(L("utilities.retry"), systemImage: Symbols.reload) }
                    .accessibilityIdentifier("utilities.retry")
            }
            .textCase(nil)
        } else if loaded && installedCount == 0 {
            Notice(.info, L("utilities.empty"), detail: L("utilities.emptyDetail"), symbol: Symbols.utilities)
                .textCase(nil)
        }
    }

    private func reload(refresh: Bool = false) async {
        await store.refreshDevTools(refresh: refresh)
        loaded = true
    }
}
