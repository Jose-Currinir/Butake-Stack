import CryptoKit
import Foundation
import LocalAuthentication
import Testing
@testable import ButakeStack

// The vault linked to Stack's projects (P-21): the optional field stays compatible, the link persists,
// the project's page learns nothing while the vault is locked, and moving a `.env` or an SSH key out
// of the vault leaves no value in any file of Stack. Everything runs against the temporary store of
// scripts/test-native.sh (BUTAKE_STACK_HOME) and in-memory keys and secrets: never the Keychain.

@MainActor private final class MemoryKeys: VaultKeyStore {
    var keys: [String: SymmetricKey] = [:]
    func create(keyId: String) throws -> SymmetricKey { let key = VaultCrypto.newKey(); keys[keyId] = key; return key }
    func load(keyId: String, context: LAContext?) throws -> SymmetricKey {
        guard let key = keys[keyId] else { throw VaultError.missingKey }
        return key
    }
    func delete(keyId: String) { keys[keyId] = nil }
}

private func folder(_ name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@MainActor private func unlockedVault(_ root: URL, keys: MemoryKeys = MemoryKeys()) async throws -> VaultSession {
    let session = VaultSession(disk: VaultDisk(root: root.appendingPathComponent("vault")), keys: keys, auth: ApprovingVaultAuthenticator())
    session.archiveIterations = VaultArchive.minimumIterations
    #expect(await session.create())
    return session
}

/// An engine of its own: a store in a new temporary folder (other tests count the projects of the
/// shared one), through a small launcher that sets BUTAKE_STACK_HOME. Nil outside
/// scripts/test-native.sh, which builds the engine and isolates the run.
func isolatedEngine() throws -> (StackEngine, URL)? {
    guard ProcessInfo.processInfo.environment["BUTAKE_STACK_HOME"] != nil else { return nil }
    let root = try folder("engine-store")
    let store = root.appendingPathComponent("store", isDirectory: true)
    let launcher = root.appendingPathComponent("engine")
    try "#!/bin/sh\nBUTAKE_STACK_HOME='\(store.path)' exec '\(StackEngine.executable.path)' \"$@\"\n".write(to: launcher, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: launcher.path)
    return (StackEngine(executable: launcher), store)
}

/// A project of the temporary store, written as the engine keeps it.
func makeProject(_ id: String, in store: URL) throws {
    let path = try folder("proyecto")
    let projects = store.appendingPathComponent("projects", isDirectory: true)
    try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
    let project: [String: Any] = ["id": id, "name": "Tienda", "path": path.path, "domains": ["\(id).test"], "https": false, "kind": "static",
                                  "runtime": [:], "docroot": ".", "services": [], "databases": [], "processes": [], "enabled": false]
    try JSONSerialization.data(withJSONObject: project).write(to: projects.appendingPathComponent("\(id).json"))
}

/// Every file under `root` whose bytes contain `needle`.
private func files(under root: URL, containing needle: String) -> [String] {
    let bytes = Data(needle.utf8)
    let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])
    var found: [String] = []
    while let url = walker?.nextObject() as? URL {
        guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
              let data = try? Data(contentsOf: url), data.range(of: bytes) != nil else { continue }
        found.append(url.path)
    }
    return found
}

// MARK: Format

/// An index written before the field opens the same; one with it, read by a version that does not
/// know it, ignores it; a container without a project does not write the key at all.
@Test func theProjectFieldIsOptionalBothWays() throws {
    let old = #"{"id":"6F1C2B8E-8B5B-4C8E-9C8E-0A1B2C3D4E5F","kind":"app","name":"Demo","bundleId":"cl.demo.app","notes":"","created":0}"#
    let decoded = try JSONDecoder().decode(VaultContainer.self, from: Data(old.utf8))
    #expect(decoded.project == nil && decoded.name == "Demo")
    #expect(String(decoding: try JSONEncoder().encode(decoded), as: UTF8.self).contains("project") == false)

    var linked = decoded
    linked.project = "tienda"
    let data = try JSONEncoder().encode(linked)
    #expect(try JSONDecoder().decode(VaultContainer.self, from: data).project == "tienda")
    // What the previous version decodes: the same fields, without `project`.
    struct PreviousContainer: Decodable { var id: UUID; var kind: String; var name: String; var bundleId: String?; var notes: String; var created: Date }
    let previous = try JSONDecoder().decode(PreviousContainer.self, from: data)
    #expect(previous.name == "Demo" && previous.bundleId == "cl.demo.app")
}

/// The link persists in the encrypted index and travels in a `.butakevault` backup.
@MainActor @Test func theLinkPersistsAndTravelsInABackup() async throws {
    let root = try folder("vault-link")
    defer { try? FileManager.default.removeItem(at: root) }
    let keys = MemoryKeys()
    let vault = try await unlockedVault(root, keys: keys)
    let id = try vault.addContainer(kind: .app, name: "Tienda", bundleId: "cl.demo.tienda", project: "tienda")
    let service = try vault.addContainer(kind: .service, name: "cloudflare", bundleId: nil, project: "tienda")
    #expect(vault.index.container(service)?.project == nil, "only apps link to a project")
    vault.lock()
    await vault.unlock()
    #expect(vault.index.container(id)?.project == "tienda")

    var container = try #require(vault.index.container(id))
    container.project = nil
    try vault.updateContainer(container)
    container.project = "otra"
    try vault.updateContainer(container)
    let archive = try await vault.exportArchive(nil, password: "contraseña-de-prueba")
    let other = try await unlockedVault(try folder("vault-link-b"))
    _ = try await other.importArchive(archive, password: "contraseña-de-prueba")
    #expect(other.index.containers.first { $0.name == "Tienda" }?.project == "otra")
}

/// While locked the project's page has nothing to list: the index is not in memory.
@MainActor @Test func aLockedVaultTellsTheProjectNothing() async throws {
    let root = try folder("vault-locked")
    defer { try? FileManager.default.removeItem(at: root) }
    let vault = try await unlockedVault(root)
    let id = try vault.addContainer(kind: .app, name: "Tienda", bundleId: nil, project: "tienda")
    _ = try await vault.store(VaultItem(container: id, section: .android, kind: .token, name: "token-de-tienda"), files: [])
    #expect(VaultProjects.items(of: "tienda", in: vault.index).map(\.name) == ["token-de-tienda"])
    #expect(VaultProjects.items(of: "otro", in: vault.index).isEmpty)
    vault.lock()
    #expect(!vault.isUnlocked && vault.index.items.isEmpty && VaultProjects.items(of: "tienda", in: vault.index).isEmpty)
    // On disk the names are encrypted.
    #expect(files(under: root, containing: "token-de-tienda").isEmpty)
}

/// A suggestion by name or by the last part of the identifier; nothing when nothing matches.
@MainActor @Test func suggestsAProjectByNameOrIdentifier() {
    let projects = [Project(id: "tienda-en-linea", name: "Tienda en línea", path: "/tmp/tienda", domains: [], https: false, kind: "static", runtime: [:],
                            docroot: ".", services: [], databases: [], processes: [], enabled: false),
                    Project(id: "salud", name: "Demo Salud", path: "/tmp/health", domains: [], https: false, kind: "static", runtime: [:],
                            docroot: ".", services: [], databases: [], processes: [], enabled: false)]
    #expect(VaultProjects.suggestion(name: "Tienda en Línea", bundleId: nil, in: projects)?.id == "tienda-en-linea")
    #expect(VaultProjects.suggestion(name: "App", bundleId: "cl.demo.health", in: projects)?.id == "salud")
    #expect(VaultProjects.suggestion(name: "Otra", bundleId: "cl.demo.otra", in: projects) == nil)
}

/// One vocabulary: the vault's stages are the projects' environments.
@MainActor @Test func stagesAreTheProjectsEnvironments() {
    #expect(VaultEnvironment.test.envKind == .staging && VaultEnvironment.prod.envKind == .production && VaultEnvironment.none.envKind == nil)
    let local = EnvEnvironment(id: "local", name: "Local", kind: .local, entries: [EnvEntry(key: "APP_KEY", value: "", secret: true)])
    let targets = VaultMove.targets([local])
    #expect(targets.first?.exists == true && targets.contains { $0.id == "production" && !$0.exists })
    #expect(VaultMove.preview(names: ["APP_KEY", "STRIPE_SECRET"], existing: local) == .init(added: ["STRIPE_SECRET"], replaced: ["APP_KEY"]))
}

// MARK: Moving

/// The values of a vault's `.env` reach the secret store and nowhere else: no file of Stack's store
/// (projects, environments, logs, audit) nor of the vault holds the sentinel afterwards, the audit
/// names the keys, and the original stays in the vault.
@MainActor @Test func movingAnEnvLeavesNoValueInStacksFiles() async throws {
    guard let (engine, store) = try isolatedEngine() else { return }
    defer { try? FileManager.default.removeItem(at: store.deletingLastPathComponent()) }
    let project = "mover-\(UUID().uuidString.prefix(8).lowercased())"
    try makeProject(project, in: store)
    let root = try folder("vault-move")
    defer { try? FileManager.default.removeItem(at: root) }
    let vault = try await unlockedVault(root)
    let app = try vault.addContainer(kind: .app, name: "Tienda", bundleId: nil, project: project)
    let sentinel = "centinela-\(UUID().uuidString)"
    let item = try await vault.store(VaultItem(container: app, section: .server, kind: .envFile, name: ".env.production", environment: .prod),
                                     files: [(".env", Data("APP_ENV=production\nSTRIPE_SECRET=\"\(sentinel)\"\n".utf8))])
    #expect(try VaultMove.envNames(item, vault: vault) == ["APP_ENV", "STRIPE_SECRET"])

    let secrets = EnvSecrets(items: MemoryKeychainItems())
    let target = try #require(VaultMove.targets([]).first { $0.kind == .production })
    let moved = try await VaultMove.moveEnv(item, vault: vault, project: project, target: target, engine: engine, secrets: secrets, actor: "pruebas")
    #expect(moved == 2)
    #expect(try secrets.values(site: project, env: "production")["STRIPE_SECRET"] == sentinel)
    #expect(files(under: store, containing: sentinel).isEmpty)
    #expect(files(under: root, containing: sentinel).isEmpty)
    // The search does find what is there: the key's name in the store, the move in the access log.
    #expect(!files(under: store, containing: "STRIPE_SECRET").isEmpty && !files(under: root, containing: "moveToEnvironments").isEmpty)

    let state: EnvState = try await engine.call(["method": "envList", "id": project])
    let production = try #require(state.site.environments.first { $0.id == "production" })
    #expect(production.kind == .production && production.entries.allSatisfy { $0.secret && $0.value.isEmpty })
    let audit: [EnvAuditEntry] = try await engine.call(["method": "envAuditLog", "id": project])
    #expect(Set(audit.filter { $0.action == "mover" }.map(\.key)) == ["APP_ENV", "STRIPE_SECRET"])
    #expect(vault.index.item(item.id) != nil, "the original is only offered for deletion")
    #expect(vault.accessLog().contains { $0.action == .moveToEnvironments && $0.target == item.id })

    // An engine refusal puts the secret store back as it was.
    let refused = VaultMove.EnvTarget(id: "no-existe", name: "No existe", kind: .other, exists: true)
    await #expect(throws: (any Error).self) {
        _ = try await VaultMove.moveEnv(item, vault: vault, project: project, target: refused, engine: engine, secrets: secrets, actor: "pruebas")
    }
    #expect(try secrets.values(site: project, env: "no-existe")["STRIPE_SECRET"] == nil)
}

/// An SSH key moves into Stack's keys (checked in their list) from a short-lived copy that does not stay.
@MainActor @Test func movingAnSSHKeyImportsItAndLeavesNoCopy() async throws {
    guard FileManager.default.isExecutableFile(atPath: "/usr/bin/ssh-keygen"), let (engine, store) = try isolatedEngine() else { return }
    defer { try? FileManager.default.removeItem(at: store.deletingLastPathComponent()) }
    let root = try folder("vault-key")
    defer { try? FileManager.default.removeItem(at: root) }
    let keyPath = root.appendingPathComponent("clave_de_prueba")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
    process.arguments = ["-q", "-t", "ed25519", "-N", "", "-C", "pruebas", "-f", keyPath.path]
    try process.run()
    process.waitUntilExit()
    let keyData = try Data(contentsOf: keyPath)
    try FileManager.default.removeItem(at: keyPath)
    let vault = try await unlockedVault(root)
    let app = try vault.addContainer(kind: .app, name: "Tienda", bundleId: nil)
    let name = "clave-movida-\(UUID().uuidString.prefix(6))"
    let item = try await vault.store(VaultItem(container: app, section: .server, kind: .sshKey, name: name), files: [("id_ed25519", keyData)])
    let key = try await VaultMove.moveKey(item, vault: vault, engine: engine)
    #expect(key.name == name && key.encrypted != true)
    let keys: [SSHKey] = try await engine.call(["method": "sshKeys"])
    #expect(keys.contains { $0.id == key.id })
    let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: vault.disk.tmpURL.path)) ?? []
    #expect(leftovers.isEmpty)
    #expect(vault.accessLog().contains { $0.action == .moveToKeys && $0.target == item.id })
}
