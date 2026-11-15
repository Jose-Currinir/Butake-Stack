import SwiftUI

/// «Extensiones» of a database of Stack's PostgreSQL: the ones active in it, with «Desactivar…»
/// (which says first what goes with it), and the ones the service offers, with «Activar…». The
/// catalog's are installed in the service's page.
struct DatabaseExtensionsPanel: View {
    @Bindable var client: DatabaseClient
    let database: String
    @State private var state: DatabaseExtensions?
    @State private var failure: String?
    @State private var activating: OfferedExtension?
    @State private var deactivating: ActiveExtension?
    @State private var dependents: [String] = []
    @State private var search = ""
    var scope: String { "db.extensions" }
    var store: StackStore { client.store }

    var available: [OfferedExtension] {
        let active = Set(state?.active.map(\.name) ?? [])
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        return (state?.offered ?? []).filter { !active.contains($0.name) && (query.isEmpty || $0.name.contains(query)) }
    }

    var body: some View {
        Form {
            if let failure {
                Section { Notice(.warning, L("ext.db.unavailable"), detail: failure) }
            }
            if let state {
                Section {
                    ForEach(state.active) { item in
                        LabeledContent {
                            if item.name != "plpgsql" {
                                Button { Task { await askDeactivate(item) } } label: { Label(L("ext.deactivate"), systemImage: Symbols.remove) }
                                    .buttonStyle(.bordered)
                                    .accessibilityIdentifier("\(scope).deactivate.\(item.name)")
                            }
                        } label: {
                            Text(verbatim: item.name)
                            Text(item.version).monospacedDigit()
                        }
                        .accessibilityIdentifier("\(scope).active.\(item.name)")
                    }
                } header: {
                    Text(L("ext.db.active"))
                }
                Section {
                    FilterField(text: $search, identifier: "\(scope).search", prompt: L("ext.search"))
                    if available.isEmpty && !search.isEmpty {
                        ContentUnavailableView.search(text: search)
                    }
                    ForEach(available) { item in
                        LabeledContent {
                            Button { activating = item } label: { Label(L("ext.activate"), systemImage: Symbols.active) }
                                .buttonStyle(.bordered)
                                .accessibilityIdentifier("\(scope).activate.\(item.name)")
                        } label: {
                            Text(verbatim: item.name)
                            if let comment = item.comment { Text(comment).lineLimit(1).help(comment) }
                        }
                    }
                } header: {
                    Text(L("ext.db.available"))
                } footer: {
                    Text(L("ext.db.footer")).font(.uiCaption).foregroundStyle(.secondary).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if failure == nil {
                ProgressView().controlSize(.small)
            }
        }
        .formStyle(.grouped).themedScroll()
        .task(id: database) { await load() }
        .confirmationDialog(activating.map { String(format: L("ext.db.confirmActivate"), $0.name, database) } ?? "",
                            isPresented: Binding(get: { activating != nil }, set: { if !$0 { activating = nil } }), presenting: activating) { item in
            Button(L("ext.activate")) { Task { await activate(item) } }
                .accessibilityIdentifier("\(scope).confirmActivate")
            Button(L("common.cancel"), role: .cancel) {}
        } message: { _ in Text(L("ext.db.activateDetail")) }
        .confirmationDialog(deactivating.map { String(format: L("ext.db.confirmDeactivate"), $0.name, database) } ?? "",
                            isPresented: Binding(get: { deactivating != nil }, set: { if !$0 { deactivating = nil } }), presenting: deactivating) { item in
            Button(dependents.isEmpty ? L("ext.deactivate") : L("ext.db.deactivateAll"), role: .destructive) {
                Task { await deactivate(item) }
            }
            .accessibilityIdentifier("\(scope).confirmDeactivate")
            Button(L("common.cancel"), role: .cancel) {}
        } message: { _ in
            Text(dependents.isEmpty ? L("ext.db.deactivateDetail")
                                    : String(format: L("ext.db.deactivateLoses"), dependents.prefix(12).joined(separator: "\n"),
                                             dependents.count > 12 ? String(format: L("ext.db.andMore"), dependents.count - 12) : ""))
        }
    }

    private func load() async {
        do {
            state = try await store.databaseExtensions(database)
            failure = nil
        } catch {
            failure = EngineFailure.message(error)
        }
    }

    private func askDeactivate(_ item: ActiveExtension) async {
        dependents = (try? await store.extensionDependents(item.name, in: database)) ?? []
        deactivating = item
    }

    private func activate(_ item: OfferedExtension) async {
        await store.run(L("busy.saving")) { try await store.activateExtensions([item.name], in: database) }
        await load()
    }

    private func deactivate(_ item: ActiveExtension) async {
        let cascade = !dependents.isEmpty
        await store.run(L("busy.saving")) { try await store.deactivateExtension(item.name, in: database, cascade: cascade) }
        await load()
    }
}
