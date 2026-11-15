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

    @discardableResult static func set(_ value: String, for id: String, label: String) -> Bool {
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

    static func delete(_ id: String) { SecItemDelete(base(id) as CFDictionary) }

    /// A random password the database accepts (letters, digits and safe symbols).
    static func generate(length: Int = 24) -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789-_.!@#%+=")
        var bytes = [UInt8](repeating: 0, count: length)
        _ = SecRandomCopyBytes(kSecRandomDefault, length, &bytes)
        return String(bytes.map { alphabet[Int($0) % alphabet.count] })
    }
}
