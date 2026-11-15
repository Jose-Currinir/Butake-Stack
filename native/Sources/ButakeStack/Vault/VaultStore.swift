import CryptoKit
import Foundation
import LocalAuthentication
import Security

/// The vault on disk, inside Stack's store (`vault/`): folders 0700, files 0600.
///
///     vault.json        format, version and the id of its key in the Keychain (no secrets)
///     index.bin         AES-GCM of the index (apps, services, items, fields)
///     blobs/<id>.bin    AES-GCM of each stored file
///     access.log        who did what and when (JSON lines; ids only, never names or values)
///     tmp/              short-lived copies for local tools (keytool), removed right after
struct VaultDisk: Sendable {
    let root: URL

    struct Header: Codable, Sendable { var format = "butake-stack-vault"; var version = 1; var keyId: String; var created = Date() }

    static func defaultRoot() -> URL {
        Folder.baseURL.appendingPathComponent("vault", isDirectory: true)
    }

    var headerURL: URL { root.appendingPathComponent("vault.json") }
    var indexURL: URL { root.appendingPathComponent("index.bin") }
    var blobsURL: URL { root.appendingPathComponent("blobs", isDirectory: true) }
    var logURL: URL { root.appendingPathComponent("access.log") }
    var tmpURL: URL { root.appendingPathComponent("tmp", isDirectory: true) }

    var exists: Bool { FileManager.default.fileExists(atPath: headerURL.path) }

    func prepare() throws {
        for url in [root, blobsURL, tmpURL] { try Self.makePrivateDirectory(url) }
    }

    static func makePrivateDirectory(_ url: URL) throws {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        if fm.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else { throw VaultError.io }
        } else {
            try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    /// Written to a 0600 temporary file, then renamed over the target (atomic, never world-readable).
    static func writePrivate(_ data: Data, to url: URL) throws {
        let temp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o600]) else { throw VaultError.io }
        guard rename(temp.path, url.path) == 0 else {
            try? FileManager.default.removeItem(at: temp)
            throw VaultError.io
        }
    }

    func readHeader() throws -> Header {
        guard let data = try? Data(contentsOf: headerURL) else { throw VaultError.io }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        guard let header = try? decoder.decode(Header.self, from: data), header.format == "butake-stack-vault" else { throw VaultError.corrupt }
        guard header.version == 1 else { throw VaultError.unsupported }
        return header
    }

    func writeHeader(_ header: Header) throws {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try Self.writePrivate(try encoder.encode(header), to: headerURL)
    }

    func loadIndex(key: SymmetricKey) throws -> VaultIndex {
        guard let sealed = try? Data(contentsOf: indexURL) else { throw VaultError.io }
        let plain = try VaultCrypto.open(sealed, key: key, context: "butake-vault/index/v1")
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        guard let index = try? decoder.decode(VaultIndex.self, from: plain) else { throw VaultError.corrupt }
        return index
    }

    func saveIndex(_ index: VaultIndex, key: SymmetricKey) throws {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let sealed = try VaultCrypto.seal(try encoder.encode(index), key: key, context: "butake-vault/index/v1")
        try Self.writePrivate(sealed, to: indexURL)
    }

    func blobURL(_ id: UUID) -> URL { blobsURL.appendingPathComponent("\(id.uuidString).bin") }

    func writeBlob(_ data: Data, id: UUID, key: SymmetricKey) throws {
        try Self.writePrivate(try VaultCrypto.seal(data, key: key, context: "butake-vault/blob/\(id.uuidString)"), to: blobURL(id))
    }

    func readBlob(_ id: UUID, key: SymmetricKey) throws -> Data {
        guard let sealed = try? Data(contentsOf: blobURL(id)) else { throw VaultError.io }
        return try VaultCrypto.open(sealed, key: key, context: "butake-vault/blob/\(id.uuidString)")
    }

    /// Prepare attachments away from the UI. The caller owns the files once returned.
    nonisolated func stageAttachments(_ inputs: [(String, Data)], key: SymmetricKey) throws -> [VaultFile] {
        var files: [VaultFile] = []
        do {
            for (name, data) in inputs {
                try Task.checkCancellation()
                guard data.count <= VaultFolder.maximumFileSize else { throw VaultError.tooLarge }
                let file = VaultFile(name: VaultNames.safeFileName(name), size: data.count, sha256: VaultCrypto.sha256(data))
                try writeBlob(data, id: file.id, key: key)
                files.append(file)
                guard VaultCrypto.sha256(try readBlob(file.id, key: key)) == file.sha256 else { throw VaultError.corrupt }
            }
            return files
        } catch {
            for file in files { deleteBlob(file.id) }
            throw error
        }
    }

    nonisolated static func readAttachment(_ url: URL) throws -> (String, Data) {
        let source = url.standardizedFileURL.resolvingSymlinksInPath()
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize else { throw VaultError.io }
        let limit = VaultFolder.maximumFileSize
        guard size <= limit else { throw VaultError.tooLarge }
        let handle = try FileHandle(forReadingFrom: source)
        defer { try? handle.close() }
        var data = Data()
        while let chunk = try handle.read(upToCount: min(256 * 1024, limit + 1 - data.count)), !chunk.isEmpty {
            try Task.checkCancellation()
            data.append(chunk)
            guard data.count <= limit else { throw VaultError.tooLarge }
        }
        return (source.lastPathComponent, data)
    }

    func deleteBlob(_ id: UUID) { try? FileManager.default.removeItem(at: blobURL(id)) }

    // MARK: Access log

    func append(_ entry: VaultAccessEntry) {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        guard var line = try? encoder.encode(entry) else { return }
        line.append(0x0A)
        let fm = FileManager.default
        if !fm.fileExists(atPath: logURL.path) {
            try? Self.makePrivateDirectory(root)
            fm.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let handle = try? FileHandle(forWritingTo: logURL) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: line)
        // Kept small: past 1 MB only the newest half stays.
        if let size = try? handle.offset(), size > 1_000_000, let data = try? Data(contentsOf: logURL) {
            let tail = data.suffix(500_000)
            let start = tail.firstIndex(of: 0x0A).map { tail.index(after: $0) } ?? tail.startIndex
            try? Self.writePrivate(Data(tail[start...]), to: logURL)
        }
    }

    func readLog(limit: Int = 500) -> [VaultAccessEntry] {
        guard let data = try? Data(contentsOf: logURL) else { return [] }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let lines = data.split(separator: 0x0A).suffix(limit)
        return lines.compactMap { try? decoder.decode(VaultAccessEntry.self, from: Data($0)) }.reversed()
    }

    /// Short-lived private copy for a local tool; the caller removes it.
    func temporaryCopy(_ data: Data, name: String) throws -> URL {
        try Self.makePrivateDirectory(tmpURL)
        let folder = tmpURL.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try Self.makePrivateDirectory(folder)
        let url = folder.appendingPathComponent(VaultNames.safeFileName(name))
        try Self.writePrivate(data, to: url)
        return url
    }

    func clearTemporary() {
        let fm = FileManager.default
        for url in (try? fm.contentsOfDirectory(at: tmpURL, includingPropertiesForKeys: nil)) ?? [] { try? fm.removeItem(at: url) }
    }
}

/// One line of the access log. Only ids: names and values never leave the encrypted index.
struct VaultAccessEntry: Codable, Sendable, Identifiable, Hashable {
    enum Action: String, Codable, Sendable, CaseIterable {
        case create, unlock, unlockFailed, lock, addItem, editItem, deleteItem, addContainer, editContainer, deleteContainer,
             reveal, copy, saveFile, exportArchive, importArchive, downloadFolder, importFolder, moveToEnvironments, moveToKeys
    }
    var id = UUID()
    var date = Date()
    var user = NSUserName()
    var action: Action
    var target: UUID?
}

// MARK: Master key

/// Where the vault's 256-bit key lives.
@MainActor protocol VaultKeyStore {
    func create(keyId: String) throws -> SymmetricKey
    func load(keyId: String, context: LAContext?) throws -> SymmetricKey
    func delete(keyId: String)
}

/// The key in the macOS Keychain: this device only, never synchronized. When the app is signed so it
/// can use the data protection keychain, the item also requires user presence (Touch ID or the Mac's
/// password) to be read; otherwise (an ad-hoc signed build) it goes to the login keychain and the app
/// asks for user presence itself before reading it (`VaultSession.authenticate`).
struct KeychainVaultKeyStore: VaultKeyStore {
    let service: String
    /// QA only: no access control, so tests never prompt.
    var requirePresence = true

    static let production = KeychainVaultKeyStore(service: "cl.butake.stack.vault")
    #if DEBUG
    static let qa = KeychainVaultKeyStore(service: "cl.butake.stack.vault.qa", requirePresence: false)
    #endif

    private func base(_ keyId: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: "master/\(keyId)",
         kSecAttrSynchronizable as String: false]
    }

    func create(keyId: String) throws -> SymmetricKey {
        let key = VaultCrypto.newKey()
        let data = key.withUnsafeBytes { Data($0) }
        var item = base(keyId)
        item[kSecValueData as String] = data
        item[kSecAttrLabel as String] = "Stack · Bóveda"
        if requirePresence, let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, .userPresence, nil) {
            var protected = item
            protected[kSecUseDataProtectionKeychain as String] = true
            protected[kSecAttrAccessControl as String] = access
            let status = SecItemAdd(protected as CFDictionary, nil)
            if status == errSecSuccess { return key }
            guard status == errSecMissingEntitlement else { throw VaultError.keychain(status) }
        }
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw VaultError.keychain(status) }
        return key
    }

    func load(keyId: String, context: LAContext?) throws -> SymmetricKey {
        var query = base(keyId)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        if requirePresence {
            var protected = query
            protected[kSecUseDataProtectionKeychain as String] = true
            if let context { protected[kSecUseAuthenticationContext as String] = context }
            let status = SecItemCopyMatching(protected as CFDictionary, &result)
            if status == errSecSuccess, let data = result as? Data, data.count == 32 { return SymmetricKey(data: data) }
            if status == errSecUserCanceled || status == errSecAuthFailed { throw VaultError.authentication }
        }
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { throw VaultError.missingKey }
        guard status == errSecSuccess, let data = result as? Data, data.count == 32 else { throw VaultError.keychain(status) }
        return SymmetricKey(data: data)
    }

    func delete(keyId: String) {
        var protected = base(keyId)
        protected[kSecUseDataProtectionKeychain as String] = true
        SecItemDelete(protected as CFDictionary)
        SecItemDelete(base(keyId) as CFDictionary)
    }
}
