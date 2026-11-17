import Foundation
import Security

/// Passwords of database connections, only in the macOS Keychain: one generic password per
/// connection id, this device only, never synchronized. The engine receives them per request and
/// never writes them to disk (beyond a 0600 options file that lives while the client runs).
enum DatabaseVault {
    /// A QA store (BUTAKE_STACK_HOME) keeps its passwords apart from the real ones.
    static let service = "cl.butake.stack.db" + (ProcessInfo.processInfo.environment["BUTAKE_STACK_HOME"] == nil ? "" : ".qa")
    /// The stack's MySQL root password (set from Servicios › Bases de datos).
    static let mysqlRoot = "stack-mysql"

    private static func base(_ id: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: id,
         kSecAttrSynchronizable as String: false]
    }

    /// Passwords already read this run, by id (a missing password is cached too). Written under
    /// `lock`; invalidated by every set/delete and by `forget`.
    private nonisolated(unsafe) static var cache: [String: String?] = [:]
    private static let lock = NSLock()
    /// Bumped by every invalidation: a Keychain read that started before one is not cached.
    private nonisolated(unsafe) static var epoch = 0

    /// Forgets the cached password of a connection (disconnect, or after an outside change).
    static func forget(_ id: String) {
        lock.withLock { cache[id] = nil; epoch += 1 }
    }

    /// The password without blocking the caller: a cache hit answers at once; otherwise the
    /// Keychain is read off the main actor and the answer is kept in memory.
    static func password(_ id: String) async -> String? {
        let (hit, start) = lock.withLock { (cache[id], epoch) }
        if let hit { return hit }
        let value = await Task.detached { get(id) }.value
        lock.withLock { if epoch == start { cache[id] = .some(value) } }
        return value
    }

    @discardableResult static func set(_ value: String, for id: String, label: String) -> Bool {
        forget(id)
        let query = base(id)
        let data = Data(value.utf8)
        if SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecSuccess { return true }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        add[kSecAttrLabel as String] = "Stack · \(label)"
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func get(_ id: String) -> String? {
        var query = base(id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    static func has(_ id: String) -> Bool {
        var query = base(id)
        query[kSecReturnAttributes as String] = true
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    static func delete(_ id: String) {
        forget(id)
        SecItemDelete(base(id) as CFDictionary)
    }

    /// Deletes the connection's password and every `user:<id>/<name>` item of its server users.
    static func deleteAll(connection id: String) {
        delete(id)
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecReturnAttributes as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitAll]
        query[kSecAttrSynchronizable as String] = false
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let items = result as? [[String: Any]] else { return }
        for item in items {
            if let account = item[kSecAttrAccount as String] as? String, account.hasPrefix("user:\(id)/") { delete(account) }
        }
    }

    /// A random password the database accepts (letters, digits and safe symbols).
    static func generate(length: Int = 24) -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789-_.!@#%+=")
        var bytes = [UInt8](repeating: 0, count: length)
        _ = SecRandomCopyBytes(kSecRandomDefault, length, &bytes)
        return String(bytes.map { alphabet[Int($0) % alphabet.count] })
    }
}
