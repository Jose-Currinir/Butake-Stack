import SwiftUI

/// An item, in the detail column: what it is, its fields (secrets hidden until revealed, which asks for
/// Touch ID or the Mac's password), its files, what was read from them and its notes.
struct VaultItemDetail: View {
    @Bindable var vault: VaultSession
    let item: VaultItem
    @State private var confirmingDelete = false

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    IconTile(symbol: item.kind.symbol, color: VaultStyle.tint(item.kind), size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name).font(.uiTitle3.weight(.semibold)).lineLimit(2).truncationMode(.middle)
                            .textSelection(.enabled)
                        Text(L("vault.kind.\(item.kind.rawValue)")).font(.uiCallout).foregroundStyle(.secondary)
                    }
                }
                retiredNotice
                if let problem = item.metadata.problem {
                    Notice(.warning, L(problem))
                }
            }
            Section {
                LabeledContent(L("vault.environment"), value: item.environment.title)
                if let section = item.section { LabeledContent(L("vault.section"), value: section.title) }
                if let expires = item.metadata.expires {
                    LabeledContent(L("vault.expires")) { Chip(expiry: item, date: expires) }
                }
            }
            if !item.fields.isEmpty {
                Section(L("vault.fields")) {
                    ForEach(Array(item.fields.enumerated()), id: \.element.id) { VaultFieldRow(vault: vault, item: item, field: $1, position: $0) }
                }
            }
            if !item.files.isEmpty {
                Section(L("vault.files")) {
                    ForEach(item.files) { file in
                        LabeledContent {
                            Button { Task { await vault.saveFile(file, of: item) } } label: {
                                Label(String(format: L("vault.saveFile"), file.name), systemImage: Symbols.dump).labelStyle(.iconOnly)
                            }
                            .buttonStyle(.borderless).help(L("vault.saveFileHelp"))
                            .accessibilityIdentifier("vault.detail.file.\(file.name).save")
                        } label: {
                            Text(file.name).lineLimit(1).truncationMode(.middle).help(file.name)
                            Text("\(Format.fileSizeText(Int64(file.size))) · SHA-256 \(file.sha256.prefix(12))…")
                                .font(.uiCaption.monospaced()).foregroundStyle(.secondary).help(file.sha256).textSelection(.enabled)
                        }
                    }
                }
            }
            let entries = item.metadata.entries.filter { $0.key != "vault.meta.keys" }
            if !entries.isEmpty {
                Section(L("vault.readFromFile")) {
                    ForEach(entries, id: \.self) { entry in
                        InfoRow(title: L(entry.key), value: entry.key == "vault.meta.profileType" ? L("vault.profileType.\(entry.value)") : entry.value, lines: 2)
                    }
                }
            }
            if !item.notes.isEmpty {
                Section(L("vault.notes")) {
                    Text(item.notes).textSelection(.enabled)
                }
            }
            Section {
                HStack {
                    Button { vault.sheet = .item(item) } label: { Label(L("vault.editItemEllipsis"), systemImage: Symbols.edit) }
                        .buttonStyle(.bordered).accessibilityIdentifier("vault.detail.edit")
                    Spacer()
                    Button(role: .destructive) { confirmingDelete = true } label: { Label(L("vault.deleteItemEllipsis"), systemImage: Symbols.delete) }
                        .buttonStyle(.bordered).accessibilityIdentifier("vault.detail.delete")
                }
            }
        }
        .formStyle(.grouped)
        .font(.uiBody)
        .themedScroll()
        .accessibilityIdentifier("vault.itemDetail")
        .simultaneousGesture(TapGesture().onEnded { vault.touch() })
        .confirmationDialog(String(format: L("vault.deleteItemTitle"), item.name), isPresented: $confirmingDelete) {
            Button(L("common.delete"), role: .destructive) { VaultActions.delete(item, vault) }
            Button(L("common.cancel"), role: .cancel) {}
        } message: { Text(L("vault.deleteItemDetail")) }
    }

    /// The two kinds the vault no longer creates say where they live now; the way there goes on its
    /// own line under the notice, so it is never cut at a large text size.
    @ViewBuilder private var retiredNotice: some View {
        if item.kind.isRetired {
            VStack(alignment: .leading, spacing: 8) {
                Notice(.info, L("vault.retired.\(item.kind.rawValue)"))
                HStack(spacing: 8) {
                    if item.kind == .sshKey {
                        Button { vault.sheet = .moveToKeys(item.id) } label: { Label(L("vault.move.key.button"), systemImage: Symbols.key) }
                            .buttonStyle(.borderedProminent).help(L("vault.move.key.help")).accessibilityIdentifier("vault.detail.moveToKeys")
                        Button { SettingsRouter.shared.open(.keys) } label: { Label(L("settings.manageKeys"), systemImage: Symbols.settings) }
                            .buttonStyle(.bordered).help(L("vault.openKeysHelp")).accessibilityIdentifier("vault.detail.openKeys")
                    } else {
                        Button { vault.sheet = .moveToEnvironments(item.id) } label: { Label(L("vault.move.env.button"), systemImage: Symbols.environments) }
                            .buttonStyle(.borderedProminent).help(L("vault.move.env.help")).accessibilityIdentifier("vault.detail.moveToEnvironments")
                    }
                }
            }
        }
    }
}

/// A field: its name and variable, its value (a secret stays hidden until revealed) and, at the end
/// of the row, reveal and copy.
private struct VaultFieldRow: View {
    @Bindable var vault: VaultSession
    let item: VaultItem
    let field: VaultField
    /// Its place in the item, for a stable identifier (custom fields share their role).
    let position: Int
    var body: some View {
        let shown = vault.revealed[field.id]
        LabeledContent {
            HStack(spacing: 6) {
                Group {
                    if field.value.isEmpty { Text(L("vault.field.empty")).foregroundStyle(.tertiary) }
                    else if !field.secret { Text(field.value).textSelection(.enabled) }
                    else if let shown { Text(shown).textSelection(.enabled) }
                    else { Text(String(repeating: "•", count: 10)).foregroundStyle(.secondary).accessibilityLabel(L("vault.hidden")) }
                }
                .font(.uiCallout.monospaced()).lineLimit(1).truncationMode(.middle)
                if field.secret && !field.value.isEmpty {
                    Button {
                        if shown == nil { Task { await vault.reveal(field, of: item) } } else { vault.hide(field) }
                    } label: {
                        Label(shown == nil ? L("vault.reveal") : L("vault.hide"), systemImage: shown == nil ? Symbols.reveal : Symbols.hide)
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless).help(shown == nil ? L("vault.reveal") : L("vault.hide"))
                    .accessibilityIdentifier("vault.detail.field.\(position).reveal")
                }
                if !field.value.isEmpty {
                    Button { Task { await vault.copy(field, of: item) } } label: { Label(L("vault.copy"), systemImage: Symbols.copy).labelStyle(.iconOnly) }
                        .buttonStyle(.borderless).help(L("vault.copy"))
                        .accessibilityIdentifier("vault.detail.field.\(position).copy")
                }
            }
        } label: {
            Text(field.title.isEmpty ? L("vault.field.untitled") : field.title)
            if let env = field.envVar, !env.isEmpty { Text(env).font(.uiCaption.monospaced()) }
        }
    }
}
