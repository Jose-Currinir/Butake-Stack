import AppKit
import SwiftUI

/// Name prompt for a new or renamed folder.
struct GroupNameSheet: View {
    let store: StackStore
    let naming: GroupNaming
    @State private var name = ""
    @FocusState private var focused: Bool
    var isNew: Bool { if case .new = naming { true } else { false } }
    var clean: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    var body: some View {
        SheetFrame(title: isNew ? L("groups.new") : L("groups.rename"), symbol: isNew ? Symbols.newFolder : Symbols.folder,
                   detail: L("groups.hint"), width: 400,
                   actionTitle: isNew ? L("common.create") : L("common.save"), actionID: "groups.save", canAct: !clean.isEmpty,
                   cancelID: "groups.cancel") {
            save()
            return true
        } content: {
            TextField(L("groups.namePlaceholder"), text: $name)
                .textFieldStyle(.roundedBorder).focused($focused)
                .accessibilityIdentifier("groups.name")
        }
        .onAppear {
            if case .rename(let id) = naming { name = store.groups.first { $0.id == id }?.name ?? "" }
            focused = true
        }
    }
    func save() {
        switch naming {
        case .new(let sites): store.createGroup(named: clean, with: sites)
        case .rename(let id): store.renameGroup(id, to: clean)
        }
    }
}
