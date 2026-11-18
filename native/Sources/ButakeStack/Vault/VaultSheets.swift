import AppKit
import SwiftUI

struct VaultSheetHost: View {
    @Bindable var vault: VaultSession
    let sheet: VaultSession.Sheet
    var body: some View {
        switch sheet {
        case .newContainer(let kind): VaultContainerSheet(vault: vault, original: nil, kind: kind)
        case .editContainer(let id): VaultContainerSheet(vault: vault, original: vault.index.container(id), kind: vault.index.container(id)?.kind ?? .app)
        case .item(let item): VaultItemSheet(vault: vault, original: item)
        case .exportArchive(let id): VaultExportSheet(vault: vault, container: id)
        case .importArchive(let url): VaultImportArchiveSheet(vault: vault, url: url)
        case .importFolder(let groups, let linked): VaultImportFolderSheet(vault: vault, groups: groups, linked: linked)
        case .download(let id): VaultDownloadSheet(vault: vault, container: id)
        case .moveToEnvironments(let id): if let item = vault.index.item(id) { VaultMoveEnvSheet(vault: vault, item: item) }
        case .moveToKeys(let id): if let item = vault.index.item(id) { VaultMoveKeySheet(vault: vault, item: item) }
        case .lastImport: VaultLastImportSheet(vault: vault)
        }
    }
}

// MARK: Item

private struct VaultItemSheet: View {
    @Bindable var vault: VaultSession
    let original: VaultItem
    @Environment(\.dismiss) private var dismiss
    @State private var item: VaultItem
    @State private var newFile: URL?
    @State private var saving = false
    /// Secret fields of a saved item shown in plain text after the user passed the same presence check as «Mostrar».
    @State private var revealedFields: Set<UUID> = []
    init(vault: VaultSession, original: VaultItem) {
        self.vault = vault
        self.original = original
        _item = State(initialValue: original)
    }
    var isNew: Bool { vault.index.item(original.id) == nil }
    var isApp: Bool { vault.index.container(item.container)?.kind == .app }
    /// A saved secret value stays masked, and its «Secreto» mark fixed, until it is revealed.
    func isLocked(_ field: VaultField) -> Bool { !isNew && !revealedFields.contains(field.id) && original.hasSecretValue(field.id) }
    func reveal(_ field: VaultField) async {
        if await vault.revealForEditing(field, of: original) { revealedFields.insert(field.id) }
    }
    var body: some View {
        SheetFrame(title: isNew ? L("vault.newItem") : L("vault.editItem"),
                   symbol: item.kind.symbol,
                   detail: L("vault.itemDetail"),
                   width: 640,
                   height: 680,
                   actionTitle: L("common.save"),
                   actionID: "vault.sheet.item.confirm",
                   canAct: !(saving || item.name.trimmingCharacters(in: .whitespaces).isEmpty && newFile == nil),
                   cancelID: "vault.sheet.item.cancel",
                   action: { await save(); return false }) {
            Form {
                Section {
                    Picker(L("common.type"), selection: $item.kind) {
                        ForEach(VaultItemKind.choices(keeping: original.kind)) { Label(L("vault.kind.\($0.rawValue)"), systemImage: $0.symbol).tag($0) }
                    }
                    .accessibilityIdentifier("vault.sheet.item.kind")
                    .onChange(of: item.kind) { _, kind in
                        if isNew && item.fields.allSatisfy({ $0.value.isEmpty }) { item.fields = kind.templateFields }
                        if isNew, isApp, let section = kind.defaultSection { item.section = section }
                    }
                    TextField(L("common.name"), text: $item.name, prompt: Text(L("vault.itemNamePrompt"))).accessibilityIdentifier("vault.sheet.item.name")
                    if isApp {
                        Picker(L("vault.section"), selection: $item.section) {
                            Text(L("vault.part.none")).tag(VaultSection?.none)
                            ForEach(VaultSection.allCases) { Text($0.title).tag(VaultSection?.some($0)) }
                        }
                        .accessibilityIdentifier("vault.sheet.item.section")
                    }
                    Picker(L("vault.environment"), selection: $item.environment) {
                        ForEach(VaultEnvironment.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented).accessibilityIdentifier("vault.sheet.item.environment")
                }
                Section(L("vault.fields")) {
                    ForEach($item.fields) { $field in
                        // Its place in the item: custom fields share their role, so identifiers use it.
                        let position = item.fields.firstIndex { $0.id == field.id } ?? 0
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                if field.role == .custom {
                                    TextField("", text: $field.label, prompt: Text(L("vault.fieldLabel"))).labelsHidden().textFieldStyle(.roundedBorder)
                                        .frame(maxWidth: 260).accessibilityIdentifier("vault.sheet.item.field.\(position).label")
                                } else {
                                    Text(field.title).font(.uiCallout.weight(.medium))
                                }
                                Spacer()
                                Toggle(L("vault.secret"), isOn: $field.secret).toggleStyle(.checkbox).disabled(isLocked(field))
                                    .accessibilityIdentifier("vault.sheet.item.field.\(position).secret")
                                Button(role: .destructive) { item.fields.removeAll { $0.id == field.id } } label: {
                                    Label(L("vault.removeField"), systemImage: Symbols.remove).labelStyle(.iconOnly)
                                }
                                .buttonStyle(.borderless).help(L("vault.removeField")).accessibilityIdentifier("vault.sheet.item.field.\(position).remove")
                            }
                            HStack {
                                Group {
                                    if field.secret && !revealedFields.contains(field.id) { SecureField("", text: $field.value, prompt: Text(L("vault.value"))) }
                                    else { TextField("", text: $field.value, prompt: Text(L("vault.value"))) }
                                }
                                .labelsHidden().textFieldStyle(.roundedBorder)
                                .accessibilityIdentifier("vault.sheet.item.field.\(position).value")
                                if isLocked(field) {
                                    Button { Task { await reveal(field) } } label: {
                                        Label(L("vault.reveal"), systemImage: Symbols.reveal).labelStyle(.iconOnly)
                                    }
                                    .buttonStyle(.borderless).help(L("vault.reveal"))
                                    .accessibilityIdentifier("vault.sheet.item.field.\(position).reveal")
                                }
                                TextField("", text: Binding(get: { field.envVar ?? "" }, set: { field.envVar = $0.isEmpty ? nil : $0 }), prompt: Text(L("vault.envVar")))
                                    .labelsHidden().textFieldStyle(.roundedBorder)
                                    .font(.uiCallout.monospaced()).frame(width: 240).accessibilityIdentifier("vault.sheet.item.field.\(position).env")
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    Menu {
                        ForEach(VaultField.Role.allCases, id: \.self) { role in
                            Button(role == .custom ? L("vault.field.custom") : L("vault.field.\(role.rawValue)")) {
                                item.fields.append(VaultField(role: role, secret: [.password, .storePassword, .keyPassword, .passphrase, .token].contains(role)))
                            }
                        }
                    } label: { Label(L("vault.addField"), systemImage: Symbols.add) }
                        .fixedSize().accessibilityIdentifier("vault.sheet.item.addField")
                }
                Section(L("vault.files")) {
                    ForEach(item.files) { file in
                        HStack {
                            Label(file.name, systemImage: Symbols.file).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(Format.fileSizeText(Int64(file.size))).foregroundStyle(.secondary)
                            Button(role: .destructive) { item.files.removeAll { $0.id == file.id } } label: {
                                Label(L("vault.removeFile"), systemImage: Symbols.remove).labelStyle(.iconOnly)
                            }
                            .buttonStyle(.borderless).help(L("vault.removeFile")).accessibilityIdentifier("vault.sheet.item.file.\(file.name).remove")
                        }
                    }
                    if let newFile {
                        Label(newFile.lastPathComponent, systemImage: Symbols.addFiles)
                    }
                    Button { attach() } label: { Label(L("vault.attachFile"), systemImage: Symbols.attachment) }
                        .buttonStyle(.bordered).accessibilityIdentifier("vault.sheet.item.attach")
                }
                Section(L("vault.notes")) {
                    TextEditor(text: $item.notes).font(.uiCallout).frame(height: 70).accessibilityIdentifier("vault.sheet.item.notes")
                }
            }
            .formStyle(.grouped).themedScroll()
        } status: {
            Text(L("vault.itemFooter")).font(.uiCaption).foregroundStyle(.secondary)
        }
    }
    func attach() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.message = L("vault.chooseFilesMessage")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        newFile = url
        if item.name.isEmpty { item.name = url.lastPathComponent }
        if isNew, item.kind == .file || item.kind == .note {
            // The kinds the vault no longer creates (a .env, an SSH key) leave the kind as it was.
            let detected = VaultInspector.detectKind(name: url.lastPathComponent, data: try? FileHandle(forReadingFrom: url).read(upToCount: 64_000))
            if !detected.isRetired { item.kind = detected }
        }
    }
    func save() async {
        saving = true
        defer { saving = false }
        item.name = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if item.name.isEmpty, let newFile { item.name = newFile.lastPathComponent }
        do {
            try await vault.save(item, newFile: newFile)
            dismiss()
        } catch { vault.message = L((error as? VaultError)?.messageKey ?? "vault.error.io") }
    }
}

// MARK: Encrypted backup

private struct VaultExportSheet: View {
    @Bindable var vault: VaultSession
    let container: UUID?
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var confirm = ""
    @State private var working = false
    var scopeName: String { container.flatMap { vault.index.container($0)?.folderName } ?? L("vault.everything") }
    var valid: Bool { password.count >= VaultArchive.minimumPasswordLength && password == confirm }
    var body: some View {
        SheetFrame(title: L("vault.exportTitle"),
                   symbol: Symbols.backup,
                   detail: String(format: L("vault.exportDetail"), scopeName),
                   width: 520,
                   height: 380,
                   actionTitle: L("vault.exportSave"),
                   actionID: "vault.sheet.export.confirm",
                   canAct: valid && !working,
                   cancelID: "vault.sheet.export.cancel",
                   action: { await export(); return false }) {
            Form {
                SecureField(L("vault.archivePassword"), text: $password).accessibilityIdentifier("vault.sheet.export.password")
                SecureField(L("vault.archivePasswordConfirm"), text: $confirm).accessibilityIdentifier("vault.sheet.export.repeat")
                Label(password.count < VaultArchive.minimumPasswordLength ? String(format: L("vault.passwordShort"), VaultArchive.minimumPasswordLength)
                      : password == confirm ? L("vault.passwordOk") : L("vault.passwordMismatch"),
                      systemImage: valid ? Symbols.success : Symbols.info)
                    .font(.uiCaption).foregroundStyle(valid ? Brand.successText : .secondary)
            }
            .formStyle(.grouped).themedScroll()
            Text(L("vault.exportWarning")).font(.uiCaption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    func export() async {
        guard await vault.confirmPresence(L("vault.auth.export"), fresh: true) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [VaultActions.archiveType]
        let date = Format.fileStamp()
        let slug = container == nil ? "todo" : VaultFolder.variableName(scopeName).lowercased()
        panel.nameFieldStringValue = "boveda-\(slug)-\(date).butakevault"
        panel.message = L("vault.exportPanel")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        working = true
        defer { working = false }
        do {
            let data = try await vault.exportArchive(container, password: password)
            // The backup is the last defence: the one it replaces stays until the new one is written whole.
            try VaultDisk.writePrivate(data, to: url, durable: true)
            password = ""; confirm = ""
            vault.notice = L("vault.exported")
            dismiss()
        } catch { vault.message = L((error as? VaultError)?.messageKey ?? "vault.error.io") }
    }
}

private struct VaultImportArchiveSheet: View {
    @Bindable var vault: VaultSession
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var header: VaultArchive.Header?
    @State private var data: Data?
    @State private var working = false
    var body: some View {
        SheetFrame(title: L("vault.importArchive"),
                   symbol: Symbols.importing,
                   detail: L("vault.importArchiveDetail"),
                   width: 520,
                   height: 380,
                   actionTitle: L("vault.importAction"),
                   actionID: "vault.sheet.importArchive.confirm",
                   canAct: !(header == nil || password.isEmpty || working),
                   cancelID: "vault.sheet.importArchive.cancel",
                   action: { await run(); return false }) {
            Form {
                LabeledContent(L("vault.archiveFile"), value: url.lastPathComponent)
                if let header {
                    LabeledContent(L("vault.archiveCreated"), value: Format.shortDateTime(header.created))
                    LabeledContent(L("vault.archiveScope"), value: header.scope == "all" ? L("vault.everything") : header.scope)
                    LabeledContent(L("vault.archiveContent"), value: String(format: L("vault.archiveCounts"), header.containers, header.items))
                    SecureField(L("vault.archivePassword"), text: $password).accessibilityIdentifier("vault.sheet.importArchive.password")
                } else {
                    Label(L("vault.error.unsupported"), systemImage: Symbols.warning).foregroundStyle(Brand.warningText)
                }
            }
            .formStyle(.grouped).themedScroll()
        }
        // Up to 512 MiB: read off the main actor, so the window does not freeze while the file loads.
        .task {
            let url = url
            let loaded = await Task.detached(priority: .userInitiated) { () -> (Data, VaultArchive.Header?)? in
                guard let bytes = try? VaultDisk.readRegularFile(url, limit: VaultArchive.maximumSize) else { return nil }
                return (bytes, try? VaultArchive.header(of: bytes).0)
            }.value
            guard let loaded else { return }
            data = loaded.0
            header = loaded.1
        }
    }
    func run() async {
        guard let data else { return }
        working = true
        defer { working = false }
        do {
            let result = try await vault.importArchive(data, password: password)
            vault.notice = String(format: L("vault.importedArchive"), result.added, result.skipped)
            dismiss()
        } catch { vault.message = L((error as? VaultError)?.messageKey ?? "vault.error.io") }
    }
}

// MARK: Plain download

private struct VaultDownloadSheet: View {
    @Bindable var vault: VaultSession
    let container: UUID?
    @Environment(\.dismiss) private var dismiss
    @State private var understood = false
    @State private var layout = VaultFolder.Layout.stack
    var body: some View {
        SheetFrame(title: container == nil ? L("vault.downloadAll") : L("vault.downloadOne"),
                   symbol: Symbols.dump,
                   detail: L("vault.downloadDetail"),
                   width: 540,
                   height: 460,
                   actionTitle: L("vault.downloadChoose"),
                   actionID: "vault.sheet.download.confirm",
                   canAct: understood,
                   cancelID: "vault.sheet.download.cancel",
                   action: { await run(); return false }) {
            Notice(.warning, L("vault.downloadWarning"))
            Picker(L("vault.download.layout"), selection: $layout) {
                ForEach(VaultFolder.Layout.allCases) { Text(L("vault.download.layout.\($0.rawValue)")).tag($0) }
            }
            .pickerStyle(.radioGroup).accessibilityIdentifier("vault.sheet.download.layout")
            Text(L(layout == .stack ? "vault.downloadLayout" : "vault.download.layoutBackup"))
                .font(.uiCaption.monospaced()).foregroundStyle(.secondary)
            Toggle(L("vault.downloadUnderstood"), isOn: $understood).toggleStyle(.checkbox).accessibilityIdentifier("vault.sheet.download.understood")
            Spacer(minLength: 0)
        }
    }
    func run() async {
        guard await vault.confirmPresence(L("vault.auth.download"), fresh: true) else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = L("vault.downloadHere")
        panel.message = L("vault.downloadPanel")
        guard panel.runModal() == .OK, let parent = panel.url else { return }
        do {
            let folder = try await vault.downloadFolderInBackground(container, into: parent, layout: layout)
            NSWorkspace.shared.activateFileViewerSelecting([folder])
            vault.notice = L("vault.downloaded")
            dismiss()
        } catch { vault.message = L((error as? VaultError)?.messageKey ?? "vault.error.io") }
    }
}
