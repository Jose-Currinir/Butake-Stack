import CryptoKit
import Foundation
import LocalAuthentication
import Security
import Testing
@testable import ButakeStack

// Renaming a project (P-41): the Entornos items move to the new id without being decoded, a Keychain
// that does not answer stops the rename with nothing left of the new id, the vault's links follow
// the project, and a rename started from the command line is finished by the app. Keychain items in
// memory and a temporary store only: never the real Keychain, vault or data.

private func single(_ items: MemoryKeychainItems, _ account: String, _ values: [String: String]) {
    let content = EnvSecrets.Content(values: values)
    let names = EnvSecrets.Names(names: values.keys.sorted(), migrated: [])
    _ = items.write(try! JSONEncoder().encode(content), account: account, label: "", attributes: try! JSONEncoder().encode(names))
}

@Test func renamingMovesEveryItemAsItIs() throws {
    let items = MemoryKeychainItems()
    let secrets = EnvSecrets(items: items)
    single(items, "api/local", ["TOKEN": "uno"])
    single(items, "api/production", ["TOKEN": "dos"])
    _ = items.write(Data("viejo".utf8), account: "api/staging/OLD_KEY", label: "", attributes: nil)
    single(items, "api-v2/local", ["TOKEN": "otro proyecto"])
    let before = items.reads.count
    try secrets.move(site: "api", to: "backend")
    #expect(items.accounts == ["backend/local", "backend/production", "backend/staging/OLD_KEY", "api-v2/local"])
    // One read per item to copy and one to verify it; the names stay readable without values.
    #expect(items.reads.count - before == 6)
    #expect(secrets.storedKeys(site: "backend", env: "local") == ["TOKEN"])
    #expect(try secrets.values(site: "backend", env: "production") == ["TOKEN": "dos"])
    #expect(try secrets.values(site: "backend", env: "staging") == ["OLD_KEY": "viejo"])
    #expect(EnvSecrets.label("backend/staging/OLD_KEY") == "Stack · backend · staging · OLD_KEY")
}

@Test func aKeychainThatDoesNotAnswerLeavesNothingOfTheNewId() throws {
    let items = MemoryKeychainItems()
    let secrets = EnvSecrets(items: items)
    single(items, "api/local", ["TOKEN": "uno"])
    single(items, "api/staging", ["TOKEN": "dos"])
    items.denied = ["api/staging"]
    #expect(throws: EnvSecrets.MoveFailure.unavailable(errSecAuthFailed)) { try secrets.copyAll(site: "api", to: "backend") }
    #expect(items.accounts == ["api/local", "api/staging"], "the copies go and the old items stay")
    items.denied = []
    // Another project's item already under the new id is never overwritten.
    single(items, "backend/local", ["TOKEN": "ajeno"])
    #expect(throws: EnvSecrets.MoveFailure.conflict) { try secrets.move(site: "api", to: "backend") }
    #expect(try secrets.values(site: "backend", env: "local") == ["TOKEN": "ajeno"])
    #expect(items.accounts.contains("api/local"))
}

/// An earlier try that copied and stopped before deleting is finished, not refused.
@Test func anInterruptedMoveIsFinished() throws {
    let items = MemoryKeychainItems()
    let secrets = EnvSecrets(items: items)
    single(items, "api/local", ["TOKEN": "uno"])
    let created = try secrets.copyAll(site: "api", to: "backend")
    #expect(created == ["backend/local"])
    try secrets.move(site: "api", to: "backend")
    #expect(items.accounts == ["backend/local"])
    // Undoing a copy removes only what it created.
    single(items, "web/local", ["TOKEN": "tres"])
    secrets.removeCopies(try secrets.copyAll(site: "web", to: "portal"))
    #expect(items.accounts == ["backend/local", "web/local"])
}

@Test func theNewIdIsCheckedAsTheEngineDoes() {
    #expect(ProjectRenameSheet.validId("butake-salud-web"))
    for wrong in ["", "Mayúscula", "con espacio", "salud_web", "ñandú", String(repeating: "a", count: 41)] {
        #expect(!ProjectRenameSheet.validId(wrong), "\(wrong)")
    }
}

@MainActor private final class Keys: VaultKeyStore {
    var keys: [String: SymmetricKey] = [:]
    func create(keyId: String) throws -> SymmetricKey { let key = VaultCrypto.newKey(); keys[keyId] = key; return key }
    func load(keyId: String, context: LAContext?) throws -> SymmetricKey {
        guard let key = keys[keyId] else { throw VaultError.missingKey }
        return key
    }
    func delete(keyId: String) { keys[keyId] = nil }
}

/// The apps linked to the project follow it; a link to a project of several parts and other
/// projects' links stay; locked, nothing changes.
@MainActor @Test func theVaultLinksFollowTheProject() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("rename-vault-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let vault = VaultSession(disk: VaultDisk(root: root.appendingPathComponent("vault")), keys: Keys(), auth: ApprovingVaultAuthenticator())
    #expect(await vault.create())
    let app = try vault.addContainer(kind: .app, name: "Api", bundleId: nil, project: "api")
    let other = try vault.addContainer(kind: .app, name: "Otra", bundleId: nil, project: "api-v2")
    let group = try vault.addContainer(kind: .app, name: "Salud", bundleId: nil, project: VaultProjects.link(composite: "api"))
    #expect(try vault.relinkProject(from: "api", to: "backend") == 1)
    #expect(vault.index.container(app)?.project == "backend")
    #expect(vault.index.container(other)?.project == "api-v2")
    #expect(vault.index.container(group)?.project == "group:api")
    var ran = false
    VaultSession.onUnlock = { ran = true }
    defer { VaultSession.onUnlock = nil }
    vault.lock()
    #expect(throws: VaultError.locked) { try vault.relinkProject(from: "backend", to: "otro") }
    await vault.unlock()
    #expect(ran, "an unlock lets the app finish what waited for the vault")
    #expect(vault.index.container(app)?.project == "backend")
}

/// A rename from the app moves the Keychain first and leaves nothing pending of it; one from the
/// command line is finished by the app (Keychain and preferences). Runs on an engine of its own.
@MainActor @Test func renamesFromTheAppAndFromTheCommandLineEndTheSame() async throws {
    guard let (engine, store) = try isolatedEngine() else { return }
    try makeProject("tienda", in: store)
    try makeProject("bodega", in: store)
    let stack = StackStore(engine: engine)
    await stack.refresh()
    let items = MemoryKeychainItems()
    let secrets = EnvSecrets(items: items)
    single(items, "tienda/local", ["TOKEN": "uno"])
    let tienda = try #require(stack.projects.first { $0.id == "tienda" })
    stack.toggleFavorite("tienda")
    defer { stack.favoriteSites.remove("almacen") }
    #expect(await stack.renameProject(tienda, to: "almacen", name: "Almacén", domain: true, secrets: secrets))
    #expect(stack.projects.contains { $0.id == "almacen" && $0.name == "Almacén" && $0.domain == "almacen.test" })
    #expect(!stack.projects.contains { $0.id == "tienda" })
    #expect(items.accounts == ["almacen/local"])
    #expect(stack.favoriteSites.contains("almacen") && !stack.favoriteSites.contains("tienda"))
    #expect(stack.route == .site("almacen"))
    let pending: [PendingRename] = try await stack.call(["method": "pendingRenames"])
    #expect(pending.isEmpty)
    // A refused rename leaves the Keychain as it was.
    #expect(await stack.renameProject(try #require(stack.projects.first { $0.id == "almacen" }), to: "bodega", name: "X", domain: false, secrets: secrets) == false)
    #expect(items.accounts == ["almacen/local"])
    stack.errorMessage = nil

    // From the command line: environments exist, so the Keychain step waits for the app.
    let environments = store.appendingPathComponent("envs", isDirectory: true)
    try FileManager.default.createDirectory(at: environments, withIntermediateDirectories: true)
    try Data(#"{"active":null,"environments":[{"id":"local","name":"Local","kind":"local","entries":[{"key":"TOKEN","value":"","secret":true}]}]}"#.utf8)
        .write(to: environments.appendingPathComponent("bodega.json"))
    single(items, "bodega/local", ["TOKEN": "dos"])
    let renamed: RenamedProject = try await stack.call(["method": "renameProject", "id": "bodega", "newId": "deposito"])
    #expect(renamed.pending == ["keychain", "app"])
    await stack.completePendingRenames(secrets: secrets)
    #expect(items.accounts == ["almacen/local", "deposito/local"])
    #expect(try secrets.values(site: "deposito", env: "local") == ["TOKEN": "dos"])
    let left: [PendingRename] = try await stack.call(["method": "pendingRenames"])
    #expect(left.isEmpty)
}
