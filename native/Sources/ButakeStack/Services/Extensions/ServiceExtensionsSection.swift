import SwiftUI

/// «Extensiones» of a service's page (PostgreSQL): the catalog's, installed or to install, with
/// «Instalar…», «Actualizar» and «Quitar…»; how many come with the service; and «Ver todas…», the
/// whole list with its search. Activating one in a database is done in that database.
struct ServiceExtensionsSection: View {
    @Bindable var store: StackStore
    let scope: String
    @State private var catalog: ExtensionCatalog?
    @State private var failure: String?
    @State private var installing: ComponentExtension?
    @State private var removing: ComponentExtension?
    @State private var browsing = false
    /// «Instalar en esta versión…»: what another installed version had.
    @State private var carrying: [ComponentExtension]?

    var body: some View {
        Section {
            if let catalog {
                ForEach(catalog.catalog) { item in
                    ExtensionCatalogRow(store: store, item: item, engineVersion: catalog.version, scope: "\(scope).\(item.id)",
                                        install: { installing = item }, remove: { removing = item })
                }
                // Another installed version had them: one offer to install them all in this one.
                let carry = catalog.catalog.filter { !$0.isInstalled && !$0.elsewhere.isEmpty && $0.supported }
                if !carry.isEmpty {
                    Notice(.info, String(format: L("ext.carry.title"), carry.map(\.name).joined(separator: ", ")),
                           detail: String(format: L("ext.carry.detail"), catalog.version)) {
                        Button { carrying = carry } label: { Label(L("ext.carry.action"), systemImage: Symbols.install) }
                            .buttonStyle(.bordered).disabled(store.busy != nil)
                            .accessibilityIdentifier("\(scope).carry")
                    }
                    .accessibilityIdentifier("\(scope).elsewhere")
                }
                ForEach(catalog.catalog.filter { !$0.isInstalled && !$0.elsewhere.isEmpty && !$0.supported }) { item in
                    Notice(.info, String(format: L("ext.elsewhere"), item.name, item.elsewhere.joined(separator: ", ")),
                           detail: String(format: L("ext.unsupported"), catalog.version))
                        .accessibilityIdentifier("\(scope).\(item.id).elsewhere")
                }
                LabeledContent(L("ext.bundled")) {
                    Text(String(format: L("ext.bundledCount"), catalog.bundled.count)).foregroundStyle(.secondary).monospacedDigit()
                }
            } else if let failure {
                Text(failure).foregroundStyle(.secondary).accessibilityIdentifier("\(scope).failed")
            } else {
                ProgressView().controlSize(.small).accessibilityIdentifier("\(scope).loading")
            }
        } header: {
            HStack {
                Text(L("ext.title"))
                Spacer()
                Button { browsing = true } label: { Label(L("ext.browse"), systemImage: Symbols.search) }
                    .buttonStyle(.bordered).controlSize(.small).disabled(catalog == nil)
                    .accessibilityIdentifier("\(scope).browse")
            }
        } footer: {
            Text(L("ext.footer")).font(.uiCaption).foregroundStyle(.secondary).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { await load() }
        .sheet(item: $installing, onDismiss: { Task { await load() } }) { item in
            ExtensionInstallSheet(store: store, item: item, engineVersion: catalog?.version ?? "").themedSheet()
        }
        .sheet(item: Binding(get: { carrying.map(CarryRequest.init) }, set: { carrying = $0?.items }), onDismiss: { Task { await load() } }) { request in
            ExtensionCarrySheet(store: store, items: request.items, engineVersion: catalog?.version ?? "").themedSheet()
        }
        .sheet(isPresented: $browsing) {
            if let catalog {
                ExtensionBrowserSheet(catalog: catalog, scope: "\(scope).browser") { item in
                    browsing = false
                    installing = item
                }
                .themedSheet()
            }
        }
        .confirmationDialog(removing.map { String(format: L("ext.confirmRemove"), $0.name) } ?? "",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), presenting: removing) { item in
            Button(L("common.remove"), role: .destructive) {
                Task { if await store.removeExtension(item.id) { await load() } }
            }
            .accessibilityIdentifier("\(scope).\(item.id).confirmRemove")
            Button(L("common.cancel"), role: .cancel) {}
        } message: { _ in Text(L("ext.removeDetail")) }
    }

    private func load() async {
        do {
            catalog = try await store.extensionCatalog()
            failure = nil
            #if DEBUG
            if let sheet = QAHooks.extensionSheet, installing == nil, !browsing, carrying == nil {
                switch sheet {
                case "browser": browsing = true
                case "carry": carrying = catalog?.catalog.filter { !$0.isInstalled && !$0.elsewhere.isEmpty && $0.supported }
                default: installing = catalog?.catalog.first { $0.id == sheet }
                }
            }
            #endif
        } catch {
            failure = EngineFailure.message(error)
        }
    }
}

/// A catalog extension: what it is, its state, and the action that fits it.
private struct ExtensionCatalogRow: View {
    @Bindable var store: StackStore
    let item: ComponentExtension
    let engineVersion: String
    let scope: String
    let install: () -> Void
    let remove: () -> Void

    var detail: String {
        var parts = [item.installed ?? item.version]
        parts.append(item.sqlNames.joined(separator: ", "))
        if !item.isInstalled { parts.append(Format.fileSizeText(item.downloadSize)) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                if !item.supported {
                    Chip(text: L("ext.notForVersion"), symbol: Symbols.warning, tint: Brand.warning,
                         help: String(format: L("ext.unsupported"), engineVersion))
                } else if let update = item.update {
                    Button(action: install) { Label(String(format: L("ext.updateTo"), update), systemImage: Symbols.update) }
                        .buttonStyle(.bordered).disabled(store.busy != nil)
                        .accessibilityIdentifier("\(scope).update")
                } else if item.isInstalled {
                    Chip(text: L("ext.installed"), symbol: Symbols.success, tint: Brand.success)
                } else {
                    Button(action: install) { Label(L("ext.install"), systemImage: Symbols.install) }
                        .buttonStyle(.bordered).disabled(store.busy != nil)
                        .accessibilityIdentifier("\(scope).install")
                }
                if item.isInstalled {
                    Menu {
                        Button(role: .destructive, action: remove) { Label(L("ext.remove"), systemImage: Symbols.delete) }
                            .disabled(store.busy != nil)
                    } label: {
                        Label(L("runtimes.actions"), systemImage: Symbols.more).labelStyle(.iconOnly)
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help(L("runtimes.actions"))
                    .accessibilityIdentifier("\(scope).menu")
                }
            }
        } label: {
            Text(verbatim: item.name)
            Text(detail).lineLimit(1).truncationMode(.middle).help(detail)
        }
        .accessibilityIdentifier(scope)
    }
}

/// The extensions «Instalar en esta versión…» installs, as the item of its sheet.
private struct CarryRequest: Identifiable {
    let items: [ComponentExtension]
    var id: String { items.map(\.id).joined(separator: ",") }
}
