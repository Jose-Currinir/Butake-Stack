import CryptoKit
import Foundation
import LocalAuthentication
import Testing
@testable import ButakeStack

@MainActor private final class Keys: VaultKeyStore {
    var keys: [String: SymmetricKey] = [:]
    func create(keyId: String) throws -> SymmetricKey { let key = VaultCrypto.newKey(); keys[keyId] = key; return key }
    func load(keyId: String, context: LAContext?) throws -> SymmetricKey {
        guard let key = keys[keyId] else { throw VaultError.missingKey }
        return key
    }
    func delete(keyId: String) { keys[keyId] = nil }
}

/// Answers the presence check the test decides.
@MainActor private final class Presence: VaultAuthenticator {
    var present = true
    func authenticate(_ reason: String) async -> LAContext? { present ? LAContext() : nil }
}

/// The edit sheet keeps a saved secret masked: only fields that are secret and hold a value are locked.
@Test func onlyASavedSecretWithAValueIsLockedInTheEditSheet() {
    let secret = VaultField(role: .password, value: "valor-inventado", secret: true)
    let empty = VaultField(role: .token, value: "", secret: true)
    let plain = VaultField(role: .username, value: "demo", secret: false)
    let item = VaultItem(container: UUID(), kind: .note, name: "Demo", fields: [secret, empty, plain])
    #expect(item.hasSecretValue(secret.id))
    #expect(!item.hasSecretValue(empty.id))
    #expect(!item.hasSecretValue(plain.id))
    #expect(!item.hasSecretValue(UUID()))
}

/// Showing a secret to edit it asks for presence like «Mostrar», and only an approved one is written to the log.
@Test @MainActor func revealingToEditNeedsPresence() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("vault-edit-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let presence = Presence()
    let session = VaultSession(disk: VaultDisk(root: root.appendingPathComponent("vault")), keys: Keys(), auth: presence)
    #expect(await session.create())
    let field = VaultField(role: .password, value: "valor-inventado", secret: true)
    let item = VaultItem(container: UUID(), kind: .note, name: "Demo", fields: [field])

    presence.present = false
    #expect(await session.revealForEditing(field, of: item) == false)
    #expect(session.disk.readLog().filter { $0.action == .reveal }.isEmpty)

    presence.present = true
    #expect(await session.revealForEditing(field, of: item))
    #expect(session.disk.readLog().filter { $0.action == .reveal && $0.target == item.id }.count == 1)
}
