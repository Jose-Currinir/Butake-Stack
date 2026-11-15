import SwiftUI

/// «Extensiones» of a new PostgreSQL database: the ones the service has installed (bundled and
/// from the catalog), ticked to be activated as soon as the database exists.
struct ExtensionPickerSection: View {
    let store: StackStore
    @Binding var selected: Set<String>
    @State private var names: [String] = []
    let scope: String

    var body: some View {
        Section {
            if names.isEmpty {
                Text(L("ext.picker.none")).foregroundStyle(.secondary)
            }
            ForEach(names, id: \.self) { name in
                Toggle(isOn: Binding(get: { selected.contains(name) },
                                     set: { if $0 { selected.insert(name) } else { selected.remove(name) } })) {
                    Text(verbatim: name)
                }
                .accessibilityIdentifier("\(scope).\(name)")
            }
        } header: {
            Text(L("ext.title"))
        } footer: {
            Text(L("ext.picker.footer")).font(.uiCaption).foregroundStyle(.secondary).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
        }
        .task {
            names = ((try? await store.extensionCatalog())?.activatable ?? []).filter { $0 != "plpgsql" }
        }
    }
}
