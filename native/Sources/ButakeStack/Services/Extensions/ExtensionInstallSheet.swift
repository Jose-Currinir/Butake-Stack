import SwiftUI

/// «Instalar…» (or «Actualizar») of a catalog extension: what it downloads, from where, how big
/// and under which license, then the install followed step by step and stoppable. Nothing is
/// downloaded until the user confirms here.
struct ExtensionInstallSheet: View {
    @Bindable var store: StackStore
    let item: ComponentExtension
    let engineVersion: String
    @State private var monitor: InstallMonitor
    var scope: String { "service.database.postgres.ext.\(item.id).sheet" }

    init(store: StackStore, item: ComponentExtension, engineVersion: String) {
        self.store = store
        self.item = item
        self.engineVersion = engineVersion
        _monitor = State(initialValue: InstallMonitor(log: StackStore.extensionLog, tool: "extension-\(item.id)"))
    }

    var actionTitle: String { item.update == nil ? L("ext.install") : L("ext.update") }

    var body: some View {
        SheetFrame(title: String(format: L("ext.installTitle"), item.name), symbol: Symbols.package,
                   width: TextScale.points(560), height: TextScale.points(520),
                   actionTitle: monitor.finished ? L("progress.close") : actionTitle,
                   actionSymbol: monitor.finished ? nil : Symbols.install,
                   actionID: monitor.finished ? "\(scope).close" : "\(scope).confirm",
                   canAct: monitor.finished || (store.busy == nil && !monitor.running && item.supported),
                   cancelID: monitor.finished ? nil : "\(scope).cancel",
                   action: {
                       if monitor.finished { return true }
                       monitor.start(store) { try await store.installExtensionFollowed(item.id) }
                       return false
                   }) {
            if monitor.phase == .ready { confirmation } else {
                InstallProgressView(monitor: monitor, name: "\(item.name) \(item.version)", scope: "\(scope).progress")
            }
        }
        .following(monitor)
    }

    private var confirmation: some View {
        Form {
            Section {
                LabeledContent(L("utilities.version"), value: item.update ?? item.version)
                LabeledContent(L("ext.forEngine"), value: "PostgreSQL \(engineVersion)")
                if let license = item.license { LabeledContent(L("ext.license"), value: license) }
                LabeledContent(L("ext.downloadSize"), value: Format.fileSizeText(item.downloadSize))
                LabeledContent(L("ext.sqlNames"), value: item.sqlNames.joined(separator: ", "))
            } footer: {
                Text(L("ext.installDetail")).font(.uiCaption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
            }
            Section {
                ForEach(item.downloads) { download in
                    LabeledContent {
                        Text(Format.fileSizeText(download.size)).monospacedDigit().foregroundStyle(.secondary)
                    } label: {
                        Text(verbatim: "\(download.name) \(download.version)")
                        Text(String(format: L("ext.origin"), download.host, L("ext.role.\(download.role)"), download.license))
                    }
                    .help("\(download.url)\nSHA-256 \(download.sha256)")
                    .accessibilityIdentifier("\(scope).download.\(download.id)")
                }
            } header: {
                Text(L("ext.downloads"))
            } footer: {
                if let note = item.note {
                    Text(L("ext.note.\(note)")).font(.uiCaption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}

/// «Ver todas…»: every extension of the service, with its search; the catalog's can be installed
/// from here, the bundled ones are already there.
struct ExtensionBrowserSheet: View {
    let catalog: ExtensionCatalog
    let scope: String
    let install: (ComponentExtension) -> Void
    @State private var search = ""

    var shown: [ComponentExtension] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return catalog.extensions }
        return catalog.extensions.filter { item in
            item.name.lowercased().contains(query) || item.sqlNames.contains { $0.contains(query) }
        }
    }

    var body: some View {
        SheetFrame(title: String(format: L("ext.browserTitle"), catalog.version), symbol: Symbols.package,
                   width: TextScale.points(520), height: TextScale.points(520),
                   actionTitle: L("progress.close"), actionID: "\(scope).close", action: { true }) {
            VStack(spacing: 10) {
                FilterField(text: $search, identifier: "\(scope).search", prompt: L("ext.search"))
                if shown.isEmpty {
                    ContentUnavailableView.search(text: search)
                } else {
                    Form {
                        Section {
                            ForEach(shown) { item in
                                LabeledContent {
                                    if item.fromCatalog && !item.isInstalled && item.supported {
                                        Button { install(item) } label: { Label(L("ext.install"), systemImage: Symbols.install) }
                                            .buttonStyle(.bordered)
                                            .accessibilityIdentifier("\(scope).\(item.id).install")
                                    } else {
                                        Text(L(item.isInstalled ? "ext.state.installed" : "ext.state.available")).foregroundStyle(.secondary)
                                    }
                                } label: {
                                    Text(verbatim: item.name)
                                    Text(L("ext.kind.\(item.kind)"))
                                }
                                .accessibilityIdentifier("\(scope).\(item.id)")
                            }
                        }
                    }
                    .formStyle(.grouped)
                    .scrollContentBackground(.hidden)
                }
            }
        }
    }
}
