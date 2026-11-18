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

    static let shared = DatabasePasswords(KeychainPasswords(service: service, labelPrefix: "Stack · "))

    static func forget(_ id: String) { shared.forget(id) }
    static func password(_ id: String) async -> String? { await shared.password(id) }
    @discardableResult static func set(_ value: String, for id: String, label: String) -> Bool { shared.set(value, for: id, label: label) }
    static func read(_ id: String) -> KeychainRead { shared.read(id) }
    static func get(_ id: String) -> String? { shared.get(id) }
    static func has(_ id: String) -> Bool { shared.has(id) }
    @discardableResult static func delete(_ id: String) -> Bool { shared.delete(id) }
    static func deleteAll(connection id: String) { shared.deleteAll(connection: id) }

    /// A random password the database accepts (letters, digits and safe symbols); nil when the system
    /// cannot give random bytes (never a predictable password).
    static func generate(length: Int = 24) -> String? { DatabasePasswords.generate(length: length) }
}

/// The passwords of one Keychain service with an in-memory cache of what was read.
final class DatabasePasswords: @unchecked Sendable {
    private let store: KeychainPasswords
    /// Passwords already read this run, by id (a password that is not there is cached too). Written under
    /// `lock`; invalidated by every set/delete and by `forget`. A failed read is never cached.
    private var cache: [String: String?] = [:]
    private let lock = NSLock()
    /// Bumped by every invalidation: a Keychain read that started before one is not cached.
    private var epoch = 0

    init(_ store: KeychainPasswords) { self.store = store }

    /// Forgets the cached password of a connection (disconnect, or after an outside change).
    func forget(_ id: String) {
        lock.withLock { cache[id] = nil; epoch += 1 }
    }

    /// The password without blocking the caller: a cache hit answers at once; otherwise the
    /// Keychain is read off the main actor and a found or missing answer is kept in memory. A refused or failed
    /// read answers nil but is asked again next time, so a «Deny» does not turn into «no password» for the session.
    func password(_ id: String) async -> String? {
        let (hit, start) = lock.withLock { (cache[id], epoch) }
        if let hit { return hit }
        let result = await Task.detached { [store] in store.read(id) }.value
        let value: String?
        switch result {
        case .found(let data): value = String(decoding: data, as: UTF8.self)
        case .missing: value = nil
        case .failed: return nil
        }
        lock.withLock { if epoch == start { cache[id] = .some(value) } }
        return value
    }

    @discardableResult func set(_ value: String, for id: String, label: String) -> Bool {
        forget(id)
        let saved = store.set(value, for: id, label: label)
        forget(id)
        return saved
    }

    func read(_ id: String) -> KeychainRead { store.read(id) }
    func get(_ id: String) -> String? { store.get(id) }
    func has(_ id: String) -> Bool { store.has(id) }

    @discardableResult func delete(_ id: String) -> Bool {
        forget(id)
        let removed = store.delete(id)
        forget(id)
        return removed
    }

    /// Deletes the connection's password and every `user:<id>/<name>` item of its server users.
    func deleteAll(connection id: String) {
        delete(id)
        for account in store.accounts(prefix: "user:\(id)/") { delete(account) }
    }

    private static let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789-_.!@#%+=")

    /// Draws each symbol by rejection (bytes at or above the largest multiple of the alphabet size are dropped), so
    /// every symbol is equally likely. `random` gives that many random bytes, or nil when it cannot.
    static func generate(length: Int, random: (Int) -> [UInt8]? = systemRandom) -> String? {
        let limit = 256 - 256 % alphabet.count
        var symbols: [Character] = []
        var attempts = 0
        while symbols.count < length {
            attempts += 1
            guard attempts <= 64, let bytes = random(max(length - symbols.count, 1) * 2) else { return nil }
            for byte in bytes where Int(byte) < limit && symbols.count < length { symbols.append(alphabet[Int(byte) % alphabet.count]) }
        }
        return String(symbols)
    }

    static func systemRandom(_ count: Int) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: count)
        return SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess ? bytes : nil
    }
}
