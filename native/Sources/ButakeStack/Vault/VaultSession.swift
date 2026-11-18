import AppKit
import CryptoKit
import Foundation
import LocalAuthentication

/// Asks for user presence: Touch ID or the Mac's password.
@MainActor protocol VaultAuthenticator {
    func authenticate(_ reason: String) async -> LAContext?
}

/// Always a real prompt: macOS's reuse of a recent unlock (`touchIDAuthenticationAllowableReuseDuration`)
/// stays at 0 so a recent Touch ID of the Mac never approves silently.
struct SystemVaultAuthenticator: VaultAuthenticator {
    func authenticate(_ reason: String) async -> LAContext? {
        let context = LAContext()
        context.touchIDAuthenticationAllowableReuseDuration = 0
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return nil }
        do { return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) ? context : nil } catch { return nil }
    }
}

/// Tests and QA windows only.
struct ApprovingVaultAuthenticator: VaultAuthenticator {
    func authenticate(_ reason: String) async -> LAContext? { LAContext() }
}

/// The vault while the app runs: locked or unlocked (the key only in memory, for a few minutes of
/// use), the decrypted index, and every action, each written to the access log without values.
@MainActor @Observable final class VaultSession {
    enum State: Equatable { case unknown, absent, locked, unlocked, missingKey, unreadable }
    enum Selection: Hashable { case container(UUID), expiring }
    enum ExpiryFilter: String, CaseIterable, Identifiable { case all, soon, expired; var id: String { rawValue } }
    enum Sheet: Identifiable, Equatable {
        case newContainer(VaultContainer.Kind), editContainer(UUID), item(VaultItem), exportArchive(UUID?), importArchive(URL),
             importFolder([VaultFolder.Group], linked: [String]), download(UUID?), moveToEnvironments(UUID), moveToKeys(UUID), lastImport
        var id: String {
            switch self {
            case .newContainer(let kind): "new-\(kind.rawValue)"
            case .editContainer(let id): "edit-\(id)"
            case .item(let item): "item-\(item.id)"
            case .exportArchive(let id): "export-\(id?.uuidString ?? "all")"
            case .importArchive(let url): "import-\(url.path)"
            case .importFolder: Symbols.folder
            case .download(let id): "download-\(id?.uuidString ?? "all")"
            case .moveToEnvironments(let id): "moveEnv-\(id)"
            case .moveToKeys(let id): "moveKey-\(id)"
            case .lastImport: "lastImport"
            }
        }
    }

    static let shared = VaultSession.make()

    private(set) var state: State = .unknown
    /// True while the vault is being created (the prompt for presence is open): the button waits.
    private(set) var creating = false
    private(set) var index = VaultIndex()
    var selection: Selection?
    /// The item shown in the inspector beside its app or service.
    var inspected: UUID?
    /// The app whose «Firma» is open in place of its page, and the stage it shows.
    var signing: UUID?
    var signingEnvironment: VaultEnvironment = .prod
    var search = ""
    var kindFilter: VaultItemKind?
    var expiryFilter: ExpiryFilter = .all
    var sheet: Sheet?
    var message: String?
    var notice: String?
    var working: String?
    /// Values shown for a moment after an explicit reveal (field id → value); cleared on lock.
    var revealed: [UUID: String] = [:]
    /// Auto-hide timers of revealed values, by field, so revealing again restarts the 30 s.
    @ObservationIgnored var hideTasks: [UUID: Task<Void, Never>] = [:]

    let disk: VaultDisk
    @ObservationIgnored let keys: VaultKeyStore
    @ObservationIgnored let auth: VaultAuthenticator
    @ObservationIgnored var timeout: TimeInterval = 300
    @ObservationIgnored var archiveIterations = VaultArchive.defaultIterations
    @ObservationIgnored private var key: SymmetricKey?
    @ObservationIgnored private(set) var sessionGeneration = UUID()
    @ObservationIgnored private var lastActivity = Date()
    @ObservationIgnored private var lastSensitive: Date?
    @ObservationIgnored private var watcher: Task<Void, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    /// A sheet asked for from elsewhere ("Respaldar bóveda" in Mi entorno), shown once unlocked.
    @ObservationIgnored private var pendingSheet: Sheet?
    /// Folders a link proposes to import (`butakestack://vault/import`), only read once unlocked.
    var proposedFolders: [URL] = []
    /// The names of the folders in the import preview, for its summary.
    @ObservationIgnored var importFolders: [String] = []
    /// A folder being scanned for the import preview (off the main actor).
    var scanningImport = false
    /// Files of a folder import stored so far, and how many there are.
    var importProgress: (done: Int, total: Int)?

    init(disk: VaultDisk, keys: VaultKeyStore, auth: VaultAuthenticator) {
        self.disk = disk
        self.keys = keys
        self.auth = auth
    }

    private static func make() -> VaultSession {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        // A separate store (QA, tests) never touches the real Keychain entry.
        let isolated = environment["BUTAKE_STACK_HOME"] != nil
        let auth: VaultAuthenticator
        if isolated && StackStore.qaWindow && environment["BUTAKE_QA_VAULT"] != nil {
            auth = ApprovingVaultAuthenticator()
        } else {
            auth = SystemVaultAuthenticator()
        }
        // BUTAKE_QA_VAULT_MEMORY: a QA window whose key lives only in memory (a temporary HOME has no Keychain).
        let keys: VaultKeyStore = isolated && StackStore.qaWindow && environment["BUTAKE_QA_VAULT_MEMORY"] != nil ? MemoryVaultKeyStore()
            : isolated ? KeychainVaultKeyStore.qa : KeychainVaultKeyStore.production
        #else
        let auth = SystemVaultAuthenticator()
        let keys = KeychainVaultKeyStore.production
        #endif
        let session = VaultSession(disk: VaultDisk(root: VaultDisk.defaultRoot()), keys: keys, auth: auth)
        session.watchSystem()
        return session
    }

    var isUnlocked: Bool { state == .unlocked && key != nil }

    /// The encrypted backup of everything: right away if unlocked, otherwise right after unlocking.
    func requestBackup() {
        if isUnlocked { sheet = .exportArchive(nil) } else { pendingSheet = .exportArchive(nil) }
    }

    private func showPending() {
        if let pending = pendingSheet { pendingSheet = nil; sheet = pending }
        else if !proposedFolders.isEmpty { previewProposed() }
    }

    func refreshState() {
        guard !isUnlocked else { return }
        if !disk.exists { state = .absent; return }
        state = (try? disk.readHeader()) == nil ? .unreadable : .locked
    }

    // MARK: Lock and unlock

    /// Creates an empty vault and its key (asks for user presence first).
    @discardableResult func create() async -> Bool {
        // One creation at a time, and the check repeated after the prompt: a second click, or another window, may have
        // created the vault meanwhile, and a second creation would write a new key and index over the first.
        guard !creating, !disk.exists else { refreshState(); return false }
        creating = true; defer { creating = false }
        guard await auth.authenticate(L("vault.auth.create")) != nil else { message = L(VaultError.authentication.messageKey); return false }
        guard !disk.exists else { refreshState(); return false }
        let keyId = UUID().uuidString
        do {
            try disk.prepare()
            let newKey = try keys.create(keyId: keyId)
            try disk.saveIndex(VaultIndex(), key: newKey)
            try disk.writeHeader(VaultDisk.Header(keyId: keyId))
            key = newKey
            index = VaultIndex()
            state = .unlocked
            touch()
            disk.append(VaultAccessEntry(action: .create))
            startWatching()
            showPending()
            return true
        } catch let error as VaultError {
            keys.delete(keyId: keyId)
            message = L(error.messageKey); return false
        } catch {
            keys.delete(keyId: keyId)
            message = L(VaultError.io.messageKey); return false
        }
    }

    func unlock() async {
        guard !isUnlocked else { return }
        guard let header = try? disk.readHeader() else { refreshState(); return }
        guard let context = await auth.authenticate(L("vault.auth.unlock")) else {
            disk.append(VaultAccessEntry(action: .unlockFailed))
            message = L(VaultError.authentication.messageKey)
            return
        }
        do {
            let loaded = try keys.load(keyId: header.keyId, context: context)
            index = try disk.loadIndex(key: loaded)
            key = loaded
            state = .unlocked
            lastSensitive = nil
            touch()
            disk.clearTemporary()
            disk.append(VaultAccessEntry(action: .unlock))
            startWatching()
            showPending()
            Self.onUnlock?()
        } catch VaultError.missingKey {
            state = .missingKey
        } catch let error as VaultError {
            disk.append(VaultAccessEntry(action: .unlockFailed))
            message = L(error.messageKey)
        } catch { message = L(VaultError.io.messageKey) }
    }

    func lock() {
        guard key != nil else { return }
        key = nil
        sessionGeneration = UUID()
        index = VaultIndex()
        revealed = [:]
        hideTasks.values.forEach { $0.cancel() }
        hideTasks = [:]
        inspected = nil
        signing = nil
        sheet = nil
        lastSensitive = nil
        state = disk.exists ? .locked : .absent
        watcher?.cancel()
        watcher = nil
        clearClipboardIfOurs()
        disk.clearTemporary()
        disk.append(VaultAccessEntry(action: .lock))
    }

    /// Any use keeps the session open; five minutes without it, it locks.
    func touch() { lastActivity = Date() }

    /// A vault whose key isn't in this Mac's Keychain: set aside (renamed, never deleted) to start over.
    func setAsideUnreadable() {
        let stamp = Format.fileStamp(time: true)
        let target = disk.root.deletingLastPathComponent().appendingPathComponent("vault-sin-clave-\(stamp)")
        do { try FileManager.default.moveItem(at: disk.root, to: target) } catch { message = L(VaultError.io.messageKey); return }
        state = .absent
    }

    private func startWatching() {
        watcher?.cancel()
        watcher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self else { return }
                if self.isUnlocked && Date().timeIntervalSince(self.lastActivity) > self.timeout { self.lock() }
            }
        }
    }

    /// Sleep, screen lock and screen saver lock the vault.
    private func watchSystem() {
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.lock() }
            })
        }
        let distributed = DistributedNotificationCenter.default()
        for name in ["com.apple.screenIsLocked", "com.apple.screensaver.didstart"] {
            observers.append(distributed.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.lock() }
            })
        }
    }

    func requireKey() throws -> SymmetricKey {
        guard let key, state == .unlocked else { throw VaultError.locked }
        if Date().timeIntervalSince(lastActivity) > timeout { lock(); throw VaultError.locked }
        touch()
        return key
    }

    /// Reveal and copy: a prompt answered in the last 60 s counts. Export, download and saving a file
    /// always prompt (`fresh`).
    func confirmPresence(_ reason: String, fresh: Bool) async -> Bool {
        guard isUnlocked else { return false }
        if !fresh, let last = lastSensitive, Date().timeIntervalSince(last) < 60 { touch(); return true }
        let generation = sessionGeneration
        guard await auth.authenticate(reason) != nil, isUnlocked, generation == sessionGeneration else { return false }
        if !fresh { lastSensitive = Date() }
        touch()
        return true
    }

    func persist(_ candidate: VaultIndex) throws {
        try disk.saveIndex(candidate, key: try requireKey())
        index = candidate
    }

    func checkSession(_ generation: UUID) throws {
        try Task.checkCancellation()
        guard isUnlocked, sessionGeneration == generation else { throw VaultError.locked }
    }

    // MARK: Containers (the rest in VaultSession+Containers.swift)

    /// Notes for a container that has none yet (the README of a folder brought in later).
    func fillNotes(_ notes: String, of container: UUID) {
        guard let position = index.containers.firstIndex(where: { $0.id == container }), index.containers[position].notes.isEmpty else { return }
        index.containers[position].notes = notes
    }

    // MARK: Items

    /// Files dropped from Finder or chosen in a panel: copied (the original stays), encrypted, checked.
    @discardableResult func add(files urls: [URL], to container: UUID, section: VaultSection?) async -> Int {
        let generation = sessionGeneration
        var added = 0, retired = 0
        defer { if retired > 0, isUnlocked { message = L("vault.retiredSkipped") } }
        for url in urls {
            guard (try? checkSession(generation)) != nil else { break }
            let attachment: (String, Data)
            do {
                attachment = try await Task.detached(priority: .userInitiated) {
                    try VaultDisk.readAttachment(url)
                }.value
                try checkSession(generation)
            } catch {
                if isUnlocked && !Task.isCancelled { message = L("vault.error.fileSkipped") }
                continue
            }
            let (name, data) = attachment
            let kind = VaultInspector.detectKind(name: name, data: data)
            // A project's .env and Stack's SSH keys have their own place (Entornos, Ajustes › Claves SSH).
            if kind.isRetired { retired += 1; continue }
            let item = VaultItem(container: container, section: section ?? kind.defaultSection ?? (index.container(container)?.kind == .app ? .terceros : nil),
                                 kind: kind, name: name, fields: VaultInspector.suggestedFields(kind: kind, fileName: name))
            if (try? await store(item, files: [(name, data)])) != nil { added += 1 }
        }
        return added
    }

    /// Stores a new item with its files; each blob is read back and its hash compared before the index changes.
    @discardableResult func store(_ draft: VaultItem, files: [(String, Data)]) async throws -> VaultItem {
        let generation = sessionGeneration
        let item = try await stageItem(draft, files: files)
        do {
            try checkSession(generation)
            guard index.container(item.container) != nil else { throw VaultError.invalidName }
            var candidate = index
            candidate.items.append(item)
            try persist(candidate)
        } catch {
            for file in item.files { disk.deleteBlob(file.id) }
            throw error
        }
        disk.append(VaultAccessEntry(action: .addItem, target: item.id))
        return item
    }

    /// Encrypts the files of a new item and reads its metadata, without touching the index: the
    /// caller persists it (`store` one at a time, a folder import a group at a time). The blobs are
    /// removed again if this fails.
    func stageItem(_ draft: VaultItem, files: [(String, Data)]) async throws -> VaultItem {
        let key = try requireKey()
        let generation = sessionGeneration
        var item = draft
        let disk = self.disk
        let work = Task.detached(priority: .userInitiated) { try disk.stageAttachments(files, key: key) }
        let staged = try await withTaskCancellationHandler {
            try await work.value
        } onCancel: { work.cancel() }
        do {
            item.files.append(contentsOf: staged)
            try checkSession(generation)
            if let first = files.first { item.metadata = await inspect(item, data: first.1, fileName: first.0) }
            try checkSession(generation)
            item.created = Date()
            item.updated = Date()
        } catch {
            for file in staged { disk.deleteBlob(file.id) }
            throw error
        }
        return item
    }

    /// Saves an edited item; metadata is read again (a password may have just been added).
    func save(_ edited: VaultItem, newFile: URL? = nil) async throws {
        let key = try requireKey()
        let generation = sessionGeneration
        var item = edited
        var written: UUID?
        var committed = false
        defer { if !committed, let written { disk.deleteBlob(written) } }
        let previous = index.item(item.id)
        let disk = self.disk
        if let newFile {
            let staged = try await Task.detached(priority: .userInitiated) {
                let attachment = try VaultDisk.readAttachment(newFile)
                return try disk.stageAttachments([attachment], key: key)
            }.value
            written = staged.first?.id
            item.files.append(contentsOf: staged)
        }
        try checkSession(generation)
        if let first = item.files.first {
            let data = await Task.detached(priority: .userInitiated) {
                try? disk.readBlob(first.id, key: key)
            }.value
            try checkSession(generation)
            if let data { item.metadata = await inspect(item, data: data, fileName: first.name) }
        }
        try checkSession(generation)
        guard index.container(item.container) != nil, index.item(item.id)?.updated == previous?.updated else { throw VaultError.io }
        item.updated = Date()
        var candidate = index
        if let position = candidate.items.firstIndex(where: { $0.id == item.id }) {
            candidate.items[position] = item
        } else {
            candidate.items.append(item)
        }
        try persist(candidate)
        committed = true
        // Files taken out of the item go with it.
        for file in previous?.files ?? [] where !item.files.contains(where: { $0.id == file.id }) { disk.deleteBlob(file.id) }
        disk.append(VaultAccessEntry(action: previous == nil ? .addItem : .editItem, target: item.id))
    }

    func delete(_ item: VaultItem) throws {
        _ = try requireKey()
        var candidate = index
        candidate.items.removeAll { $0.id == item.id }
        try persist(candidate)
        for file in item.files { disk.deleteBlob(file.id) }
        disk.append(VaultAccessEntry(action: .deleteItem, target: item.id))
    }

    func inspect(_ item: VaultItem, data: Data, fileName: String) async -> VaultMetadata {
        let disk = disk
        return await Task.detached(priority: .userInitiated) {
            VaultInspector.inspect(item: item, data: data, fileName: fileName, keytool: VaultInspector.keytool(), disk: disk)
        }.value
    }

    // MARK: Views of the index

    func accessLog() -> [VaultAccessEntry] { disk.readLog() }

    /// The access log read and decoded off the main actor (newest first). `nil` when the file did
    /// not change since `modified`; the new modification date comes back with the entries.
    func accessLog(since modified: Date?) async -> (entries: [VaultAccessEntry]?, modified: Date?) {
        let disk = disk
        return await Task.detached(priority: .utility) {
            let date = (try? FileManager.default.attributesOfItem(atPath: disk.logURL.path)[.modificationDate]) as? Date
            if let modified, let date, date == modified { return (nil, date) }
            return (disk.readLog(), date)
        }.value
    }

    /// What a log line points at, by name, while unlocked.
    func targetName(_ id: UUID?) -> String? {
        guard let id else { return nil }
        if let item = index.item(id) { return [index.container(item.container)?.name, item.name].compactMap { $0 }.joined(separator: " · ") }
        return index.container(id)?.name
    }

    func matches(_ item: VaultItem) -> Bool {
        if let kindFilter, item.kind != kindFilter { return false }
        switch expiryFilter {
        case .all: break
        case .soon: guard let expiry = item.expiry(), expiry >= .soon else { return false }
        case .expired: guard item.expiry() == .expired else { return false }
        }
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return true }
        let haystack = [item.name, L("vault.kind.\(item.kind.rawValue)"), item.notes] + item.files.map(\.name)
            + item.metadata.entries.map(\.value) + item.fields.map(\.title) + item.fields.compactMap(\.envVar)
        return haystack.contains { $0.localizedCaseInsensitiveContains(query) }
    }

    func visibleItems(in container: UUID) -> [VaultItem] {
        index.items(in: container).filter(matches).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var expiringItems: [VaultItem] {
        index.items.filter { ($0.expiry() ?? .ok) >= .soon }.sorted { ($0.metadata.expires ?? .distantFuture) < ($1.metadata.expires ?? .distantFuture) }
    }

    func worstExpiry(in container: UUID) -> VaultItem.Expiry? {
        index.items(in: container).compactMap { $0.expiry() }.filter { $0 >= .soon }.max()
    }
}
