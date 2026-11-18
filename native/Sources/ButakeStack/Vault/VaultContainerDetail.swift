import AppKit
import SwiftUI

/// An app or a service, like a page of System Settings: its card, General (where it goes in the
/// master backup), Notas, and one section per part (Android, iOS, Servidor, Terceros, Otros) whose
/// items open in the detail (back with the toolbar's arrow). Files dropped on it are added where
/// their kind goes.
struct VaultContainerDetail: View {
    @Bindable var vault: VaultSession
    let container: VaultContainer

    var body: some View {
        let items = vault.visibleItems(in: container.id)
        let isApp = container.kind == .app
        Form {
            Section {
                HStack(spacing: 12) {
                    IconTile(symbol: isApp ? Symbols.app : Symbols.server, size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(container.title).font(.uiTitle3.weight(.semibold)).lineLimit(2).textSelection(.enabled)
                        Text(subtitle).font(container.bundleId == nil ? .uiCallout : .uiCallout.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            .textSelection(.enabled).help(subtitle)
                    }
                    Spacer(minLength: 8)
                    if let bundle = container.bundleId {
                        CopyButton(value: bundle, title: L("vault.copyBundle"), identifier: "vault.detail.copyBundle")
                    }
                }
                .accessibilityIdentifier("vault.detail.header")
            }
            Section(L("vault.general")) {
                InfoRow(title: L("vault.backupFolder"), value: folder, mono: true, copyID: "vault.detail.copyFolder")
                    .help(L("vault.backupFolderHelp"))
                if isApp { VaultProjectRow(vault: vault, container: container) }
            }
            if isApp {
                Section {
                    VaultSigningLink(vault: vault, container: container, identifier: "vault.detail.signing") { vault.signing = container.id }
                }
            }
            if let notes = VaultNotes.clean(container.notes, title: container.title) {
                Section(L("vault.notes")) {
                    Text(notes).textSelection(.enabled).accessibilityIdentifier("vault.detail.notes")
                }
            }
            if isApp {
                let general = items.filter { $0.section == nil }
                if !general.isEmpty { part(nil, general) }
                ForEach(VaultSection.allCases) { section in part(section, items.filter { $0.section == section }) }
            } else {
                // A service: what sits in it, then each of its accounts (the subfolders of the backup).
                let accounts = Set(items.compactMap(\.account)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                let own = items.filter { $0.account == nil }
                if !own.isEmpty || accounts.isEmpty { part(nil, own) }
                ForEach(accounts, id: \.self) { account in accountPart(account, items.filter { $0.account == account }) }
            }
        }
        .formStyle(.grouped)
        .font(.uiBody)
        .themedScroll()
        .accessibilityIdentifier("vault.detail")
        .vaultFileDrop(vault, container: container.id)
    }

    private var subtitle: String { container.kind == .app ? (container.bundleId ?? L("vault.noBundle")) : (container.subtitlePath ?? L("vault.serviceKind")) }
    private var folder: String { container.kind == .app ? container.folderName + "/" : "_SERVICIOS/\(container.name)/" }

    /// An account of a service: its items under its name (`tunnels › principal`), never a path.
    private func accountPart(_ account: String, _ items: [VaultItem]) -> some View {
        Section {
            ForEach(items) { item in VaultItemLink(vault: vault, item: item) }
        } header: {
            Text(VaultContainer.accountTitle(account))
                .accessibilityIdentifier("vault.section.account.\(account)")
        }
    }

    /// A part of the app or the service: its items, or where to drop files while it has none, and its
    /// «+» in the header.
    private func part(_ section: VaultSection?, _ items: [VaultItem]) -> some View {
        let title = VaultSection.title(section, app: container.kind == .app)
        let id = section?.rawValue ?? "general"
        return Section {
            if items.isEmpty {
                Label(L("vault.dropHere"), systemImage: Symbols.addFiles).font(.uiCallout).foregroundStyle(.secondary)
                    .accessibilityIdentifier("vault.section.\(id).empty")
            }
            ForEach(items) { item in
                VaultItemLink(vault: vault, item: item)
            }
        } header: {
            HStack {
                Text(title)
                Spacer()
                Button { VaultActions.chooseFiles(vault, container: container.id, section: section) } label: {
                    Label(String(format: L("vault.addTo"), title), systemImage: Symbols.add).labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless).help(String(format: L("vault.addTo"), title)).accessibilityIdentifier("vault.section.\(id).add")
            }
        }
    }
}

/// Everything expired or about to, by app or service.
struct VaultExpiringDetail: View {
    @Bindable var vault: VaultSession
    var body: some View {
        let items = vault.expiringItems.filter(vault.matches)
        let containers = vault.index.containers.filter { container in items.contains { $0.container == container.id } }
        Form {
            ForEach(containers) { container in
                Section(container.title) {
                    ForEach(items.filter { $0.container == container.id }) { item in
                        VaultItemLink(vault: vault, item: item)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .font(.uiBody)
        .themedScroll()
        .overlay {
            if items.isEmpty { ContentUnavailableView(L("vault.expiringNone"), systemImage: Symbols.expiring) }
        }
        .accessibilityIdentifier("vault.expiring")
    }
}

/// An item in a list: its kind's tile, name, kind, stage, expiry and anything wrong with it.
struct VaultItemRow: View {
    @Bindable var vault: VaultSession
    let item: VaultItem
    @State private var confirmingDelete = false
    var body: some View {
        HStack(spacing: 10) {
            IconTile(symbol: item.kind.symbol, color: VaultStyle.tint(item.kind), size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(.uiBody.weight(.medium)).lineLimit(1).truncationMode(.middle).help(item.name)
                Text(L("vault.kind.\(item.kind.rawValue)")).font(.uiCaption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if let kind = item.environment.envKind {
                Chip(text: item.environment.title, symbol: kind.symbol, tint: kind.color)
            }
            if let expires = item.metadata.expires { Chip(expiry: item, date: expires) }
            if item.metadata.problem != nil {
                Image(systemName: Symbols.warning).foregroundStyle(Brand.warning)
                    .help(L(item.metadata.problem ?? "")).accessibilityLabel(L(item.metadata.problem ?? ""))
            }
        }
        .accessibilityIdentifier("vault.item.\(item.name)")
        .contextMenu {
            Button { vault.sheet = .item(item) } label: { Label(L("vault.editItemEllipsis"), systemImage: Symbols.edit) }
            ForEach(item.files) { file in
                Button { Task { await vault.saveFile(file, of: item) } } label: { Label(String(format: L("vault.saveFile"), file.name), systemImage: Symbols.dump) }
            }
            Divider()
            Button(role: .destructive) { confirmingDelete = true } label: { Label(L("vault.deleteItemEllipsis"), systemImage: Symbols.delete) }
        }
        .confirmationDialog(String(format: L("vault.deleteItemTitle"), item.name), isPresented: $confirmingDelete) {
            Button(L("common.delete"), role: .destructive) { VaultActions.delete(item, vault) }
            Button(L("common.cancel"), role: .cancel) {}
        } message: { Text(L("vault.deleteItemDetail")) }
    }
}

/// A row that opens its item, like a row of System Settings that leads to a page (the same kind of
/// row as `ProjectLinkRow`): the whole row is the button, with the chevron at its end.
struct VaultItemLink: View {
    @Bindable var vault: VaultSession
    let item: VaultItem
    var body: some View {
        Button { vault.inspected = item.id } label: {
            HStack(spacing: 8) {
                VaultItemRow(vault: vault, item: item)
                Image(systemName: Symbols.forward).font(.uiCaption).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(HighlightButtonStyle())
        .help(L("vault.openItem"))
        .accessibilityIdentifier("vault.item.\(item.name).open")
    }
}

/// Copies a value that is not secret (an identifier, a folder), at the end of a row.
struct CopyButton: View {
    let value: String
    let title: String
    let identifier: String
    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
        } label: { Label(title, systemImage: Symbols.copy).labelStyle(.iconOnly) }
            .buttonStyle(.borderless).help(title).accessibilityIdentifier(identifier)
    }
}

/// The notes of an app or service read like text: the README they came from loses its Markdown
/// heading marks, and a first heading that only repeats the name is left out.
enum VaultNotes {
    static func clean(_ notes: String, title: String) -> String? {
        var lines = notes.components(separatedBy: .newlines).map { line -> String in
            var line = line
            while line.hasPrefix("#") { line.removeFirst() }
            return line.trimmingCharacters(in: .whitespaces)
        }
        if let first = lines.first(where: { !$0.isEmpty }), first.caseInsensitiveCompare(title) == .orderedSame,
           let index = lines.firstIndex(of: first) { lines.remove(at: index) }
        let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

extension VaultActions {
    static func delete(_ item: VaultItem, _ vault: VaultSession) {
        do {
            try vault.delete(item)
            if vault.inspected == item.id { vault.inspected = nil }
        } catch { vault.message = L((error as? VaultError)?.messageKey ?? "vault.error.io") }
    }
}

/// One solid tile color per kind, as in System Settings (store keys and certificates in the system's
/// colors, Android in its own).
enum VaultStyle {
    @MainActor static func tint(_ kind: VaultItemKind) -> Color {
        switch kind {
        case .androidKeystore, .googleServices: Tech.of("android").brand
        case .iosCertificate, .provisioningProfile, .appStoreKey, .googleServiceInfo, .certificateKey: Color.blue
        case .apnsKey: Color.red
        case .serviceAccount: Color.purple
        case .sshKey, .token: TileColor.security
        case .envFile: TileColor.terminal
        case .note, .file: TileColor.system
        }
    }
}
