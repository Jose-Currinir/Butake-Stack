import Foundation

/// One generic password per id in one Keychain service (this device only, never synchronized), over `KeychainItems` so
/// tests and QA use memory instead of the real Keychain. Used for database passwords and SSH key passphrases.
struct KeychainPasswords: Sendable {
    let items: KeychainItems
    /// Put before each item's label in Keychain Access.
    let labelPrefix: String

    init(service: String, labelPrefix: String) { self.init(items: KeychainItemStore(service: service), labelPrefix: labelPrefix) }
    init(items: KeychainItems, labelPrefix: String) { self.items = items; self.labelPrefix = labelPrefix }

    /// `.failed` is a Keychain that refused or could not answer: not the same as `.missing`.
    func read(_ id: String) -> KeychainRead { items.read(id) }

    func get(_ id: String) -> String? {
        if case .found(let data) = items.read(id) { return String(decoding: data, as: UTF8.self) }
        return nil
    }

    @discardableResult func set(_ value: String, for id: String, label: String) -> Bool {
        items.write(Data(value.utf8), account: id, label: labelPrefix + label, attributes: nil)
    }

    func has(_ id: String) -> Bool { items.list(prefix: id).contains { $0.account == id } }

    func accounts(prefix: String) -> [String] { items.list(prefix: prefix).map(\.account) }

    @discardableResult func delete(_ id: String) -> Bool { items.remove(id, quietly: false) }
}
