import Foundation
import Security
import Testing
@testable import ButakeStack

// Entornos keeps each environment's secrets in one Keychain item (P-32): reading an environment asks
// macOS for access at most once, the old per-variable items are migrated safely, and nothing is read
// to show the page. Everything runs on Keychain items in memory: never the real Keychain.

/// An old per-variable item, as earlier versions wrote it (`site/env/KEY`, the value as UTF-8).
private func legacy(_ items: MemoryKeychainItems, _ site: String, _ env: String, _ key: String, _ value: String) {
    _ = items.write(Data(value.utf8), account: "\(site)/\(env)/\(key)", label: "Stack · \(site) · \(env) · \(key)", attributes: nil)
}

@Test func anEnvironmentIsOneItemReadOnce() throws {
    let items = MemoryKeychainItems()
    let secrets = EnvSecrets(items: items)
    try secrets.update(site: "tienda", env: "local", set: ["DB_PASSWORD": "uno", "API_KEY": "dos"], remove: [])
    #expect(items.accounts == ["tienda/local"])
    let before = items.reads.count
    #expect(try secrets.values(site: "tienda", env: "local") == ["DB_PASSWORD": "uno", "API_KEY": "dos"])
    #expect(items.reads.count - before == 1, "a single read for the whole environment")
    try secrets.update(site: "tienda", env: "local", set: ["API_KEY": "tres"], remove: ["DB_PASSWORD"])
    #expect(try secrets.values(site: "tienda", env: "local") == ["API_KEY": "tres"])
    // Another environment and another project with a name that starts the same stay apart.
    try secrets.update(site: "tienda-2", env: "local", set: ["API_KEY": "otra"], remove: [])
    try secrets.update(site: "tienda", env: "production", set: ["API_KEY": "prod"], remove: [])
    #expect(try secrets.values(site: "tienda", env: "local") == ["API_KEY": "tres"])
    // Removing the last value removes the item.
    try secrets.update(site: "tienda", env: "local", set: [:], remove: ["API_KEY"])
    #expect(!items.accounts.contains("tienda/local"))
}

@Test func storedKeysReadNoValue() throws {
    let items = MemoryKeychainItems()
    let secrets = EnvSecrets(items: items)
    try secrets.update(site: "tienda", env: "local", set: ["DB_PASSWORD": "uno"], remove: [])
    legacy(items, "tienda", "staging", "OLD_KEY", "viejo")
    let reads = items.reads.count
    #expect(secrets.storedKeys(site: "tienda", env: "local") == ["DB_PASSWORD"])
    #expect(secrets.storedKeys(site: "tienda", env: "staging") == ["OLD_KEY"])
    #expect(secrets.storedKeys(site: "tienda", env: "testing").isEmpty)
    #expect(items.reads.count == reads, "showing the page never reads a value")
}

@Test func oldItemsMoveToTheSingleItemAndAreDeleted() throws {
    let items = MemoryKeychainItems()
    let secrets = EnvSecrets(items: items)
    legacy(items, "salud-app", "local", "ADMIN_API_KEY", "a")
    legacy(items, "salud-app", "local", "DB_PASSWORD", "b")
    legacy(items, "salud-app", "staging", "DB_PASSWORD", "otro entorno")
    #expect(try secrets.values(site: "salud-app", env: "local") == ["ADMIN_API_KEY": "a", "DB_PASSWORD": "b"])
    #expect(items.accounts == ["salud-app/local", "salud-app/staging/DB_PASSWORD"])
    // Once migrated, a read is a single access again.
    let reads = items.reads.count
    #expect(try secrets.values(site: "salud-app", env: "local") == ["ADMIN_API_KEY": "a", "DB_PASSWORD": "b"])
    #expect(items.reads.count - reads == 1)
}

@Test func aDeniedOldItemLosesNothingAndIsRetried() throws {
    let items = MemoryKeychainItems()
    let secrets = EnvSecrets(items: items)
    legacy(items, "salud-app", "local", "ADMIN_API_KEY", "a")
    legacy(items, "salud-app", "local", "DB_PASSWORD", "b")
    items.denied = ["salud-app/local/DB_PASSWORD"]
    #expect(throws: EnvSecrets.Failure.unavailable(errSecAuthFailed)) { try secrets.values(site: "salud-app", env: "local") }
    #expect(items.accounts == ["salud-app/local/ADMIN_API_KEY", "salud-app/local/DB_PASSWORD"], "nothing written, nothing deleted")
    // A write that needs the values also stops before changing anything.
    #expect(throws: EnvSecrets.Failure.self) { try secrets.update(site: "salud-app", env: "local", set: ["NEW": "x"], remove: []) }
    #expect(!items.accounts.contains("salud-app/local"))
    items.denied = []
    #expect(try secrets.values(site: "salud-app", env: "local") == ["ADMIN_API_KEY": "a", "DB_PASSWORD": "b"])
    #expect(items.accounts == ["salud-app/local"])
}

@Test func anOldItemThatCannotBeDeletedIsIgnoredAfterwards() throws {
    let items = MemoryKeychainItems()
    let secrets = EnvSecrets(items: items)
    legacy(items, "tienda", "local", "API_KEY", "viejo")
    items.undeletable = ["tienda/local/API_KEY"]
    #expect(try secrets.values(site: "tienda", env: "local") == ["API_KEY": "viejo"])
    // The user changes it, then removes it: the leftover old item never comes back.
    try secrets.update(site: "tienda", env: "local", set: ["API_KEY": "nuevo"], remove: [])
    #expect(try secrets.values(site: "tienda", env: "local") == ["API_KEY": "nuevo"])
    try secrets.update(site: "tienda", env: "local", set: [:], remove: ["API_KEY"])
    #expect(try secrets.values(site: "tienda", env: "local").isEmpty)
    #expect(secrets.storedKeys(site: "tienda", env: "local").isEmpty)
    let reads = items.reads
    _ = try secrets.values(site: "tienda", env: "local")
    #expect(!items.reads.dropFirst(reads.count).contains("tienda/local/API_KEY"), "the old item is not read again")
}

@Test func aValueWrittenAfterTheOldItemsWins() throws {
    let items = MemoryKeychainItems()
    let secrets = EnvSecrets(items: items)
    // An item written by this version while an old one for the same key could not be read yet.
    let content = EnvSecrets.Content(values: ["API_KEY": "nuevo"], migrated: [])
    _ = items.write(try JSONEncoder().encode(content), account: "tienda/local", label: "", attributes: nil)
    legacy(items, "tienda", "local", "API_KEY", "viejo")
    legacy(items, "tienda", "local", "OTHER", "otro")
    #expect(try secrets.values(site: "tienda", env: "local") == ["API_KEY": "nuevo", "OTHER": "otro"])
}

@Test func deletingAProjectOrAnEnvironmentRemovesOldItemsToo() throws {
    let items = MemoryKeychainItems()
    let secrets = EnvSecrets(items: items)
    try secrets.update(site: "tienda", env: "local", set: ["A": "1"], remove: [])
    try secrets.update(site: "tienda", env: "staging", set: ["A": "2"], remove: [])
    legacy(items, "tienda", "staging", "B", "3")
    try secrets.update(site: "tienda-2", env: "local", set: ["A": "4"], remove: [])
    secrets.deleteAll(site: "tienda", env: "staging")
    #expect(items.accounts == ["tienda/local", "tienda-2/local"])
    secrets.deleteAll(site: "tienda")
    #expect(items.accounts == ["tienda-2/local"])
}

@Test func anUnreadableItemIsNeverOverwritten() throws {
    let items = MemoryKeychainItems()
    let secrets = EnvSecrets(items: items)
    _ = items.write(Data("no es JSON".utf8), account: "tienda/local", label: "", attributes: nil)
    #expect(throws: EnvSecrets.Failure.corrupt) { try secrets.update(site: "tienda", env: "local", set: ["A": "1"], remove: []) }
    #expect(items.read("tienda/local") == .found(Data("no es JSON".utf8)))
}
