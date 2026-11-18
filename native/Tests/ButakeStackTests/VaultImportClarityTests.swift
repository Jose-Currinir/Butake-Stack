import CryptoKit
import Foundation
import LocalAuthentication
import Testing
@testable import ButakeStack

// P-40: an import says what came in and what did not, and leaves no empty app or service. A made-up
// backup with the three shapes the real one showed: services that only bring a README, accounts of a
// service kept as subfolders (and quarantines inside them), and what is left out by design (history,
// dumps with their checksums, `.env`). In-memory keys and temporary folders only.

@MainActor private final class Keys: VaultKeyStore {
    var keys: [String: SymmetricKey] = [:]
    func create(keyId: String) throws -> SymmetricKey { let key = VaultCrypto.newKey(); keys[keyId] = key; return key }
    func load(keyId: String, context: LAContext?) throws -> SymmetricKey {
        guard let key = keys[keyId] else { throw VaultError.missingKey }
        return key
    }
    func delete(keyId: String) { keys[keyId] = nil }
}

@MainActor private func session(_ root: URL) async -> VaultSession {
    let session = VaultSession(disk: VaultDisk(root: root.appendingPathComponent("vault")), keys: Keys(), auth: ApprovingVaultAuthenticator())
    session.archiveIterations = VaultArchive.minimumIterations
    #expect(await session.create())
    return session
}

private enum Invented {
    static let p12Password = "CENTINELA-P40-P12-4e1a"
    static let quarantined = "CENTINELA-P40-CUARENTENA-9b77"
    static let dumped = "CENTINELA-P40-VOLCADO-12cd"
    static let env = "CENTINELA-P40-ENV-77aa"
    static var sentinels: [String] { [p12Password, quarantined, dumped, env] }
    static let token = "token de prueba, no es real"
    static let app = "Demo Clara (cl.demo.clara)"
    static let quarantine = "_CUARENTENA-NOMBRE-SENSIBLE-2026-09-09"

    /// The made-up backup: an app and `_SERVICIOS` with the three cases.
    static func backup() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("p40-\(UUID().uuidString)", isDirectory: true)
        func write(_ text: String, _ path: String) throws {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        // Services that only bring notes: nothing to import.
        try write("# aws\nCuenta principal, ver consola.\n", "_SERVICIOS/aws/README.md")
        try write("# github\nOrganización demo.\n", "_SERVICIOS/github/README.md")
        try write("# Cuarentena\nApartado por nombre sensible.\n", "_SERVICIOS/github/\(quarantine)/README.md")
        try write("# Banco\n", "_SERVICIOS/Banco Demo/\(quarantine)/README.md")
        try write(quarantined + "\n", "_SERVICIOS/Banco Demo/\(quarantine)/datos.txt")
        // A service with accounts: the service's notes, an account with its README and a token, another
        // account with a certificate and its password.
        try write("# cloudflare\nZonas y túneles.\n", "_SERVICIOS/cloudflare/README.md")
        try write("# Cuenta demo\nDueña de la zona demo.\n", "_SERVICIOS/cloudflare/cuenta@ejemplo.cl/README.md")
        try write(token + "\n", "_SERVICIOS/cloudflare/cuenta@ejemplo.cl/api-token.txt")
        try write("p12-falso-p40", "_SERVICIOS/apple-signing/developer-id/dev.p12")
        try write(p12Password + "\n", "_SERVICIOS/apple-signing/developer-id/dev.p12.pass")
        // The app: what goes in, and what is left out by design.
        try write(PEM.block("NO-ES-REAL-P40"), "\(app)/03-IOS/PROD/AuthKey_ABC123DEF4.p8")
        try write("png-falso", "\(app)/03-IOS/PROD/icono.png")
        try write("APP_KEY=\(env)\n", "\(app)/01-API/PROD/.env")
        try write(dumped, "\(app)/01-API/PROD/base.dump.gz")
        try write("0123abcd  base.dump.gz\n", "\(app)/01-API/PROD/base.dump.gz.sha256")
        try write("viejo", "\(app)/99-HISTORICO-TRANSICION/viejo.cer")
        try write("suelta", "Notas sueltas/apunte.md")
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("\(app)/03-IOS/enlace.p12"),
                                                   withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
        return root
    }
}

private func noSentinel(_ text: String, _ place: String) {
    for sentinel in Invented.sentinels { #expect(!text.contains(sentinel), "\(place) shows a sentinel") }
}

// MARK: Scan

@Test func aServiceIsOneGroupWithItsAccountsAndQuarantinesAreNeverRead() throws {
    let root = try Invented.backup()
    defer { try? FileManager.default.removeItem(at: root) }
    let groups = VaultFolder.scan(root)
    noSentinel(String(describing: groups), "the scan")
    // One group per service, never one per subfolder: no name is a path.
    #expect(Set(groups.filter { $0.kind == .service }.map(\.name)) == ["apple-signing", "aws", "Banco Demo", "cloudflare", "github"])
    let cloudflare = try #require(groups.first { $0.name == "cloudflare" })
    #expect(cloudflare.files.map(\.account) == ["cuenta@ejemplo.cl"])
    #expect(Set(cloudflare.readmes.map(\.account)) == [nil, "cuenta@ejemplo.cl"])
    let signing = try #require(groups.first { $0.name == "apple-signing" }?.files.first)
    #expect(signing.account == "developer-id" && signing.kind == .iosCertificate && signing.companions.first?.certain == true)
    // A quarantine is listed by name only, unselected and sealed; it adds no account.
    let bank = try #require(groups.first { $0.name == "Banco Demo" })
    #expect(bank.files.count == 2 && bank.files.allSatisfy { $0.exclusion == .quarantine && !$0.selected && $0.sealed && $0.account == nil })
    #expect(bank.readmes.isEmpty && !bank.bringsSomething)
    #expect(groups.first { $0.name == "aws" }?.bringsSomething == false)
    // A dump and its checksum, the .env, history, what nobody recognizes, a link and a loose folder.
    let app = try #require(groups.first { $0.kind == .app })
    func file(_ name: String) -> VaultFolder.Candidate? { app.files.first { $0.name == name } }
    #expect(file("base.dump.gz")?.exclusion == .dump && file("base.dump.gz.sha256")?.exclusion == .dump)
    #expect(file("icono.png")?.unrecognized == true && file("icono.png")?.selected == false)
    #expect(file("AuthKey_ABC123DEF4.p8")?.selected == true)
    let skipped = Set(groups.flatMap(\.skipped).map(\.reason))
    #expect(skipped.contains(.link) && skipped.contains(.notApp))

    let summary = VaultImportSummary.make(groups, folders: [root.lastPathComponent])
    #expect(summary.count(.imported) == 3)
    #expect(summary.count(.quarantine) == 3 && summary.count(.dump) == 2 && summary.count(.env) == 1 && summary.count(.history) == 1)
    #expect(summary.list(.unrecognized).map(\.reason).contains("unknown") && summary.list(.unrecognized).contains { $0.reason == "skip.link" })
    #expect(summary.list(.readme).contains { $0.path == "_SERVICIOS/aws/README.md" && $0.reason == "notKept" })
    #expect(summary.list(.readme).contains { $0.path == "_SERVICIOS/cloudflare/cuenta@ejemplo.cl/README.md" && $0.reason == nil })
    #expect(VaultBackupLayout.excluded(folder: Invented.quarantine) == .quarantine)
}

// MARK: Import, import again, clean up

@Test @MainActor func importingCreatesNoEmptyContainerAndKeepsTheSummary() async throws {
    let backup = try Invented.backup()
    defer { try? FileManager.default.removeItem(at: backup) }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("p40-boveda-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let vault = await session(root)
    let result = await vault.importFolder(vault.markDuplicates(VaultFolder.scan(backup)), folders: [backup.lastPathComponent])
    #expect(result.added == 3 && result.failed == 0)

    // Only what brought something: the app, cloudflare and apple-signing; no aws, github or bank.
    #expect(Set(vault.index.containers.map(\.name)) == ["Demo Clara", "cloudflare", "apple-signing"])
    #expect(vault.emptyContainers.isEmpty)
    #expect(vault.index.containers.allSatisfy { !$0.title.contains("/") && $0.subtitlePath == nil })
    let cloudflare = try #require(vault.index.containers.first { $0.name == "cloudflare" })
    #expect(cloudflare.notes.contains("Zonas y túneles") && cloudflare.notes.contains("## cuenta@ejemplo.cl") && cloudflare.notes.contains("Dueña de la zona"))
    #expect(vault.index.items(in: cloudflare.id).map(\.account) == ["cuenta@ejemplo.cl"])
    let p12 = try #require(vault.index.items.first { $0.kind == .iosCertificate })
    #expect(p12.account == "developer-id" && p12.field(.password)?.value == Invented.p12Password)

    // The summary stays in the (encrypted) index: paths and counts, read back after locking.
    vault.lock()
    await vault.unlock()
    let summary = try #require(vault.index.lastImport)
    #expect(summary.folders == [backup.lastPathComponent] && summary.count(.imported) == 3 && summary.count(.quarantine) == 3)
    #expect(summary.list(.readme).contains { $0.path == "_SERVICIOS/github/README.md" && $0.reason == "notKept" })
    noSentinel(String(describing: summary), "the summary")
    let json = String(decoding: try JSONEncoder().encode(summary), as: UTF8.self)
    noSentinel(json, "the stored summary")
    #expect(!json.contains(Invented.token))
    // Nothing quarantined or dumped was read into the vault.
    let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
    while let url = enumerator?.nextObject() as? URL {
        if let data = try? Data(contentsOf: url) { noSentinel(String(decoding: data, as: UTF8.self), url.lastPathComponent) }
    }

    // Importing the same backup again adds nothing and creates nothing.
    let again = vault.markDuplicates(VaultFolder.scan(backup))
    let recognized = again.flatMap(\.files).filter { !$0.sealed && $0.kind != .envFile && !$0.unrecognized && $0.exclusion == nil }
    #expect(recognized.allSatisfy { $0.duplicate })
    let second = await vault.importFolder(again)
    #expect(second.added == 0 && vault.index.items.count == 3 && vault.index.containers.count == 3)
}

@Test @MainActor func importingAgainGathersTheAccountsAnEarlierImportKeptApart() async throws {
    let backup = try Invented.backup()
    defer { try? FileManager.default.removeItem(at: backup) }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("p40-antes-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let vault = await session(root)
    // What the earlier importer left: a service per subfolder (paths as names), README-only ones empty.
    _ = try vault.addContainer(kind: .service, name: "aws", bundleId: nil, notes: "# aws")
    let cloudflare = try vault.addContainer(kind: .service, name: "cloudflare", bundleId: nil, notes: "# cloudflare\nZonas y túneles.")
    let account = try vault.addContainer(kind: .service, name: "cloudflare/cuenta@ejemplo.cl", bundleId: nil, notes: "# Cuenta demo\nDueña de la zona demo.")
    let developer = try vault.addContainer(kind: .service, name: "apple-signing/developer-id", bundleId: nil)
    _ = try vault.addContainer(kind: .service, name: "github/\(Invented.quarantine)", bundleId: nil, notes: "# Cuarentena")
    try await vault.store(VaultItem(container: account, kind: .note, name: "api-token.txt"), files: [("api-token.txt", Data((Invented.token + "\n").utf8))])
    try await vault.store(VaultItem(container: developer, kind: .iosCertificate, name: "dev.p12"), files: [("dev.p12", Data("p12-falso-p40".utf8))])
    #expect(vault.index.containers.first { $0.id == account }?.title == "cloudflare")
    #expect(vault.index.containers.first { $0.id == account }?.subtitlePath == "cuenta@ejemplo.cl")
    #expect(Set(vault.emptyContainers.map(\.name)) == ["aws", "cloudflare", "github/\(Invented.quarantine)"])

    let groups = vault.markDuplicates(VaultFolder.scan(backup))
    #expect(groups.first { $0.name == "cloudflare" }?.legacy == [account])
    #expect(groups.first { $0.name == "cloudflare" }?.files.allSatisfy(\.duplicate) == true)
    #expect(groups.first { $0.name == "apple-signing" }?.files.first?.duplicate == true)
    let result = await vault.importFolder(groups)
    // The app's key is new; nothing that was already there is imported twice.
    #expect(result.added == 1 && vault.index.items.count == 3)
    let token = try #require(vault.index.items.first { $0.name == "api-token.txt" })
    #expect(token.container == cloudflare && token.account == "cuenta@ejemplo.cl")
    let signing = try #require(vault.index.containers.first { $0.name == "apple-signing" })
    #expect(vault.index.items.first { $0.kind == .iosCertificate }.map { $0.container == signing.id && $0.account == "developer-id" } == true)
    #expect(vault.index.container(account) == nil && vault.index.container(developer) == nil)
    #expect(vault.index.container(cloudflare)?.notes.contains("## cuenta@ejemplo.cl") == true)

    // What stays empty is removed only by the explicit action, and never an item.
    #expect(Set(vault.emptyContainers.map(\.name)) == ["aws", "github/\(Invented.quarantine)"])
    #expect(try vault.removeEmptyContainers() == 2)
    #expect(vault.emptyContainers.isEmpty && vault.index.items.count == 3)
    #expect(vault.index.containers.allSatisfy { !$0.name.contains("/") })
    #expect(vault.index.containers.first { $0.name == "github" } == nil)
}

@Test @MainActor func accountsTravelInTheDownloadAndComeBack() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("p40-descarga-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let vault = await session(root.appendingPathComponent("a"))
    let service = try vault.addContainer(kind: .service, name: "cloudflare", bundleId: nil)
    var token = VaultItem(container: service, kind: .token, name: "API token")
    token.account = "tunnels/principal"
    token.fields = [VaultField(role: .token, value: "tok-p40", secret: true, envVar: "CLOUDFLARE_API_TOKEN")]
    try await vault.store(token, files: [])
    let parent = root.appendingPathComponent("drive")
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    let folder = try vault.downloadFolder(nil, into: parent)
    #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("_SERVICIOS/cloudflare/tunnels/principal/API token.datos.txt").path))
    let fresh = await session(root.appendingPathComponent("b"))
    _ = await fresh.importFolder(fresh.markDuplicates(VaultFolder.scan(folder)))
    #expect(fresh.index.containers.map(\.name) == ["cloudflare"])
    #expect(fresh.index.items.first?.account == "tunnels/principal")
    #expect(VaultContainer.accountTitle("tunnels/principal") == "tunnels › principal")
    #expect(VaultNames.account("a/../b") == nil && VaultNames.account("a/b/c/d") == nil)
}
