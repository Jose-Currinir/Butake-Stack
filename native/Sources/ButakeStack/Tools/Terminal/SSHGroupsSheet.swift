import SwiftUI

/// «Grupos y etiquetas…»: every group and tag of the hosts with how many use it, to rename, merge
/// or delete them at once. Each change applies when it is confirmed; «Listo» closes the sheet.
struct SSHGroupsSheet: View {
    @Bindable var terminal: SSHTerminal
    @State private var naming: SSHNameRequest?
    @State private var deleting: Item?
    enum Item: Hashable { case group(String), tag(String) }

    var body: some View {
        SheetFrame(title: L("ssh.groups.title"), symbol: Symbols.folder, note: L("ssh.groups.note"), width: 500, height: 480,
                   actionTitle: L("common.done"), actionID: "ssh.groups.done", action: { true }) {
            Form {
                Section(L("ssh.groups.groups")) {
                    let groups = terminal.groups.filter { !$0.isEmpty }
                    if groups.isEmpty {
                        Text(L("ssh.groups.noGroups")).foregroundStyle(.secondary)
                    }
                    ForEach(groups, id: \.self) { group in
                        row(group, symbol: Symbols.folder, count: terminal.hostCount(group: group), id: "group.\(group)") {
                            menu(.group(group), others: groups.filter { $0 != group })
                        }
                    }
                    if terminal.hostCount(group: "") > 0 {
                        row(L("ssh.noGroup"), symbol: Symbols.folder, count: terminal.hostCount(group: ""), id: "group.none") { EmptyView() }
                    }
                }
                Section(L("ssh.tags")) {
                    if terminal.tags.isEmpty {
                        Text(L("ssh.groups.noTags")).foregroundStyle(.secondary)
                    }
                    ForEach(terminal.tags, id: \.self) { tag in
                        row(tag, symbol: Symbols.tags, count: terminal.hostCount(tag: tag), id: "tag.\(tag)") {
                            menu(.tag(tag), others: terminal.tags.filter { $0.lowercased() != tag.lowercased() })
                        }
                    }
                }
            }
            .formStyle(.grouped).themedScroll()
            .frame(minHeight: 300)
        }
        .sheet(item: $naming) { request in SSHNameSheet(request: request, terminal: terminal).themedSheet() }
        .confirmationDialog(deleteTitle, isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { item in
            Button(L(isGroup(item) ? "ssh.groups.delete" : "ssh.groups.deleteTag"), role: .destructive) {
                Task {
                    switch item {
                    case .group(let group): await terminal.deleteGroup(group)
                    case .tag(let tag): await terminal.deleteTag(tag)
                    }
                }
            }
            .accessibilityIdentifier("ssh.groups.confirmDelete")
            Button(L("common.cancel"), role: .cancel) {}
        } message: { item in
            switch item {
            case .group(let group): Text(String(format: L("ssh.groups.deleteDetail"), terminal.hostCount(group: group)))
            case .tag(let tag): Text(String(format: L("ssh.groups.deleteTagDetail"), terminal.hostCount(tag: tag)))
            }
        }
    }

    private var deleteTitle: String {
        switch deleting {
        case .group(let group): String(format: L("ssh.groups.deleteConfirm"), group)
        case .tag(let tag): String(format: L("ssh.groups.deleteTagConfirm"), tag)
        case nil: ""
        }
    }
    private func isGroup(_ item: Item) -> Bool { if case .group = item { true } else { false } }

    private func row<Actions: View>(_ name: String, symbol: String, count: Int, id: String, @ViewBuilder actions: () -> Actions) -> some View {
        LabeledContent {
            HStack(spacing: 8) {
                Text(String(format: L("ssh.hostCount"), count)).foregroundStyle(.secondary).monospacedDigit()
                actions()
            }
        } label: {
            Label { Text(name).lineLimit(1).truncationMode(.tail) } icon: { IconTile(symbol: symbol, size: 22) }
        }
        .accessibilityIdentifier("ssh.groups.\(id)")
    }

    private func menu(_ item: Item, others: [String]) -> some View {
        Menu {
            Button { naming = rename(item) } label: { Label(L("ssh.groups.renameEllipsis"), systemImage: Symbols.edit) }
                .accessibilityIdentifier("ssh.groups.menu.rename")
            if !others.isEmpty {
                Menu {
                    ForEach(others, id: \.self) { other in
                        Button(other) { Task { await merge(item, into: other) } }
                    }
                } label: { Label(L("ssh.groups.merge"), systemImage: Symbols.forward) }
                .accessibilityIdentifier("ssh.groups.menu.merge")
            }
            Divider()
            Button(role: .destructive) { deleting = item } label: {
                Label(L(isGroup(item) ? "ssh.groups.deleteEllipsis" : "ssh.groups.deleteTagEllipsis"), systemImage: Symbols.delete)
            }
            .accessibilityIdentifier("ssh.groups.menu.delete")
        } label: {
            Label(L("ssh.groups.actions"), systemImage: Symbols.more).labelStyle(.iconOnly)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help(L("ssh.groups.actions"))
    }

    private func rename(_ item: Item) -> SSHNameRequest {
        switch item {
        case .group(let group): .group(group)
        case .tag(let tag): .tag(tag)
        }
    }
    private func merge(_ item: Item, into other: String) async {
        switch item {
        case .group(let group): await terminal.renameGroup(group, to: other)
        case .tag(let tag): await terminal.renameTag(tag, to: other)
        }
    }
}

/// A name asked in a small sheet: renaming a group or a tag, or the group a host goes to.
enum SSHNameRequest: Identifiable {
    case group(String)
    case tag(String)
    /// A new group for the host being edited; it exists once the host is saved in it.
    case newGroup((String) -> Void)
    var id: String {
        switch self {
        case .group(let name): "group-" + name
        case .tag(let name): "tag-" + name
        case .newGroup: "new"
        }
    }
}

struct SSHNameSheet: View {
    let request: SSHNameRequest
    let terminal: SSHTerminal
    @State private var name: String
    init(request: SSHNameRequest, terminal: SSHTerminal) {
        self.request = request
        self.terminal = terminal
        switch request {
        case .group(let value), .tag(let value): _name = State(initialValue: value)
        case .newGroup: _name = State(initialValue: "")
        }
    }
    private var trimmed: String { name.trimmingCharacters(in: .whitespaces) }
    private var original: String? {
        switch request {
        case .group(let value), .tag(let value): value
        case .newGroup: nil
        }
    }
    private var isTag: Bool { if case .tag = request { true } else { false } }
    /// Renaming onto a name in use merges both: the sheet says so before.
    private var merges: Bool {
        guard let original, trimmed != original else { return false }
        return isTag ? terminal.tags.contains { $0.lowercased() == trimmed.lowercased() && $0 != original }
            : terminal.groups.contains(trimmed)
    }
    private var valid: Bool {
        !trimmed.isEmpty && trimmed != original && (isTag ? trimmed.count <= 30 && !trimmed.contains(",") : trimmed.count <= 60)
    }
    private var title: String {
        switch request {
        case .group: L("ssh.groups.renameGroup")
        case .tag: L("ssh.groups.renameTag")
        case .newGroup: L("ssh.groups.new")
        }
    }

    var body: some View {
        SheetFrame(title: title, symbol: isTag ? Symbols.tags : Symbols.folder,
                   note: merges ? L(isTag ? "ssh.groups.mergeTagNote" : "ssh.groups.mergeNote") : nil, width: 400,
                   actionTitle: original == nil ? L("common.create") : L(merges ? "ssh.groups.merge" : "ssh.groups.rename"),
                   actionID: "ssh.name.save", canAct: valid, cancelID: "ssh.name.cancel") {
            switch request {
            case .group(let value): await terminal.renameGroup(value, to: trimmed)
            case .tag(let value): await terminal.renameTag(value, to: trimmed)
            case .newGroup(let pick): pick(SSHHost.cleanGroup(trimmed))
            }
            return true
        } content: {
            Form {
                TextField(L("common.name"), text: $name).formField(L("common.name"))
                    .accessibilityIdentifier("ssh.name.field")
            }
            .formStyle(.grouped).themedScroll()
            .frame(minHeight: 70)
        }
    }
}
