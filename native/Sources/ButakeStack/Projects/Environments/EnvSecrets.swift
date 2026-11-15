import Foundation
import Security

/// Where Entornos keeps secret values: the Keychain in the app (`EnvSecrets.keychain`), memory in
/// QA windows and tests. One environment at a time, so a read asks macOS for access at most once.
protocol EnvSecretStore: Sendable {
    /// Every secret value of an environment. Throws, without changing anything, when the Keychain
    /// refuses (the user denied access) or the item cannot be read.
    func values(site: String, env: String) throws -> [String: String]
    /// Sets and removes values in one write; the result is read back before returning.
    func update(site: String, env: String, set: [String: String], remove: Set<String>) throws
}

/// The secrets of each environment of a project, in a single Keychain item (account `site/env`) whose
/// data is JSON `name → value`, this device only, never synchronized. Its attributes (never the
/// values) carry the names, so the page knows which secrets are stored without reading any.
///
/// Earlier versions kept one item per variable (account `site/env/key`). They are migrated the first
/// time an environment is read: each one is read (macOS may ask once per old item), the single item is
/// written and read back, and only then are the old ones deleted. If the user denies access nothing is
/// written or deleted and the next read tries again. An old item macOS does not let this build delete
/// (it belongs to the build that created it) stays, listed in `migrated` and ignored from then on.
struct EnvSecrets: EnvSecretStore {
    enum Failure: Error, Equatable {
        /// The Keychain refused or failed (`errSecAuthFailed` when the user denied access).
        case unavailable(OSStatus)
        case corrupt, write, verification
    }

    /// What the single item holds. `migrated`: names of old per-variable items already merged.
    struct Content: Codable, Equatable, Sendable {
        var version = 1
        var values: [String: String] = [:]
        var migrated: [String] = []
    }

    /// Names kept in the item's attributes, readable without asking for access.
    struct Names: Codable, Equatable, Sendable {
        var names: [String]
        var migrated: [String]
    }

    let items: KeychainItems

    /// A QA store (BUTAKE_STACK_HOME) keeps its secrets apart from the real ones.
    static let service = "cl.butake.stack.env" + (ProcessInfo.processInfo.environment["BUTAKE_STACK_HOME"] == nil ? "" : ".qa")
    static let keychain = EnvSecrets(items: KeychainItemStore(service: service))

    static func account(_ site: String, _ env: String) -> String { "\(site)/\(env)" }

    // MARK: Without reading values

    /// Which secrets of the environment have a value, from attributes only (no access prompt).
    func storedKeys(site: String, env: String) -> Set<String> {
        let account = Self.account(site, env)
        let entries = items.list(prefix: account)
        let names = entries.first { $0.account == account }.flatMap { $0.attributes.flatMap { try? JSONDecoder().decode(Names.self, from: $0) } }
        let legacy = Set(entries.compactMap { Self.legacyKey($0.account, of: account) }).subtracting(names?.migrated ?? [])
        return legacy.union(names?.names ?? [])
    }

    /// Every item of a project, or of one of its environments, old ones included.
    func deleteAll(site: String, env: String? = nil) {
        let prefix = env.map { Self.account(site, $0) } ?? "\(site)/"
        for entry in items.list(prefix: prefix) {
            guard env == nil || entry.account == prefix || entry.account.hasPrefix(prefix + "/") else { continue }
            let single = entry.account.split(separator: "/", omittingEmptySubsequences: false).count == 2
            items.remove(entry.account, quietly: !single)
        }
    }

    // MARK: Reading and writing

    func values(site: String, env: String) throws -> [String: String] { try content(site: site, env: env).values }

    func update(site: String, env: String, set: [String: String], remove: Set<String>) throws {
        guard !set.isEmpty || !remove.isEmpty else { return }
        var content = try content(site: site, env: env)
        let before = content
        for key in remove { content.values[key] = nil }
        content.values.merge(set) { _, new in new }
        guard content != before else { return }
        let account = Self.account(site, env)
        if content.values.isEmpty && content.migrated.isEmpty {
            guard items.remove(account, quietly: false) else { throw Failure.write }
        } else {
            try save(content, account: account, site: site, env: env)
        }
    }

    /// The single item, after migrating any old per-variable item it does not account for yet.
    private func content(site: String, env: String) throws -> Content {
        let account = Self.account(site, env)
        var content = Content()
        switch items.read(account) {
        case .found(let data):
            guard let decoded = try? JSONDecoder().decode(Content.self, from: data) else { throw Failure.corrupt }
            content = decoded
        case .missing: break
        case .failed(let status): throw Failure.unavailable(status)
        }
        let legacy = Set(items.list(prefix: account).compactMap { Self.legacyKey($0.account, of: account) }).subtracting(content.migrated)
        guard !legacy.isEmpty else { return content }
        var merged: [String: String] = [:]
        for key in legacy.sorted() {
            switch items.read("\(account)/\(key)") {
            case .found(let data): merged[key] = String(decoding: data, as: UTF8.self)
            case .missing: continue
            case .failed(let status): throw Failure.unavailable(status)
            }
        }
        // A value written after the old items (in the single item) wins.
        merged.merge(content.values) { _, new in new }
        content.values = merged
        content.migrated = Set(content.migrated).union(legacy).sorted()
        try save(content, account: account, site: site, env: env)
        for key in legacy { items.remove("\(account)/\(key)", quietly: true) }
        return content
    }

    private func save(_ content: Content, account: String, site: String, env: String) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(content),
              let names = try? encoder.encode(Names(names: content.values.keys.sorted(), migrated: content.migrated)) else { throw Failure.write }
        guard items.write(data, account: account, label: "Stack · \(site) · \(env)", attributes: names) else { throw Failure.write }
        guard case .found(let back) = items.read(account), (try? JSONDecoder().decode(Content.self, from: back)) == content else { throw Failure.verification }
    }

    /// `site/env/KEY` → `KEY` for the old items of `site/env`.
    private static func legacyKey(_ account: String, of environment: String) -> String? {
        guard account.hasPrefix(environment + "/") else { return nil }
        let key = String(account.dropFirst(environment.count + 1))
        return key.isEmpty || key.contains("/") ? nil : key
    }
}

// MARK: - Generic passwords of one service

enum KeychainRead: Equatable, Sendable {
    case found(Data)
    case missing
    case failed(OSStatus)
}

/// An item's account and the non-secret data kept in its attributes.
struct KeychainEntry: Equatable, Sendable {
    let account: String
    let attributes: Data?
}

/// Generic passwords of one service. The Keychain in the app; memory in QA and tests.
protocol KeychainItems: Sendable {
    func read(_ account: String) -> KeychainRead
    /// Adds the item or replaces its data, label and attributes.
    func write(_ data: Data, account: String, label: String, attributes: Data?) -> Bool
    /// Attributes only, never a value: no access prompt.
    func list(prefix: String) -> [KeychainEntry]
    /// `quietly`: never shows a dialog; an item macOS does not let this build delete stays.
    @discardableResult func remove(_ account: String, quietly: Bool) -> Bool
}

/// The login Keychain, this device only, never synchronized.
struct KeychainItemStore: KeychainItems {
    let service: String

    private func base(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: false]
    }

    func read(_ account: String) -> KeychainRead {
        var query = base(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return .missing }
        guard status == errSecSuccess, let data = result as? Data else { return .failed(status) }
        return .found(data)
    }

    func write(_ data: Data, account: String, label: String, attributes: Data?) -> Bool {
        let query = base(account)
        var change: [String: Any] = [kSecValueData as String: data, kSecAttrLabel as String: label]
        if let attributes { change[kSecAttrGeneric as String] = attributes }
        let updated = SecItemUpdate(query as CFDictionary, change as CFDictionary)
        if updated == errSecSuccess { return true }
        guard updated == errSecItemNotFound else { return false }
        var add = query.merging(change) { _, new in new }
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    func list(prefix: String) -> [KeychainEntry] {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitAll]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let found = result as? [[String: Any]] else { return [] }
        return found.compactMap { item in
            guard let account = item[kSecAttrAccount as String] as? String, account.hasPrefix(prefix) else { return nil }
            return KeychainEntry(account: account, attributes: item[kSecAttrGeneric as String] as? Data)
        }
    }

    @discardableResult func remove(_ account: String, quietly: Bool) -> Bool {
        let status = quietly ? Self.withoutInteraction { SecItemDelete(base(account) as CFDictionary) } : SecItemDelete(base(account) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// Runs a Keychain call with its dialogs turned off (they return an error instead). Deleting an
    /// item that another build created is refused by macOS (`errSecInvalidOwnerEdit`); this makes
    /// sure the attempt never turns into a dialog. The switch is looked up at run time because the
    /// login Keychain's API for it is deprecated without a replacement for deleting.
    private static func withoutInteraction(_ body: () -> OSStatus) -> OSStatus {
        typealias Setter = @convention(c) (DarwinBoolean) -> OSStatus
        typealias Getter = @convention(c) (UnsafeMutablePointer<DarwinBoolean>) -> OSStatus
        let handle = UnsafeMutableRawPointer(bitPattern: -2) // RTLD_DEFAULT
        guard let setter = dlsym(handle, "SecKeychainSetUserInteractionAllowed"), let getter = dlsym(handle, "SecKeychainGetUserInteractionAllowed") else { return errSecInteractionNotAllowed }
        let set = unsafeBitCast(setter, to: Setter.self), get = unsafeBitCast(getter, to: Getter.self)
        var previous: DarwinBoolean = true
        _ = get(&previous)
        _ = set(false)
        defer { _ = set(previous) }
        return body()
    }
}
