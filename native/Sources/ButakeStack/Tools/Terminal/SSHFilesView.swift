import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Remote files of a host over SFTP: browse, upload (toolbar or drag from Finder), download with
/// progress, rename, create folders and delete with confirmation. Its actions are in the window's
/// toolbar (`SFTPToolbar`) and in each row's context menu.
struct SSHFilesView: View {
    @Bindable var browser: SFTPBrowser
    @State private var dropping = false
    @State private var pathText = ""
    var body: some View {
        VStack(spacing: 0) {
            TextField(L("ssh.sftp.path"), text: $pathText)
                .textFieldStyle(.roundedBorder).font(.uiCallout.monospaced())
                .onSubmit { Task { await browser.load(pathText) } }
                .help(L("ssh.sftp.path"))
                .accessibilityIdentifier("ssh.sftp.path")
                .padding(.horizontal, 12).padding(.vertical, 8)
                .overlay(alignment: .bottom) { Divider() }
            ZStack {
                if let failure = browser.failure, browser.entries.isEmpty {
                    ContentUnavailableView {
                        Label(L("ssh.sftp.failed"), systemImage: Symbols.warning)
                    } description: { Text(failure) } actions: {
                        Button { Task { await browser.load(nil) } } label: { Label(L("common.retry"), systemImage: Symbols.reload) }
                            .buttonStyle(.bordered).accessibilityIdentifier("ssh.sftp.retry")
                    }
                } else {
                    table
                    if browser.entries.isEmpty && !browser.loading && !browser.path.isEmpty {
                        ContentUnavailableView(L("ssh.sftp.emptyFolder"), systemImage: Symbols.folder, description: Text(L("ssh.sftp.emptyFolderDetail")))
                            .accessibilityIdentifier("ssh.sftp.empty")
                    }
                }
                if browser.loading { ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing).padding(10) }
                if dropping {
                    RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6]))
                        .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                        .overlay(Label(String(format: L("ssh.sftp.dropHere"), browser.path), systemImage: Symbols.share).font(.uiHeadline).foregroundStyle(Color.accentColor))
                        .padding(8).allowsHitTesting(false)
                }
            }
            .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
                for provider in providers {
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in
                        if let url { Task { @MainActor in await browser.upload([url]) } }
                    }
                }
                return true
            }
            if !browser.transfers.isEmpty {
                TransfersPanel(browser: browser).overlay(alignment: .top) { Divider() }
            }
        }
        .onChange(of: browser.path, initial: true) { _, path in pathText = path }
        .background { Button(L("ssh.sftp.up")) { browser.goUp() }.keyboardShortcut(.upArrow).hidden() }
        .sheet(item: $browser.naming) { naming in
            switch naming {
            case .newFolder:
                SFTPNameSheet(title: L("ssh.sftp.newFolder"), initial: "", action: L("common.create")) { name in await browser.mkdir(name) }.themedSheet()
            case .rename(let entry):
                SFTPNameSheet(title: L("ssh.sftp.rename"), initial: entry.name, action: L("ssh.sftp.renameButton")) { name in await browser.rename(entry, to: name) }.themedSheet()
            }
        }
        .confirmationDialog(deleteTitle, isPresented: Binding(get: { !browser.deleting.isEmpty }, set: { if !$0 { browser.deleting = [] } })) {
            Button(L("common.delete"), role: .destructive) { let items = browser.deleting; browser.deleting = []; Task { await browser.delete(items) } }
                .accessibilityIdentifier("ssh.sftp.confirmDelete")
            Button(L("common.cancel"), role: .cancel) {}
        } message: { Text(browser.deleting.contains { $0.isDirectory } ? L("ssh.sftp.deleteFolderDetail") : L("ssh.sftp.deleteDetail")) }
        .confirmationDialog(String(format: L("ssh.sftp.overwrite"), browser.overwrite?.entry.name ?? ""), isPresented: Binding(get: { browser.overwrite != nil }, set: { if !$0 { browser.overwrite = nil } })) {
            Button(L("ssh.sftp.replace"), role: .destructive) {
                guard let overwrite = browser.overwrite else { return }
                browser.overwrite = nil
                Task { do { try await browser.download(overwrite.entry, to: overwrite.folder, overwrite: true) } catch { StackStore.shared.report(error) } }
            }
            Button(L("common.cancel"), role: .cancel) {}
        }
    }

    private var table: some View {
        Table(browser.entries, selection: $browser.selection) {
            TableColumn(L("common.name")) { entry in
                Label {
                    Text(entry.name).lineLimit(1).truncationMode(.middle).help(entry.name)
                } icon: {
                    Image(systemName: entry.isDirectory ? Symbols.folder : entry.isLink ? Symbols.link : Symbols.file)
                        .foregroundStyle(entry.isDirectory ? TileColor.folder : .secondary)
                }
            }
            .width(min: 140, ideal: 200)
            TableColumn(L("ssh.sftp.size")) { entry in
                Text(entry.isDirectory ? "—" : Format.fileSizeText(Int64(entry.size))).monospacedDigit().foregroundStyle(.secondary)
            }
            .width(min: 70, ideal: 90, max: 120)
            TableColumn(L("ssh.sftp.modified")) { entry in Text(entry.modified).monospacedDigit().foregroundStyle(.secondary) }
                .width(min: 90, ideal: 130, max: 160)
            TableColumn(L("ssh.sftp.mode")) { entry in Text(entry.mode).font(.uiSubheadline.monospaced()).foregroundStyle(.secondary) }
                .width(min: 70, ideal: 90, max: 110)
        }
        .contextMenu(forSelectionType: String.self) { names in
            let items = browser.entries.filter { names.contains($0.name) }
            if items.count == 1, let entry = items.first, entry.isDirectory {
                Button { Task { await browser.load(browser.full(entry.name)) } } label: { Label(L("common.open"), systemImage: Symbols.folder) }
                Divider()
            }
            Button { browser.chooseDownload(items) } label: { Label(L("ssh.sftp.download"), systemImage: Symbols.dump) }.disabled(items.isEmpty)
            Button { browser.chooseUploads() } label: { Label(L("ssh.sftp.upload"), systemImage: Symbols.share) }
            Button { browser.naming = .newFolder } label: { Label(L("ssh.sftp.newFolderEllipsis"), systemImage: Symbols.newFolder) }
            Button { if let entry = items.first { browser.naming = .rename(entry) } } label: { Label(L("ssh.sftp.renameEllipsis"), systemImage: Symbols.edit) }
                .disabled(items.count != 1)
            Divider()
            Button(role: .destructive) { browser.deleting = items } label: { Label(L("ssh.sftp.deleteEllipsis"), systemImage: Symbols.delete) }
                .disabled(items.isEmpty)
        } primaryAction: { names in
            if names.count == 1, let entry = browser.entries.first(where: { names.contains($0.name) }), entry.isDirectory || entry.isLink {
                Task { await browser.load(browser.full(entry.name)) }
            }
        }
        .accessibilityIdentifier("ssh.sftp.table")
    }

    var deleteTitle: String {
        browser.deleting.count == 1 ? String(format: L("ssh.sftp.deleteConfirm"), browser.deleting[0].name) : String(format: L("ssh.sftp.deleteConfirmMany"), browser.deleting.count)
    }
}

/// The file browser's actions in the window's toolbar, with the page's: Subir… and Descargar… with
/// their titles, and the rest in «Archivo» (parent folder ⌘↑, home, new folder, rename, delete).
struct SFTPToolbar: ToolbarContent {
    @Bindable var browser: SFTPBrowser
    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button { browser.chooseUploads() } label: { Label(L("ssh.sftp.uploadShort"), systemImage: Symbols.share) }
                .labelStyle(.titleAndIcon).font(nil).help(L("ssh.sftp.upload")).accessibilityIdentifier("ssh.toolbar.sftp.upload")
            Button { browser.chooseDownload(browser.selected) } label: { Label(L("ssh.sftp.downloadShort"), systemImage: Symbols.dump) }
                .labelStyle(.titleAndIcon).font(nil).disabled(browser.selected.isEmpty).help(L("ssh.sftp.download")).accessibilityIdentifier("ssh.toolbar.sftp.download")
            Menu {
                Button { browser.goUp() } label: { Label(L("ssh.sftp.up"), systemImage: Symbols.parentFolder) }
                    .disabled(browser.parent == nil).accessibilityIdentifier("ssh.toolbar.sftp.up")
                Button { Task { await browser.load("") } } label: { Label(L("ssh.sftp.home"), systemImage: Symbols.home) }
                    .accessibilityIdentifier("ssh.toolbar.sftp.home")
                Divider()
                Button { browser.naming = .newFolder } label: { Label(L("ssh.sftp.newFolderEllipsis"), systemImage: Symbols.newFolder) }
                    .accessibilityIdentifier("ssh.toolbar.sftp.newFolder")
                Button { if let entry = browser.selected.first { browser.naming = .rename(entry) } } label: { Label(L("ssh.sftp.renameEllipsis"), systemImage: Symbols.edit) }
                    .disabled(browser.selected.count != 1).accessibilityIdentifier("ssh.toolbar.sftp.rename")
                Button(role: .destructive) { browser.deleting = browser.selected } label: { Label(L("ssh.sftp.deleteEllipsis"), systemImage: Symbols.delete) }
                    .disabled(browser.selected.isEmpty).accessibilityIdentifier("ssh.toolbar.sftp.delete")
                Divider()
                Button { Task { await browser.load(nil) } } label: { Label(L("common.refresh"), systemImage: Symbols.reload) }
                    .accessibilityIdentifier("ssh.toolbar.sftp.reload")
            } label: {
                Label(L("ssh.sftp.menu"), systemImage: Symbols.folder)
            }
            .help(L("ssh.sftp.menuHelp")).accessibilityIdentifier("ssh.toolbar.sftp.menu")
        }
    }
}

extension SFTPBrowser {
    /// The parent folder (⌘↑ and Archivo › Carpeta superior).
    func goUp() { if let up = parent { Task { await load(up) } } }

    /// Files or folders of this Mac to upload into the folder shown.
    func chooseUploads() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.message = String(format: L("ssh.sftp.uploadMessage"), path)
        if panel.runModal() == .OK { Task { await upload(panel.urls) } }
    }

    /// Downloads into a folder the user picks; a file already there asks before it is replaced.
    func chooseDownload(_ items: [SFTPEntry]) {
        guard !items.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = L("ssh.sftp.downloadHere")
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        Task {
            for entry in items {
                do { try await download(entry, to: folder) } catch let failure as EngineFailure where failure.code == "sftp_exists" {
                    overwrite = Overwrite(entry: entry, folder: folder)
                    return
                } catch { StackStore.shared.report(error); return }
            }
        }
    }
}

private struct TransfersPanel: View {
    @Bindable var browser: SFTPBrowser
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L("ssh.sftp.transfers")).font(.uiCallout.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button { browser.clearFinished() } label: { Label(L("ssh.sftp.clearFinished"), systemImage: Symbols.remove) }
                    .buttonStyle(.bordered).controlSize(.small)
                    .disabled(!browser.transfers.contains { $0.state != .running }).accessibilityIdentifier("ssh.sftp.clearFinished")
            }
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(browser.transfers) { transfer in TransferRow(browser: browser, transfer: transfer) }
                }
            }
            .frame(maxHeight: 130)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .accessibilityIdentifier("ssh.sftp.transfers")
    }
}

private struct TransferRow: View {
    let browser: SFTPBrowser
    @Bindable var transfer: SFTPTransfer
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: transfer.upload ? Symbols.share : Symbols.dump)
                .foregroundStyle(transfer.state == .failed ? Brand.danger : transfer.state == .done ? Brand.success : .secondary)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(transfer.name).font(.uiCallout.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(status).font(.uiCaption).foregroundStyle(.secondary).monospacedDigit()
                }
                ProgressView(value: transfer.progress).progressViewStyle(.linear)
                    .tint(transfer.state == .failed ? Brand.danger : nil)
                if transfer.state == .failed, !transfer.detail.isEmpty {
                    Text(transfer.detail).font(.uiCaption).foregroundStyle(Brand.danger).lineLimit(2)
                }
            }
            if transfer.state == .running {
                Button { browser.cancel(transfer) } label: { Label(L("ssh.sftp.cancel"), systemImage: Symbols.close).labelStyle(.iconOnly) }
                    .buttonStyle(.borderless).help(L("ssh.sftp.cancel")).accessibilityIdentifier("ssh.sftp.cancel")
            }
        }
    }
    var status: String {
        switch transfer.state {
        case .running: "\(Int(transfer.progress * 100)) %"
        case .done: L("ssh.sftp.done")
        case .failed: L("ssh.sftp.failedShort")
        }
    }
}

/// A single name (new folder, rename): no slashes.
private struct SFTPNameSheet: View {
    let title: String
    let initial: String
    let action: String
    let save: (String) async -> Void
    @State private var name: String
    init(title: String, initial: String, action: String, save: @escaping (String) async -> Void) {
        self.title = title
        self.initial = initial
        self.action = action
        self.save = save
        _name = State(initialValue: initial)
    }
    var valid: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && trimmed != "." && trimmed != ".." && !name.contains("/") && name != initial
            && !name.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
    var body: some View {
        SheetFrame(title: title, symbol: Symbols.folder, width: 420, actionTitle: action, actionID: "ssh.sftp.nameSave", canAct: valid,
                   cancelID: "ssh.sftp.nameCancel") {
            await save(name)
            return true
        } content: {
            Form {
                TextField(L("common.name"), text: $name).formField(L("common.name")).accessibilityIdentifier("ssh.sftp.nameField")
            }
            .formStyle(.grouped).themedScroll()
            .frame(minHeight: 70)
        }
    }
}
