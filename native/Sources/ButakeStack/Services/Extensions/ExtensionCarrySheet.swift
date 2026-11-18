import SwiftUI

/// «Instalar en esta versión…»: the catalog extensions another installed PostgreSQL had, installed
/// one after the other in the version in use. What each downloads is listed first; nothing is
/// downloaded until the user confirms, and each install is followed and stoppable like «Instalar…».
struct ExtensionCarrySheet: View {
    @Bindable var store: StackStore
    let items: [ComponentExtension]
    let engineVersion: String
    @State private var monitors: [String: InstallMonitor]
    @State private var current: String?
    @State private var started = false
    @State private var finished = false
    let scope = "service.database.postgres.ext.carry"

    init(store: StackStore, items: [ComponentExtension], engineVersion: String) {
        self.store = store
        self.items = items
        self.engineVersion = engineVersion
        _monitors = State(initialValue: Dictionary(uniqueKeysWithValues: items.map {
            ($0.id, InstallMonitor(log: StackStore.extensionLog, tool: "extension-\($0.id)"))
        }))
    }

    var monitor: InstallMonitor? { current.flatMap { monitors[$0] } }
    var currentItem: ComponentExtension? { items.first { $0.id == current } }

    var body: some View {
        SheetFrame(title: String(format: L("ext.carry.sheetTitle"), engineVersion), symbol: Symbols.package,
                   width: TextScale.points(560), height: TextScale.points(520),
                   actionTitle: finished ? L("progress.close") : L("common.install"),
                   actionSymbol: finished ? nil : Symbols.install,
                   actionID: finished ? "\(scope).close" : "\(scope).confirm",
                   canAct: finished || (store.busy == nil && !started),
                   cancelID: finished ? nil : "\(scope).cancel",
                   action: {
                       if finished { return true }
                       started = true
                       Task { await installAll() }
                       return false
                   }) {
            if let monitor, let item = currentItem {
                InstallProgressView(monitor: monitor, name: "\(item.name) \(item.version)", scope: "\(scope).progress")
            } else {
                confirmation
            }
        }
        .following(monitor)
    }

    /// One after the other; a failure or «Cancelar» leaves the rest as they were.
    private func installAll() async {
        for item in items {
            guard let monitor = monitors[item.id] else { continue }
            current = item.id
            guard await monitor.run(store, { try await store.installExtensionFollowed(item.id) }) else { break }
        }
        finished = true
    }

    private var confirmation: some View {
        Form {
            Section {
                ForEach(items) { item in
                    LabeledContent {
                        Text(Format.fileSizeText(item.downloadSize)).monospacedDigit().foregroundStyle(.secondary)
                    } label: {
                        Text(verbatim: "\(item.name) \(item.version)")
                        Text(String(format: L("ext.carry.from"), item.elsewhere.joined(separator: ", ")))
                    }
                    .accessibilityIdentifier("\(scope).item.\(item.id)")
                }
            } footer: {
                Text(L("ext.installDetail")).font(.uiCaption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}
