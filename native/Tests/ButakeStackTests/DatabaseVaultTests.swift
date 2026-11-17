import Foundation
import Testing
@testable import ButakeStack

/// Keychain items that refuse every write, as a locked or denied Keychain does.
private struct RefusingItems: KeychainItems {
    func read(_ account: String) -> KeychainRead { .failed(errSecAuthFailed) }
    func write(_ data: Data, account: String, label: String, attributes: Data?) -> Bool { false }
    func list(prefix: String) -> [KeychainEntry] { [] }
    func remove(_ account: String, quietly: Bool) -> Bool { false }
}

private func passwords(_ items: KeychainItems = MemoryKeychainItems()) -> DatabasePasswords {
    DatabasePasswords(KeychainPasswords(items: items, labelPrefix: "Prueba · "))
}

/// A denied or failed read is not «no password»: it is not cached, so the next read can still find it.
@Test func aFailedKeychainReadIsNotCachedAsNoPassword() async {
    let items = MemoryKeychainItems()
    let vault = passwords(items)
    #expect(vault.set("clave-inventada", for: "conexion", label: "Demo"))
    vault.forget("conexion")

    items.denied = ["conexion"]
    #expect(await vault.password("conexion") == nil)
    #expect({ if case .failed = vault.read("conexion") { true } else { false } }())

    items.denied = []
    #expect(await vault.password("conexion") == "clave-inventada")
}

/// A password that is not there is cached (no repeated reads); setting or deleting clears it.
@Test func aMissingPasswordIsCachedUntilItChanges() async {
    let items = MemoryKeychainItems()
    let vault = passwords(items)
    #expect(await vault.password("otra") == nil)
    #expect(await vault.password("otra") == nil)
    #expect(items.reads == ["otra"])
    #expect({ if case .missing = vault.read("otra") { true } else { false } }())
    vault.set("nueva", for: "otra", label: "Demo")
    #expect(await vault.password("otra") == "nueva")
    vault.delete("otra")
    #expect(await vault.password("otra") == nil)
}

/// Saving reports failure so the callers can say so instead of showing «guardada».
@Test func savingAndDeletingReportTheirOutcome() {
    #expect(passwords(RefusingItems()).set("x", for: "a", label: "Demo") == false)
    #expect(passwords(RefusingItems()).delete("a") == false)
    let items = MemoryKeychainItems()
    items.undeletable = ["fija"]
    let vault = passwords(items)
    vault.set("x", for: "fija", label: "Demo")
    #expect(vault.delete("fija") == false)
    #expect(vault.has("fija"))
}

/// Removing a connection removes its password and its server users' passwords, and nothing else.
@Test func deletingAConnectionRemovesItsServerUsers() {
    let items = MemoryKeychainItems()
    let vault = passwords(items)
    for account in ["c1", "user:c1/ana", "user:c1/luis", "c2", "user:c2/ana"] { vault.set("x", for: account, label: account) }
    vault.deleteAll(connection: "c1")
    #expect(items.accounts == ["c2", "user:c2/ana"])
    #expect(vault.has("c2") && !vault.has("c1"))
}

/// The SSH passphrase wrapper works over the same injectable store.
@Test func passphrasesGoThroughTheInjectableStore() {
    let items = MemoryKeychainItems()
    let store = KeychainPasswords(items: items, labelPrefix: "Stack · SSH · ")
    #expect(store.get("clave") == nil && !store.has("clave"))
    #expect(store.set("frase-inventada", for: "clave", label: "Mi clave"))
    #expect(store.get("clave") == "frase-inventada" && store.has("clave"))
    items.denied = ["clave"]
    #expect(store.get("clave") == nil)
    items.denied = []
    #expect(store.delete("clave") && !store.has("clave"))
}

/// A generated password needs real random bytes and draws every symbol with the same odds.
@Test func generatedPasswordsFailWithoutRandomnessAndAreNotBiased() throws {
    #expect(DatabasePasswords.generate(length: 24, random: { _ in nil }) == nil)
    // Only bytes above the largest multiple of 66 (198) are all rejected: it gives up instead of looping.
    #expect(DatabasePasswords.generate(length: 24, random: { count in [UInt8](repeating: 255, count: count) }) == nil)
    // Bytes 0...255 once each: the 58 bytes from 198 up are dropped and each of the 66 symbols comes up 3 times.
    let all = try #require(DatabasePasswords.generate(length: 198, random: { _ in (0...255).map { UInt8($0) } }))
    let counts = Dictionary(grouping: all, by: { $0 }).mapValues(\.count)
    #expect(counts.count == 66 && Set(counts.values) == [3])
    let real = try #require(DatabaseVault.generate())
    #expect(real.count == 24 && Set(real).count > 4)
}
