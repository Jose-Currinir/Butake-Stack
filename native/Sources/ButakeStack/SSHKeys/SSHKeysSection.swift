import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Ajustes › Claves SSH: the keys kept by Stack. Import a `.pem` once (button or drag and drop),
/// give it a name, a description and a group, and later just pick it in a connection. The key's
/// content never shows; only its type and fingerprint.
struct SSHKeysSection: View {
    @State private var importing: [URL] = []
    @State private var editing: SSHKey?
    @State private var dropping = false
    @State private var generating = false
    @Bindable var keyring = SSHKeyring.shared
    var groups: [String] {
        Array(Set(keyring.sshKeys.map(\.group))).sorted { a, b in
            a.isEmpty ? false : b.isEmpty ? true : a.localizedCaseInsensitiveCompare(b) == .orderedAscending
        }
    }
    var body: some View {
        Form {
            Section {
                LabeledContent {
                    HStack(spacing: 8) {
                        Button { generating = true } label: { Label(L("ssh.keys.generateEllipsis"), systemImage: Symbols.generateKey) }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("ssh.keys.generate")
                        Button { chooseFiles() } label: { Label(L("ssh.keys.importEllipsis"), systemImage: Symbols.add) }
                            .buttonStyle(.borderedProminent).accessibilityIdentifier("ssh.keys.import")
                    }
                } label: {
                    Text(L("ssh.keys.subtitle"))
                }
            } footer: {
                if keyring.sshKeys.isEmpty { SettingsFooter(L("ssh.keys.privacy")) }
            }
            if keyring.sshKeys.isEmpty {
                Section {
                    ContentUnavailableView {
                        Label(L("ssh.keys.empty"), systemImage: Symbols.hostKey)
                    } description: {
                        Text(L("ssh.keys.emptyHelp"))
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            ForEach(groups, id: \.self) { group in
                Section {
                    ForEach(keyring.sshKeys.filter { $0.group == group }) { key in
                        KeyRow(key: key) { editing = key }
                    }
                } header: {
                    Text(group.isEmpty ? L("ssh.keys.noGroup") : group)
                } footer: {
                    if group == groups.last { SettingsFooter(L("ssh.keys.privacy")) }
                }
            }
        }
        .formStyle(.grouped).themedScroll()
        .overlay {
            if dropping {
                RoundedRectangle(cornerRadius: Radius.card).strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6]))
                    .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: Radius.card))
                    .overlay(Label(L("ssh.keys.dropHere"), systemImage: Symbols.dump).font(.uiHeadline).foregroundStyle(Color.accentColor))
                    .padding(10)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url { Task { @MainActor in importing.append(url) } }
                }
            }
            return true
        }
        .task {
            await keyring.load()
            await keyring.loadConnectionUsers()
            if StackStore.shared.pluginEnabled("ssh-terminal") { await SSHTerminal.shared.load() }
        }
        .sheet(item: Binding(get: { importing.first.map(ImportTarget.init) }, set: { if $0 == nil, !importing.isEmpty { importing.removeFirst() } })) { target in
            KeyForm(title: L("ssh.keys.importTitle"), groups: groups.filter { !$0.isEmpty },
                    initial: SSHKey(id: "", name: target.url.deletingPathExtension().lastPathComponent, description: "", group: "", kind: "", fingerprint: "", added: 0),
                    file: target.url.lastPathComponent) { key in
                await keyring.importKey(target.url, name: key.name, description: key.description, group: key.group)
            }
            .themedSheet()
        }
        .sheet(item: $editing) { key in
            KeyForm(title: L("ssh.keys.editTitle"), groups: groups.filter { !$0.isEmpty }, initial: key, file: nil) { updated in
                await keyring.updateKey(updated); return true
            }
            .themedSheet()
        }
        .sheet(isPresented: $generating) { GenerateKeyForm(groups: groups.filter { !$0.isEmpty }).themedSheet() }
        .sheet(item: $keyring.prompt) { request in PassphraseSheet(request: request).themedSheet() }
        #if DEBUG
        .task { if QAHooks.sshKeysGenerate { generating = true } }
        #endif
    }
    struct ImportTarget: Identifiable { let url: URL; var id: String { url.path } }

    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = L("ssh.keys.panelMessage")
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        if panel.runModal() == .OK { importing.append(contentsOf: panel.urls) }
    }
}

private struct KeyRow: View {
    let key: SSHKey
    let edit: () -> Void
    @Bindable var keyring = SSHKeyring.shared
    @State private var confirmDelete = false
    var body: some View {
        let used = keyring.users(of: key, hosts: SSHTerminal.shared.hosts)
        LabeledContent {
            HStack(spacing: 8) {
                Menu {
                    Button(L("ssh.keys.copyPublic")) { Task { await keyring.copyPublicKey(key.id) } }
                    Button(L("ssh.keys.exportPublic")) { Task { await keyring.exportPublicKey(key) } }
                    if keyring.encrypted(key.id) {
                        Divider()
                        if keyring.loaded(key.id) {
                            Button(L("ssh.keys.unloadAgent")) { Task { await keyring.unload(key.id) } }
                        } else {
                            Button(L("ssh.keys.loadAgent")) { Task { _ = await keyring.ensureAgent(key.id) } }
                        }
                        if SSHKeyVault.has(key.id) {
                            Button(L("ssh.keys.forgetPassphrase")) { SSHKeyVault.delete(key.id); StackStore.shared.notify(L("ssh.keys.passphraseForgotten")) }
                        }
                    }
                } label: { Label(L("ssh.keys.publicMenu"), systemImage: Symbols.share).labelStyle(.iconOnly) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help(L("ssh.keys.publicMenu")).accessibilityIdentifier("ssh.keys.public.\(key.id)")
                Button(action: edit) { Label(L("ssh.keys.edit"), systemImage: Symbols.edit).labelStyle(.iconOnly) }
                    .buttonStyle(.borderless).help(L("ssh.keys.edit"))
                    .accessibilityIdentifier("ssh.keys.edit.\(key.id)")
                Button { confirmDelete = true } label: { Label(L("ssh.keys.delete"), systemImage: Symbols.delete).labelStyle(.iconOnly) }
                    .buttonStyle(.borderless).help(used.isEmpty ? L("ssh.keys.delete") : L("ssh.keys.inUse")).disabled(!used.isEmpty)
                    .accessibilityIdentifier("ssh.keys.delete.\(key.id)")
            }
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 3) {
                    Text(key.name)
                    if !key.description.isEmpty {
                        Text(key.description).foregroundStyle(.secondary)
                    }
                    Text(verbatim: "\(key.kind) · \(key.fingerprint)").font(.uiCaption.monospaced()).foregroundStyle(.tertiary)
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled).help(key.fingerprint)
                    if !used.isEmpty {
                        Text(String(format: L("ssh.keys.usedBy"), used.joined(separator: ", "))).font(.uiCaption).foregroundStyle(.secondary)
                    }
                    if keyring.encrypted(key.id) {
                        HStack(spacing: 8) {
                            Label(L("ssh.keys.protected"), systemImage: Symbols.locked).font(.uiCaption).foregroundStyle(.secondary)
                            if keyring.loaded(key.id) {
                                Label(L("ssh.keys.inAgent"), systemImage: Symbols.success).font(.uiCaption).foregroundStyle(Brand.successText)
                            }
                            if SSHKeyVault.has(key.id) {
                                Label(L("ssh.keys.inKeychain"), systemImage: Symbols.keychain).font(.uiCaption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } icon: {
                IconTile(symbol: Symbols.key, size: 22)
            }
        }
        .confirmationDialog(String(format: L("ssh.keys.deleteConfirm"), key.name), isPresented: $confirmDelete) {
            Button(L("ssh.keys.delete"), role: .destructive) {
                Task { await keyring.deleteKey(key) }
            }
            Button(L("common.cancel"), role: .cancel) {}
        }
    }
}


/// The group of a key: one of the existing key groups, none, or a new one. Key groups only order the
/// keys in Ajustes; they are not the groups of the SSH terminal's hosts (`SSHHost.group`).
private struct KeyGroupPicker: View {
    @Binding var group: String
    let groups: [String]
    @State private var naming = false
    @State private var typed = ""
    private static let newTag = "\u{0}new"
    var body: some View {
        Picker(L("ssh.keys.group"), selection: Binding(get: { group }, set: { value in
            if value == Self.newTag { typed = ""; naming = true } else { group = value }
        })) {
            Text(L("ssh.keys.noGroup")).tag("")
            ForEach(Array(Set(groups + [group]).filter { !$0.isEmpty }).sorted(), id: \.self) { Text($0).tag($0) }
            Divider()
            Text(L("ssh.keys.newGroupEllipsis")).tag(Self.newTag)
        }
        .help(L("ssh.keys.groupHelp"))
        .accessibilityIdentifier("ssh.keys.form.group")
        .alert(L("ssh.keys.newGroup"), isPresented: $naming) {
            TextField(L("ssh.keys.groupPlaceholder"), text: $typed).accessibilityIdentifier("ssh.keys.form.newGroup")
            Button(L("common.cancel"), role: .cancel) {}
            Button(L("common.create")) { group = String(typed.trimmingCharacters(in: .whitespaces).prefix(60)) }
                .disabled(typed.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }
}

/// Name, description and group of a key (new or existing).
private struct KeyForm: View {
    let title: String
    let groups: [String]
    let file: String?
    let save: (SSHKey) async -> Bool
    @State private var key: SSHKey
    init(title: String, groups: [String], initial: SSHKey, file: String?, save: @escaping (SSHKey) async -> Bool) {
        self.title = title
        self.groups = groups
        self.file = file
        self.save = save
        _key = State(initialValue: initial)
    }
    var body: some View {
        SheetFrame(title: title, symbol: Symbols.key, detail: file, width: 480, actionTitle: file == nil ? L("common.save") : L("ssh.keys.importButton"),
                   actionID: "ssh.keys.form.save", canAct: !key.name.trimmingCharacters(in: .whitespaces).isEmpty, cancelID: "ssh.keys.form.cancel") {
            await save(key)
        } content: {
            Form {
                TextField(L("ssh.keys.namePlaceholder"), text: $key.name).formField(L("common.name")).accessibilityIdentifier("ssh.keys.form.name")
                TextField(L("ssh.keys.descriptionPlaceholder"), text: $key.description, axis: .vertical).lineLimit(1...3)
                    .formField(L("ssh.keys.description")).accessibilityIdentifier("ssh.keys.form.description")
                KeyGroupPicker(group: $key.group, groups: groups)
            }
            .formStyle(.grouped).themedScroll()
            .frame(minHeight: 150)
        }
    }
}

/// A new ed25519 key made by Stack (ssh-keygen): optional passphrase, kept in the Keychain if
/// the user wants; the public half can then be copied to the server's authorized_keys.
private struct GenerateKeyForm: View {
    let groups: [String]
    @State private var name = ""
    @State private var description = ""
    @State private var group = ""
    @State private var comment = "butake-stack"
    @State private var passphrase = ""
    @State private var confirmation = ""
    @State private var remember = true
    var commentValid: Bool { comment.count <= 64 && comment.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "@._-".contains($0)) } }
    var valid: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty && passphrase == confirmation && commentValid }
    var body: some View {
        SheetFrame(title: L("ssh.keys.generateTitle"), symbol: Symbols.generateKey, detail: L("ssh.keys.generateKind"), note: L("ssh.keys.generateHelp"),
                   width: 520, actionTitle: L("ssh.keys.generateButton"), actionID: "ssh.keys.generate.save", canAct: valid,
                   cancelID: "ssh.keys.generate.cancel") {
            let ok = await SSHKeyring.shared.generate(name: name, description: description, group: group, comment: comment, passphrase: passphrase, remember: remember)
            passphrase = ""
            confirmation = ""
            return ok
        } content: {
            Form {
                Section {
                    TextField(L("ssh.keys.namePlaceholder"), text: $name).formField(L("common.name")).accessibilityIdentifier("ssh.keys.generate.name")
                    TextField(L("ssh.keys.descriptionPlaceholder"), text: $description).formField(L("ssh.keys.description"))
                        .accessibilityIdentifier("ssh.keys.generate.description")
                    KeyGroupPicker(group: $group, groups: groups)
                    TextField(L("ssh.keys.comment"), text: $comment).formField(L("ssh.keys.comment")).accessibilityIdentifier("ssh.keys.generate.comment")
                } footer: {
                    if !commentValid { Text(L("ssh.keys.commentInvalid")).font(.uiCaption).foregroundStyle(Brand.dangerText) }
                }
                Section {
                    SecureField(L("ssh.keys.passphraseOptional"), text: $passphrase).formField(L("ssh.keys.passphrase"))
                        .accessibilityIdentifier("ssh.keys.generate.passphrase")
                    SecureField(L("ssh.keys.passphraseRepeat"), text: $confirmation).formField(L("ssh.keys.passphraseRepeat"))
                        .accessibilityIdentifier("ssh.keys.generate.confirm")
                    if !passphrase.isEmpty {
                        Toggle(L("ssh.keys.rememberPassphrase"), isOn: $remember).accessibilityIdentifier("ssh.keys.generate.remember")
                    }
                } footer: {
                    if passphrase != confirmation && !confirmation.isEmpty {
                        Text(L("ssh.keys.passphraseMismatch")).font(.uiCaption).foregroundStyle(Brand.dangerText)
                    }
                }
            }
            .formStyle(.grouped).themedScroll()
            .frame(minHeight: 300)
        }
    }
}
