import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// "Bóveda", like Passwords: what signs and publishes each app (keystores, certificates, profiles,
/// store keys, service accounts), encrypted on this Mac and organized like the master backup folder.
/// Unlocked, its apps and services are in the window's content column (`VaultList`), this is the one
/// selected; an item opens in its place, with a back arrow in the toolbar. Locked, it is one pane with «Desbloquear».
struct VaultPage: View {
    @Bindable var store: StackStore
    @Bindable var vault = VaultSession.shared

    var body: some View {
        Group {
            switch vault.state {
            case .unlocked: VaultDetail(store: store, vault: vault)
            case .unknown: ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            default: VaultLockedView(vault: vault)
            }
        }
        .task { vault.refreshState() }
        .onChange(of: vault.notice) { _, notice in
            if let notice { store.notify(notice); vault.notice = nil }
        }
        .alert(L("error.title"), isPresented: Binding(get: { vault.message != nil }, set: { if !$0 { vault.message = nil } })) {
            Button(L("common.close"), role: .cancel) { vault.message = nil }
        } message: { Text(vault.message ?? "") }
        .sheet(item: $vault.sheet) { sheet in VaultSheetHost(vault: vault, sheet: sheet).themedSheet() }
    }
}

// MARK: Locked

/// Absent, locked or unreadable: one message and its action, centered by the system's own empty
/// view (a plain stack sized to the window once left the sidebar empty).
private struct VaultLockedView: View {
    @Bindable var vault: VaultSession
    @State private var confirmingSetAside = false
    var body: some View {
        ContentUnavailableView {
            Label(L(titleKey), systemImage: Symbols.vault)
        } description: {
            Text(L(detailKey))
            // A link's folders wait, unread, until the user unlocks: only how many, never which.
            if !vault.proposedFolders.isEmpty {
                Text(String(format: L("vault.link.waiting"), vault.proposedFolders.count)).accessibilityIdentifier("vault.locked.linked")
            }
        } actions: {
            switch vault.state {
            case .absent:
                Button { Task { await vault.create() } } label: { Label(L("vault.create"), systemImage: Symbols.add) }
                    .buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction)
                    .help(L("vault.createHelp")).accessibilityIdentifier("vault.create")
            case .missingKey, .unreadable:
                Button(role: .destructive) { confirmingSetAside = true } label: { Label(L("vault.startOver"), systemImage: Symbols.startOver) }
                    .buttonStyle(.bordered).accessibilityIdentifier("vault.startOver")
            default:
                Button { Task { await vault.unlock() } } label: { Label(L("vault.unlock"), systemImage: Symbols.unlock) }
                    .buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction)
                    .help(L("vault.unlockHelp")).accessibilityIdentifier("vault.unlock")
            }
            if !vault.proposedFolders.isEmpty {
                Button { vault.proposedFolders = [] } label: { Label(L("vault.link.discard"), systemImage: Symbols.close) }
                    .buttonStyle(.bordered).help(L("vault.link.discardHelp")).accessibilityIdentifier("vault.locked.discardLinked")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("vault.locked")
        .confirmationDialog(L("vault.startOverTitle"), isPresented: $confirmingSetAside) {
            Button(L("vault.startOver"), role: .destructive) { vault.setAsideUnreadable() }
            Button(L("common.cancel"), role: .cancel) {}
        } message: { Text(L("vault.startOverDetail")) }
    }
    var titleKey: String {
        switch vault.state {
        case .absent: "vault.absentTitle"
        case .missingKey: "vault.missingKeyTitle"
        case .unreadable: "vault.unreadableTitle"
        default: "vault.lockedTitle"
        }
    }
    var detailKey: String {
        switch vault.state {
        case .absent: "vault.absentDetail"
        case .missingKey: "vault.missingKeyDetail"
        case .unreadable: "vault.unreadableDetail"
        default: "vault.lockedDetail"
        }
    }
}

// MARK: Unlocked

private struct VaultDetail: View {
    @Bindable var store: StackStore
    @Bindable var vault: VaultSession
    @State private var confirmingDelete: VaultContainer?
    /// The apps and services without items that «Quitar contenedores vacíos…» would remove.
    @State private var confirmingEmpty: [VaultContainer] = []

    private var container: VaultContainer? {
        if case .container(let id)? = vault.selection { return vault.index.container(id) }
        return nil
    }

    var body: some View {
        // An item opens in place of its app or service, like a page of System Settings, with a back
        // arrow in the toolbar (no room for an inspector at the window's minimum width). A
        // NavigationStack here would replace the window's toolbar while an item is open.
        Group {
            if let item = vault.inspected.flatMap(vault.index.item) {
                VaultItemDetail(vault: vault, item: item).id(item.id)
            } else if let app = vault.signing.flatMap(vault.index.container) {
                VaultSigningDetail(vault: vault, container: app).id(app.id)
            } else {
                switch vault.selection {
                case .container(let id):
                    if let container = vault.index.container(id) { VaultContainerDetail(vault: vault, container: container).id(id) }
                    else { VaultEmptyDetail(vault: vault) }
                case .expiring: VaultExpiringDetail(vault: vault)
                case nil: VaultEmptyDetail(vault: vault)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .toolbar { toolbar }
        // An item opened from elsewhere (a project's page) stays open beside its own app.
        .onChange(of: vault.selection) {
            if vault.inspected.flatMap(vault.index.item).map({ VaultSession.Selection.container($0.container) }) != vault.selection
                && vault.signing.map({ VaultSession.Selection.container($0) }) != vault.selection { vault.inspected = nil }
            if vault.signing.map({ VaultSession.Selection.container($0) }) != vault.selection { vault.signing = nil }
        }
        .simultaneousGesture(TapGesture().onEnded { vault.touch() })
        .confirmationDialog(String(format: L("vault.deleteContainerTitle"), confirmingDelete?.title ?? ""),
                            isPresented: Binding(get: { confirmingDelete != nil }, set: { if !$0 { confirmingDelete = nil } }),
                            presenting: confirmingDelete) { container in
            Button(L("common.delete"), role: .destructive) {
                do { try vault.deleteContainer(container.id) } catch { vault.message = L((error as? VaultError)?.messageKey ?? "vault.error.io") }
            }
            Button(L("common.cancel"), role: .cancel) {}
        } message: { _ in Text(L("vault.deleteContainerDetail")) }
        .confirmationDialog(String(format: L("vault.removeEmpty.title"), confirmingEmpty.count),
                            isPresented: Binding(get: { !confirmingEmpty.isEmpty }, set: { if !$0 { confirmingEmpty = [] } })) {
            Button(L("vault.removeEmpty.action"), role: .destructive) {
                do {
                    let removed = try vault.removeEmptyContainers()
                    vault.notice = String(format: L("vault.removeEmpty.done"), removed)
                } catch { vault.message = L((error as? VaultError)?.messageKey ?? "vault.error.io") }
            }
            .accessibilityIdentifier("vault.removeEmpty.confirm")
            Button(L("common.cancel"), role: .cancel) {}
        } message: {
            Text(String(format: L("vault.removeEmpty.detail"), confirmingEmpty.map { [$0.title, $0.subtitlePath].compactMap { $0 }.joined(separator: " · ") }.joined(separator: ", ")))
        }
    }

    /// One main action with its title («Nuevo…»), «Bloquear», and everything else in «⋯».
    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        if vault.inspected.flatMap(vault.index.item) != nil || vault.signing != nil {
            ToolbarItem(placement: .navigation) {
                Button { if vault.inspected != nil { vault.inspected = nil } else { vault.signing = nil } } label: { Label(backTitle, systemImage: Symbols.back) }
                    .keyboardShortcut("[", modifiers: .command)
                    .help(backTitle).accessibilityIdentifier("vault.toolbar.back")
            }
        }
        if #available(macOS 26, *) {
            // Apart from the window's own «+» (new project).
            ToolbarSpacer(.fixed, placement: .primaryAction)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                Button { vault.sheet = .newContainer(.app) } label: { Label(L("vault.newAppEllipsis"), systemImage: Symbols.app) }
                    .help(L("vault.newAppHelp")).accessibilityIdentifier("vault.toolbar.newApp")
                Button { vault.sheet = .newContainer(.service) } label: { Label(L("vault.newServiceEllipsis"), systemImage: Symbols.server) }
                    .help(L("vault.newServiceHelp")).accessibilityIdentifier("vault.toolbar.newService")
                if let container {
                    Section(container.title) {
                        Button { VaultActions.chooseFiles(vault, container: container.id, section: nil) } label: {
                            Label(L("vault.addFiles"), systemImage: Symbols.addFiles)
                        }
                        .help(L("vault.addFilesHelp")).accessibilityIdentifier("vault.toolbar.addFiles")
                        ForEach(VaultItemKind.offered) { kind in
                            Button { vault.sheet = .item(VaultActions.draft(kind, in: container, section: nil)) } label: {
                                Label(L("vault.kind.\(kind.rawValue)") + "…", systemImage: kind.symbol)
                            }
                            .accessibilityIdentifier("vault.toolbar.newItem.\(kind.rawValue)")
                        }
                    }
                }
            } label: {
                Label(L("vault.new"), systemImage: Symbols.newItem).labelStyle(.titleAndIcon)
            }
            .help(L("vault.newHelp")).accessibilityIdentifier("vault.toolbar.new")

            Button { vault.lock() } label: { Label(L("vault.lock"), systemImage: Symbols.locked).labelStyle(.titleAndIcon).font(.body) }
                .keyboardShortcut("l", modifiers: [.command, .control])
                .help(L("vault.lockHelp")).accessibilityIdentifier("vault.toolbar.lock")

            Menu {
                Button { vault.sheet = .exportArchive(nil) } label: { Label(L("vault.backup"), systemImage: Symbols.backup) }
                    .help(L("vault.backupHelp")).accessibilityIdentifier("vault.toolbar.backup")
                Menu {
                    Button { VaultActions.openArchive(vault) } label: { Label(L("vault.importArchive"), systemImage: Symbols.backup) }
                        .help(L("vault.importArchiveHelp")).accessibilityIdentifier("vault.toolbar.importArchive")
                    Button { VaultActions.chooseFolder(vault) } label: { Label(L("vault.importFolder"), systemImage: Symbols.newFolder) }
                        .help(L("vault.importFolderHelp")).accessibilityIdentifier("vault.toolbar.importFolder")
                } label: { Label(L("vault.import"), systemImage: Symbols.importing) }
                    .help(L("vault.importHelp")).accessibilityIdentifier("vault.toolbar.import")
                Menu {
                    Picker(L("common.type"), selection: $vault.kindFilter) {
                        Text(L("vault.filter.allKinds")).tag(VaultItemKind?.none)
                        ForEach(filterKinds) { kind in Label(L("vault.kind.\(kind.rawValue)"), systemImage: kind.symbol).tag(VaultItemKind?.some(kind)) }
                    }
                    .accessibilityIdentifier("vault.toolbar.filter.kind")
                    Picker(L("vault.filter.expiry"), selection: $vault.expiryFilter) {
                        ForEach(VaultSession.ExpiryFilter.allCases) { Text(L("vault.filter.\($0.rawValue)")).tag($0) }
                    }
                    .accessibilityIdentifier("vault.toolbar.filter.expiry")
                } label: { Label(L("vault.filterTitle"), systemImage: Symbols.filter) }
                    .help(L("vault.filterHelp")).accessibilityIdentifier("vault.toolbar.filter")
                if let container {
                    Section(container.title) {
                        Button { vault.sheet = .editContainer(container.id) } label: { Label(L("vault.editContainer"), systemImage: Symbols.edit) }
                            .help(L("vault.editContainerHelp")).accessibilityIdentifier("vault.toolbar.editContainer")
                        Button { vault.sheet = .exportArchive(container.id) } label: { Label(L("vault.backupOne"), systemImage: Symbols.backup) }
                            .help(L("vault.backupHelp")).accessibilityIdentifier("vault.toolbar.backupOne")
                        Button { vault.sheet = .download(container.id) } label: { Label(L("vault.downloadOne"), systemImage: Symbols.dump) }
                            .help(L("vault.downloadHelp")).accessibilityIdentifier("vault.toolbar.downloadOne")
                        Button(role: .destructive) { confirmingDelete = container } label: { Label(L("vault.deleteContainer"), systemImage: Symbols.delete) }
                            .help(L("vault.deleteContainerHelp")).accessibilityIdentifier("vault.toolbar.deleteContainer")
                    }
                }
                Divider()
                Button { vault.sheet = .lastImport } label: { Label(L("vault.lastImport.menu"), systemImage: Symbols.review) }
                    .disabled(vault.index.lastImport == nil)
                    .help(L("vault.lastImport.help")).accessibilityIdentifier("vault.toolbar.lastImport")
                Button { confirmingEmpty = vault.emptyContainers } label: { Label(L("vault.removeEmpty.menu"), systemImage: Symbols.emptyInbox) }
                    .disabled(vault.emptyContainers.isEmpty)
                    .help(L("vault.removeEmpty.help")).accessibilityIdentifier("vault.toolbar.removeEmpty")
                Button { vault.sheet = .download(nil) } label: { Label(L("vault.downloadAll"), systemImage: Symbols.dump) }
                    .help(L("vault.downloadHelp")).accessibilityIdentifier("vault.toolbar.downloadAll")
                Button { store.showLogs(LogsBrowser.vaultSource) } label: { Label(L("vault.log"), systemImage: Symbols.logs) }
                    .help(L("vault.logHelp")).accessibilityIdentifier("vault.toolbar.log")
            } label: {
                Label(L("vault.moreActions"), systemImage: Symbols.more)
            }
            .help(L("vault.moreActions")).accessibilityIdentifier("vault.toolbar.more")
        }
    }

    /// Back to the app, the service or Por vencer the item was opened from.
    private var backTitle: String {
        if vault.inspected != nil && vault.signing != nil { return String(format: L("vault.backTo"), L("vault.signing.title")) }
        return switch vault.selection {
        case .container(let id): String(format: L("vault.backTo"), vault.index.container(id)?.title ?? "")
        default: String(format: L("vault.backTo"), L("vault.expiring"))
        }
    }

    /// The kinds a new item can take, and those of the items already kept.
    private var filterKinds: [VaultItemKind] {
        let kept = Set(vault.index.items.map(\.kind))
        return VaultItemKind.allCases.filter { !$0.isRetired || kept.contains($0) }
    }
}

/// Nothing chosen: the first steps of an empty vault, or what to do next.
private struct VaultEmptyDetail: View {
    @Bindable var vault: VaultSession
    var body: some View {
        if vault.index.containers.isEmpty {
            ContentUnavailableView {
                Label(L("vault.noneTitle"), systemImage: Symbols.vault)
            } description: {
                Text(L("vault.emptyDetail"))
            } actions: {
                // One under the other: side by side they do not fit at the window's minimum width.
                VStack(spacing: 8) {
                    Button { vault.sheet = .newContainer(.app) } label: { Label(L("vault.newAppEllipsis"), systemImage: Symbols.app) }
                        .buttonStyle(.borderedProminent).help(L("vault.newAppHelp")).accessibilityIdentifier("vault.empty.newApp")
                    Button { VaultActions.chooseFolder(vault) } label: { Label(L("vault.importFolder"), systemImage: Symbols.newFolder) }
                        .buttonStyle(.bordered).help(L("vault.importFolderHelp")).accessibilityIdentifier("vault.empty.importFolder")
                    Button { VaultActions.openArchive(vault) } label: { Label(L("vault.importArchive"), systemImage: Symbols.importing) }
                        .buttonStyle(.bordered).help(L("vault.importArchiveHelp")).accessibilityIdentifier("vault.empty.importArchive")
                }
            }
        } else {
            ContentUnavailableView(L("vault.emptyTitle"), systemImage: Symbols.vault)
        }
    }
}

// MARK: Panels

@MainActor enum VaultActions {
    static func draft(_ kind: VaultItemKind, in container: VaultContainer, section: VaultSection?) -> VaultItem {
        VaultItem(container: container.id, section: container.kind == .app ? (section ?? kind.defaultSection ?? .terceros) : nil,
                  kind: kind, name: "", fields: kind.templateFields)
    }

    static func chooseFiles(_ vault: VaultSession, container: UUID, section: VaultSection?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        panel.message = L("vault.chooseFilesMessage")
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task {
            let added = await vault.add(files: urls, to: container, section: section)
            if added > 0 { vault.notice = String(format: L("vault.added"), added) }
        }
    }

    static func chooseFolder(_ vault: VaultSession) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = L("vault.chooseFolderMessage")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        vault.previewImport([url])
    }

    static func openArchive(_ vault: VaultSession) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [VaultActions.archiveType]
        panel.allowsMultipleSelection = false
        panel.message = L("vault.openArchiveMessage")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        vault.sheet = .importArchive(url)
    }

    static var archiveType: UTType { UTType(filenameExtension: "butakevault") ?? .data }
}
