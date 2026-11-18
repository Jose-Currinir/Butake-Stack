import SwiftUI

/// A section of Utilidades (AI assistants, cloud, repositories), like a pane of System Settings: one
/// grouped form with a row per utility, its state and its one action. Its header (`DetailHeader`) says
/// which section it is and how many are installed, and holds the check for new versions.
struct UtilitiesPage: View {
    @Bindable var store: StackStore
    let group: String
    @State private var loaded = false

    var tools: [String] { UtilityCatalog.group(group)?.tools ?? [] }
    var installedCount: Int { tools.filter { store.devTools[$0]?.installed == true }.count }

    var body: some View {
        VStack(spacing: 0) {
            if let section = UtilityCatalog.group(group) {
                DetailHeader(title: section.title) {
                    TechLogo(tech: section.tech, size: DetailHeaderLogo.size)
                } subtitle: {
                    Text(String(format: L("utilities.installedOf"), installedCount, tools.count))
                        .accessibilityIdentifier("utilities.summary")
                } actions: {
                    Button { Task { await reload(refresh: true) } } label: { Label(L("utilities.check"), systemImage: Symbols.reload) }
                        .help(L("utilities.checkHelp"))
                        .disabled(store.busy != nil)
                        .accessibilityIdentifier("utilities.check")
                }
                Divider()
            }
            form
        }
        .task { await reload() }
    }

    private var form: some View {
        Form {
            Section {
                ForEach(tools, id: \.self) { UtilityRow(store: store, tool: $0) }
            } header: {
                // The page's error goes above the rows, on its own surface rather than inside a row.
                notice
            } footer: {
                // Nothing installed is already said by each row («Sin instalar»): only how they install.
                if loaded && !store.devTools.isEmpty && installedCount == 0 {
                    Text(L("utilities.emptyDetail")).font(.uiCaption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("utilities.emptyDetail")
                }
            }
        }
        .formStyle(.grouped)
        .themedScroll()
    }

    @ViewBuilder private var notice: some View {
        if loaded && store.devTools.isEmpty {
            Notice(.error, L("utilities.loadFailed"), detail: L("utilities.loadFailedDetail")) {
                Button { Task { await reload() } } label: { Label(L("utilities.retry"), systemImage: Symbols.reload) }
                    .accessibilityIdentifier("utilities.retry")
            }
            .textCase(nil)
        }
    }

    private func reload(refresh: Bool = false) async {
        await store.refreshDevTools(refresh: refresh)
        loaded = true
    }
}
