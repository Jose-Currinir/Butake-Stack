import CryptoKit
import Foundation
import LocalAuthentication
import Testing
@testable import ButakeStack

// MARK: Helpers

/// Keys in memory only.
@MainActor private final class MemoryVaultKeyStore: VaultKeyStore {
    var keys: [String: SymmetricKey] = [:]
    func create(keyId: String) throws -> SymmetricKey { let key = VaultCrypto.newKey(); keys[keyId] = key; return key }
    func load(keyId: String, context: LAContext?) throws -> SymmetricKey {
        guard let key = keys[keyId] else { throw VaultError.missingKey }
        return key
    }
    func delete(keyId: String) { keys[keyId] = nil }
}

private func temporaryFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("vault-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func permissions(_ url: URL) -> Int {
    ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? NSNumber)?.intValue ?? -1
}

@MainActor private func newSession(_ root: URL, keys: MemoryVaultKeyStore = MemoryVaultKeyStore()) -> VaultSession {
    let session = VaultSession(disk: VaultDisk(root: root.appendingPathComponent("vault")), keys: keys, auth: ApprovingVaultAuthenticator())
    session.archiveIterations = VaultArchive.minimumIterations
    return session
}

private let serviceAccountJSON = """
{"type": "service_account", "project_id": "demo-proyecto", "private_key_id": "0123456789abcdef0123",
 "private_key": "\(PEM.block("NO-ES-REAL", escaped: true))",
 "client_email": "ci@demo-proyecto.iam.gserviceaccount.com"}
"""

private let googleServicesJSON = """
{"project_info": {"project_number": "123456789", "project_id": "demo-salud"},
 "client": [{"client_info": {"android_client_info": {"package_name": "cl.demo.health"}}}]}
"""

private func runTool(_ path: String, _ arguments: [String], in folder: URL) -> Bool {
    guard FileManager.default.isExecutableFile(atPath: path) else { return false }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    process.currentDirectoryURL = folder
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    process.standardInput = FileHandle.nullDevice
    do { try process.run() } catch { return false }
    process.waitUntilExit()
    return process.terminationStatus == 0
}

// MARK: Encryption

@Test func sealsAndOpensWithItsContextOnly() throws {
    let key = VaultCrypto.newKey()
    let secret = Data("clave-de-prueba".utf8)
    let sealed = try VaultCrypto.seal(secret, key: key, context: "butake-vault/blob/A")
    #expect(sealed.range(of: secret) == nil)
    #expect(try VaultCrypto.open(sealed, key: key, context: "butake-vault/blob/A") == secret)
    #expect(throws: VaultError.corrupt) { try VaultCrypto.open(sealed, key: key, context: "butake-vault/blob/B") }
    #expect(throws: VaultError.corrupt) { try VaultCrypto.open(sealed, key: VaultCrypto.newKey(), context: "butake-vault/blob/A") }
    var tampered = sealed
    tampered[tampered.count - 20] ^= 0x01
    #expect(throws: VaultError.corrupt) { try VaultCrypto.open(tampered, key: key, context: "butake-vault/blob/A") }
}

@Test func derivesPBKDF2SHA256LikeTheReference() throws {
    // RFC 7914, section 11: PBKDF2-HMAC-SHA256("passwd", "salt", 1).
    let key = try VaultCrypto.deriveKey(password: "passwd", salt: Data("salt".utf8), iterations: 1)
    let hex = key.withUnsafeBytes { Data($0) }.map { String(format: "%02x", $0) }.joined()
    #expect(hex == "55ac046e56e3089fec1691c22544b605f94185216dde0465e68b9d57c20dacbc")
}

// MARK: .butakevault

private func samplePayload() -> VaultArchive.Payload {
    let app = VaultContainer(kind: .app, name: "Demo Salud", bundleId: "cl.demo.health")
    let bytes = Data("keystore-falso".utf8)
    let file = VaultFile(name: "upload.jks", size: bytes.count, sha256: VaultCrypto.sha256(bytes))
    // Whole seconds: dates travel as ISO 8601.
    let date = Date(timeIntervalSince1970: 1_800_000_000)
    var app2 = app
    app2.created = date
    var item = VaultItem(container: app.id, section: .android, kind: .androidKeystore, name: "upload.jks", files: [file], created: date, updated: date)
    item.fields = [VaultField(role: .storePassword, value: "s3creto", secret: true, envVar: "ANDROID_KEYSTORE_PASSWORD")]
    return VaultArchive.Payload(containers: [app2], items: [item], blobs: [file.id.uuidString: bytes])
}

@Test func archiveRoundTrips() throws {
    let payload = samplePayload()
    let data = try VaultArchive.encode(payload, password: "una contraseña larga", scope: "all", iterations: VaultArchive.minimumIterations)
    #expect(data.prefix(8) == Data("BUTAKEVT".utf8))
    #expect(data.range(of: Data("s3creto".utf8)) == nil)
    #expect(data.range(of: Data("Demo Salud".utf8)) == nil)
    let (header, decoded) = try VaultArchive.decode(data, password: "una contraseña larga")
    #expect(header.iterations == VaultArchive.minimumIterations)
    #expect(header.items == 1 && header.containers == 1)
    #expect(decoded == payload)
}

@Test func archiveRejectsWrongPasswordAndTampering() throws {
    let data = try VaultArchive.encode(samplePayload(), password: "una contraseña larga", scope: "all", iterations: VaultArchive.minimumIterations)
    #expect(throws: VaultError.wrongPassword) { try VaultArchive.decode(data, password: "otra contraseña larga") }
    var body = data
    body[body.count - 30] ^= 0x40
    #expect(throws: VaultError.wrongPassword) { try VaultArchive.decode(body, password: "una contraseña larga") }
    // The header is authenticated too: changing the scope breaks the file.
    let (_, prefixLength) = try VaultArchive.header(of: data)
    let headerText = String(decoding: data[13..<prefixLength], as: UTF8.self).replacingOccurrences(of: "\"scope\":\"all\"", with: "\"scope\":\"xyz\"")
    var header = data.prefix(13)
    header.append(Data(headerText.utf8))
    header.append(data.dropFirst(prefixLength))
    #expect(throws: VaultError.wrongPassword) { try VaultArchive.decode(header, password: "una contraseña larga") }
    #expect(throws: VaultError.unsupported) { try VaultArchive.decode(Data("NOTVAULT-and-more-bytes".utf8), password: "x") }
    #expect(throws: (any Error).self) { try VaultArchive.decode(data.prefix(40), password: "una contraseña larga") }
}

@Test func archiveRefusesWeakDerivation() throws {
    let data = try VaultArchive.encode(samplePayload(), password: "una contraseña larga", scope: "all", iterations: 1_000)
    #expect(throws: VaultError.unsupported) { try VaultArchive.decode(data, password: "una contraseña larga") }
}

// MARK: Store on disk and session

@Test @MainActor func storesEverythingEncryptedAndPrivate() async throws {
    let root = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    let keys = MemoryVaultKeyStore()
    let session = newSession(root, keys: keys)
    session.refreshState()
    #expect(session.state == .absent)
    #expect(await session.create())
    let app = try session.addContainer(kind: .app, name: "Demo Salud", bundleId: "cl.demo.health")
    let source = root.appendingPathComponent("service-account.json")
    try Data(serviceAccountJSON.utf8).write(to: source)
    #expect(await session.add(files: [source], to: app, section: nil) == 1)
    let item = try #require(session.index.items.first)
    #expect(item.kind == .serviceAccount)
    #expect(item.section == .terceros)
    #expect(item.metadata.value("vault.meta.clientEmail") == "ci@demo-proyecto.iam.gserviceaccount.com")
    #expect(!item.metadata.entries.contains { $0.value.contains("PRIVATE KEY") || $0.value.contains("NO-ES-REAL") })
    // The original stays where it was.
    #expect(FileManager.default.fileExists(atPath: source.path))

    let disk = session.disk
    #expect(permissions(disk.root) == 0o700 && permissions(disk.blobsURL) == 0o700)
    #expect(permissions(disk.indexURL) == 0o600 && permissions(disk.blobURL(item.files[0].id)) == 0o600)
    let index = try Data(contentsOf: disk.indexURL)
    #expect(index.range(of: Data("Demo Salud".utf8)) == nil && index.range(of: Data("ci@demo".utf8)) == nil)
    let blob = try Data(contentsOf: disk.blobURL(item.files[0].id))
    #expect(blob.range(of: Data("service_account".utf8)) == nil)

    // Locked: nothing in memory; unlocked again: the same index.
    session.lock()
    #expect(session.state == .locked && session.index.items.isEmpty)
    #expect(throws: VaultError.locked) { try session.fileData(item.files[0]) }
    await session.unlock()
    #expect(session.state == .unlocked)
    #expect(session.index.items.first?.id == item.id)
    #expect(try session.fileData(item.files[0]) == Data(serviceAccountJSON.utf8))

    // The log has who, what and when, never names or values.
    let log = try String(contentsOf: disk.logURL, encoding: .utf8)
    #expect(log.contains("\"addItem\"") && log.contains("\"unlock\""))
    #expect(!log.contains("Demo Salud") && !log.contains("ci@demo") && !log.contains("service-account"))
    #expect(permissions(disk.logURL) == 0o600)

    // Without its key the vault can't be opened.
    session.lock()
    keys.keys.removeAll()
    await session.unlock()
    #expect(session.state == .missingKey)
}

@Test @MainActor func locksAfterInactivity() async throws {
    let root = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    let session = newSession(root)
    #expect(await session.create())
    session.timeout = 0
    try await Task.sleep(for: .milliseconds(20))
    #expect(throws: VaultError.locked) { try session.addContainer(kind: .service, name: "github", bundleId: nil) }
    #expect(session.state == .locked)
}

@Test @MainActor func validatesNames() async throws {
    let root = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    let session = newSession(root)
    #expect(await session.create())
    #expect(throws: VaultError.invalidName) { try session.addContainer(kind: .app, name: "../fuera", bundleId: nil) }
    #expect(throws: VaultError.invalidName) { try session.addContainer(kind: .app, name: "Demo", bundleId: "no válido") }
    #expect(throws: VaultError.invalidName) { try session.addContainer(kind: .service, name: "a/b/c/d", bundleId: nil) }
    _ = try session.addContainer(kind: .service, name: "cloudflare/cuenta-principal", bundleId: nil)
    #expect(throws: VaultError.invalidName) { try session.addContainer(kind: .service, name: "Cloudflare/Cuenta-Principal", bundleId: nil) }
}

@Test @MainActor func exportsAndImportsAnEncryptedBackup() async throws {
    let root = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    let first = newSession(root.appendingPathComponent("a"))
    #expect(await first.create())
    let app = try first.addContainer(kind: .app, name: "Demo Salud", bundleId: "cl.demo.health")
    var draft = VaultItem(container: app, section: .ios, kind: .appStoreKey, name: "AuthKey_ABCD123456.p8")
    draft.fields = VaultInspector.suggestedFields(kind: .appStoreKey, fileName: draft.name)
    try await first.store(draft, files: [(draft.name, Data((PEM.begin() + "\nFALSA\n").utf8))])
    #expect(first.index.items[0].field(.keyId)?.value == "ABCD123456")
    #expect(first.index.items[0].metadata.value("vault.meta.keyId") == "ABCD123456")
    await #expect(throws: VaultError.wrongPassword) { try await first.exportArchive(nil, password: "corta") }
    let archive = try await first.exportArchive(nil, password: "contraseña de respaldo")

    let second = newSession(root.appendingPathComponent("b"))
    #expect(await second.create())
    await #expect(throws: VaultError.wrongPassword) { try await second.importArchive(archive, password: "no es la contraseña") }
    let result = try await second.importArchive(archive, password: "contraseña de respaldo")
    #expect(result.added == 1 && result.skipped == 0)
    let imported = try #require(second.index.items.first)
    #expect(imported.files[0].sha256 == first.index.items[0].files[0].sha256)
    #expect(try second.fileData(imported.files[0]) == Data((PEM.begin() + "\nFALSA\n").utf8))
    #expect(second.index.containers.first?.folderName == "Demo Salud (cl.demo.health)")
    // Importing the same file again adds nothing.
    let again = try await second.importArchive(archive, password: "contraseña de respaldo")
    #expect(again.added == 0 && again.skipped == 1)
}

// MARK: Master backup folder

@Test @MainActor func downloadsAndImportsTheMasterLayout() async throws {
    let root = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    let session = newSession(root.appendingPathComponent("a"))
    #expect(await session.create())
    let app = try session.addContainer(kind: .app, name: "Demo Salud", bundleId: "cl.demo.health", notes: "Notas de la app")
    var keystore = VaultItem(container: app, section: .android, kind: .androidKeystore, name: "upload.jks")
    keystore.fields = VaultItemKind.androidKeystore.templateFields
    keystore.fields[0].value = "upload"
    keystore.fields[1].value = "clave con espacios $y\"comillas"
    keystore.environment = .prod
    keystore.notes = "Línea 1\nLínea 2"
    try await session.store(keystore, files: [("upload.jks", Data("jks-falso".utf8))])
    try await session.store(VaultItem(container: app, section: .android, kind: .googleServices, name: "google-services.json"),
                            files: [("google-services.json", Data(googleServicesJSON.utf8))])
    let service = try session.addContainer(kind: .service, name: "cloudflare/cuenta", bundleId: nil)
    var token = VaultItem(container: service, kind: .token, name: "API token")
    token.fields = [VaultField(role: .token, value: "tok-123", secret: true, envVar: "CLOUDFLARE_API_TOKEN")]
    try await session.store(token, files: [])

    let parent = root.appendingPathComponent("drive")
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    let folder = try session.downloadFolder(nil, into: parent)
    #expect(folder.lastPathComponent == "3.CLAVES-APPS")
    let appFolder = folder.appendingPathComponent("Demo Salud (cl.demo.health)")
    for section in VaultSection.allCases {
        #expect(FileManager.default.fileExists(atPath: appFolder.appendingPathComponent(section.rawValue).path))
    }
    #expect(try Data(contentsOf: appFolder.appendingPathComponent("android/upload.jks")) == Data("jks-falso".utf8))
    let readme = try String(contentsOf: appFolder.appendingPathComponent("README.md"), encoding: .utf8)
    #expect(readme.contains("ANDROID_KEYSTORE_PASSWORD") && readme.contains("demo-salud"))
    #expect(!readme.contains("clave con espacios") && !readme.contains("jks-falso"))
    #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("_SERVICIOS/cloudflare/cuenta/API token.datos.txt").path))
    #expect(permissions(appFolder.appendingPathComponent("android/upload.jks")) == 0o600)
    // A second download never writes over the first.
    #expect(try session.downloadFolder(nil, into: parent).lastPathComponent == "3.CLAVES-APPS 2")

    // Back in, into a fresh vault: same apps, services, files and fields.
    let fresh = newSession(root.appendingPathComponent("b"))
    #expect(await fresh.create())
    let groups = fresh.markDuplicates(VaultFolder.scan(folder))
    // The account kept as `cloudflare/cuenta` comes back as an account of «cloudflare» (P-40).
    #expect(Set(groups.map(\.folderName)) == ["Demo Salud (cl.demo.health)", "cloudflare"])
    let result = await fresh.importFolder(groups)
    #expect(result.failed == 0 && result.added == 3)
    let restored = try #require(fresh.index.items.first { $0.kind == .androidKeystore })
    #expect(restored.section == .android && restored.environment == .prod)
    #expect(restored.field(.alias)?.value == "upload")
    #expect(restored.field(.storePassword)?.value == "clave con espacios $y\"comillas")
    #expect(restored.field(.storePassword)?.secret == true)
    #expect(restored.notes == "Línea 1\nLínea 2")
    #expect(fresh.index.containers.first { $0.kind == .app }?.notes.contains("Notas de la app") == true)
    let restoredToken = try #require(fresh.index.items.first { $0.name == "API token" })
    #expect(restoredToken.kind == .token && restoredToken.files.isEmpty && restoredToken.field(.token)?.value == "tok-123")
    #expect(restoredToken.account == "cuenta" && fresh.index.container(restoredToken.container)?.name == "cloudflare")
    // The source folder is untouched; a second scan sees everything as already there.
    #expect(FileManager.default.fileExists(atPath: appFolder.appendingPathComponent("android/upload.jks").path))
    let second = fresh.markDuplicates(VaultFolder.scan(folder))
    #expect(second.flatMap(\.files).allSatisfy { $0.duplicate && !$0.selected })
}

@Test func scansAppFoldersSectionsAndServices() throws {
    let root = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    let fm = FileManager.default
    let app = root.appendingPathComponent("Otra App (cl.demo.otra)")
    for path in ["android", "ios", "server", "terceros", "_SERVICIOS/github", "_SERVICIOS/gcp/proyecto-a"] {
        try fm.createDirectory(at: (path.hasPrefix("_") ? root : app).appendingPathComponent(path), withIntermediateDirectories: true)
    }
    try Data("x".utf8).write(to: app.appendingPathComponent("ios/AuthKey_ZZZZ999999.p8"))
    try Data("A=1\nB=2\n".utf8).write(to: app.appendingPathComponent("server/.env"))
    try Data("# Léeme".utf8).write(to: app.appendingPathComponent("README.md"))
    try Data(serviceAccountJSON.utf8).write(to: root.appendingPathComponent("_SERVICIOS/gcp/proyecto-a/sa.json"))
    try Data("t".utf8).write(to: root.appendingPathComponent("_SERVICIOS/github/token.txt"))
    try Data("y".utf8).write(to: app.appendingPathComponent(".DS_Store"))
    try fm.createSymbolicLink(at: app.appendingPathComponent("terceros/enlace"), withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))

    let groups = VaultFolder.scan(root)
    let appGroup = try #require(groups.first { $0.kind == .app })
    #expect(appGroup.name == "Otra App" && appGroup.bundleId == "cl.demo.otra")
    #expect(appGroup.readme != nil)
    #expect(Set(appGroup.files.map(\.name)) == ["AuthKey_ZZZZ999999.p8", ".env"])
    #expect(appGroup.files.first { $0.name == ".env" }?.section == .server)
    #expect(appGroup.files.first { $0.name.hasPrefix("AuthKey") }?.kind == .appStoreKey)
    let gcp = try #require(groups.first { $0.name == "gcp" }?.files.first)
    #expect(gcp.kind == .serviceAccount && gcp.account == "proyecto-a")
    #expect(groups.first { $0.name == "github" }?.files.first?.kind == .note)
    // Scanning one app folder directly works the same.
    #expect(VaultFolder.scan(app).first?.bundleId == "cl.demo.otra")
}

// MARK: Metadata

@Test func detectsKindsByNameAndContent() {
    #expect(VaultInspector.detectKind(name: "release.keystore", data: nil) == .androidKeystore)
    #expect(VaultInspector.detectKind(name: "dist.p12", data: nil) == .iosCertificate)
    #expect(VaultInspector.detectKind(name: "App_Store.mobileprovision", data: nil) == .provisioningProfile)
    #expect(VaultInspector.detectKind(name: "GoogleService-Info.plist", data: nil) == .googleServiceInfo)
    #expect(VaultInspector.detectKind(name: "google-services.json", data: nil) == .googleServices)
    #expect(VaultInspector.detectKind(name: "play.json", data: Data(serviceAccountJSON.utf8)) == .serviceAccount)
    #expect(VaultInspector.detectKind(name: "otro.json", data: Data("{}".utf8)) == .file)
    #expect(VaultInspector.detectKind(name: ".env.production", data: nil) == .envFile)
    #expect(VaultInspector.detectKind(name: "id_ed25519", data: nil) == .sshKey)
    #expect(VaultInspector.detectKind(name: "servidor.pem", data: Data(PEM.begin("OPENSSH PRIVATE KEY").utf8)) == .sshKey)
    #expect(VaultInspector.appStoreKeyId("AuthKey_AB12CD34EF.p8") == "AB12CD34EF")
    #expect(VaultInspector.appStoreKeyId("otra.p8") == nil)
}

@Test func readsFirebaseAndGoogleFiles() throws {
    let android = VaultInspector.googleServices(Data(googleServicesJSON.utf8))
    #expect(android.value("vault.meta.projectId") == "demo-salud")
    #expect(android.value("vault.meta.packages") == "cl.demo.health")
    let plist = try PropertyListSerialization.data(fromPropertyList: ["PROJECT_ID": "demo-salud", "BUNDLE_ID": "cl.demo.health", "API_KEY": "no-se-muestra"], format: .xml, options: 0)
    let ios = VaultInspector.googleServiceInfo(plist)
    #expect(ios.value("vault.meta.bundleId") == "cl.demo.health")
    #expect(!ios.entries.contains { $0.value == "no-se-muestra" })
    let account = VaultInspector.serviceAccount(Data(serviceAccountJSON.utf8))
    #expect(account.value("vault.meta.privateKeyId") == "01234567…")
    #expect(VaultInspector.serviceAccount(Data("{}".utf8)).problem != nil)
}

@Test func readsProvisioningProfiles() throws {
    let expires = Date(timeIntervalSince1970: 1_900_000_000)
    let plist: [String: Any] = ["Name": "Demo App Store", "TeamName": "Demo SpA", "TeamIdentifier": ["ABCDE12345"], "ExpirationDate": expires,
                                "Entitlements": ["application-identifier": "ABCDE12345.cl.demo.health", "get-task-allow": false]]
    let xml = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    // Not a valid CMS envelope: the plist is still found inside the bytes.
    let wrapped = Data([0x30, 0x80, 0x06, 0x09]) + xml + Data([0x00, 0x00, 0xA0])
    let meta = VaultInspector.provisioningProfile(wrapped)
    #expect(meta.expires == expires)
    #expect(meta.value("vault.meta.team") == "Demo SpA (ABCDE12345)")
    #expect(meta.value("vault.meta.appId") == "ABCDE12345.cl.demo.health")
    #expect(meta.value("vault.meta.profileType") == "appstore")
}

@Test func readsSignedProvisioningProfileAndCertificate() throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let openssl = "/usr/bin/openssl"
    guard runTool(openssl, ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", "key.pem", "-out", "cert.pem", "-days", "10",
                            "-subj", "/CN=Apple Distribution: Demo SpA (ABCDE12345)/OU=ABCDE12345"], in: folder) else { return }
    // A provisioning profile is a CMS-signed plist.
    let plist: [String: Any] = ["Name": "Dev", "ExpirationDate": Date(timeIntervalSince1970: 1_900_000_000), "ProvisionedDevices": ["a", "b"],
                                "Entitlements": ["get-task-allow": true]]
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: folder.appendingPathComponent("p.plist"))
    #expect(runTool(openssl, ["smime", "-sign", "-in", "p.plist", "-signer", "cert.pem", "-inkey", "key.pem", "-outform", "DER", "-nodetach", "-binary", "-out", "p.mobileprovision"], in: folder))
    do {
        let meta = VaultInspector.provisioningProfile(try Data(contentsOf: folder.appendingPathComponent("p.mobileprovision")))
        #expect(meta.value("vault.meta.profileType") == "development")
        #expect(meta.value("vault.meta.devices") == "2")
    }
    // .p12 with its password, read in memory only.
    guard runTool(openssl, ["pkcs12", "-export", "-inkey", "key.pem", "-in", "cert.pem", "-out", "c.p12", "-passout", "pass:clave-p12"], in: folder) else { return }
    let p12 = try Data(contentsOf: folder.appendingPathComponent("c.p12"))
    let good = VaultInspector.certificate(p12, password: "clave-p12", fileName: "c.p12")
    #expect(good.problem == nil)
    #expect(good.value("vault.meta.teamId") == "ABCDE12345")
    let days = (good.expires?.timeIntervalSinceNow ?? 0) / 86_400
    #expect(days > 8 && days < 11)
    var item = VaultItem(container: UUID(), kind: .iosCertificate, name: "c.p12")
    item.metadata = good
    #expect(item.expiry() == .soon)
    #expect(VaultInspector.certificate(p12, password: "otra", fileName: "c.p12").problem == "vault.meta.wrongPassword")
}

@Test func readsKeytoolOutput() {
    let text = """
    Keystore type: PKCS12
    Alias name: upload
    Creation date: Nov 12, 2026
    Owner: CN=Demo, O=Demo SpA, C=CL
    Valid from: Thu Nov 12 10:00:00 UTC 2026 until: Mon Mar 30 10:00:00 UTC 2054
    Certificate fingerprints:
    \t SHA1: AA:BB:CC
    \t SHA256: 11:22:33
    """
    let meta = VaultInspector.parseKeytool(text)
    #expect(meta.value("vault.meta.alias") == "upload")
    #expect(meta.value("vault.meta.sha1") == "AA:BB:CC")
    #expect(meta.value("vault.meta.sha256") == "11:22:33")
    #expect(meta.expires.map { Calendar(identifier: .gregorian).component(.year, from: $0) } == 2054)
}

@Test func readsKeystoreWithStackJava() throws {
    // Only where a JDK installed by Stack is found (BUTAKE_STACK_HOME in tests points to an empty store).
    guard let keytool = VaultInspector.stackKeytool() else { return }
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    guard runTool(keytool.path, ["-genkeypair", "-keystore", "k.jks", "-storetype", "PKCS12", "-alias", "upload", "-keyalg", "RSA", "-keysize", "2048",
                                 "-validity", "20", "-storepass", "clave-ks", "-keypass", "clave-ks", "-dname", "CN=Demo"], in: folder) else { return }
    let data = try Data(contentsOf: folder.appendingPathComponent("k.jks"))
    let meta = VaultInspector.keystore(data, fileName: "k.jks", password: "clave-ks", alias: "upload", keytool: keytool, disk: VaultDisk(root: folder))
    #expect(meta.value("vault.meta.sha256") != nil)
    #expect(meta.expires != nil)
}

@Test func describesSSHPublicKeysAndEnvFiles() {
    let pub = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl demo@servidor"
    let meta = VaultInspector.sshKey(Data(pub.utf8), fileName: "id_ed25519.pub")
    #expect(meta.value("vault.meta.algorithm") == "ssh-ed25519")
    #expect(meta.value("vault.meta.fingerprint")?.hasPrefix("SHA256:") == true)
    #expect(meta.value("vault.meta.comment") == "demo@servidor")
    let item = VaultItem(container: UUID(), kind: .envFile, name: ".env")
    let env = VaultInspector.inspect(item: item, data: Data("APP_KEY=secreto\nDB_PASSWORD=otro\n".utf8), fileName: ".env")
    #expect(env.value("vault.meta.variables") == "2")
    #expect(env.value("vault.meta.keys") == "APP_KEY, DB_PASSWORD")
    #expect(!env.entries.contains { $0.value.contains("secreto") })
}

@Test func dataFilesRoundTrip() {
    var item = VaultItem(container: UUID(), kind: .appStoreKey, name: "AuthKey_X.p8")
    item.fields = [VaultField(role: .keyId, value: "ABC", secret: false, envVar: "ASC_KEY_ID"),
                   VaultField(role: .custom, label: "Clave del portal", value: "a b#c", secret: true)]
    item.environment = .test
    let parsed = VaultFolder.parseDataFile(VaultFolder.dataFile(item))
    #expect(parsed.kind == .appStoreKey && parsed.environment == .test)
    #expect(parsed.fields.map(\.value) == ["ABC", "a b#c"])
    #expect(parsed.fields[1].label == "Clave del portal" && parsed.fields[1].secret && parsed.fields[1].envVar == "CLAVE_DEL_PORTAL")
    #expect(parsed.fields[0].role == .keyId)
}

/// A pasted key, a JSON of credentials or a password with a line break comes back whole from the plain folder.
@Test func dataFilesKeepValuesWithSeveralLines() {
    let pem = PEM.block("NO-ES-REAL\nSEGUNDA-LINEA")
    var item = VaultItem(container: UUID(), kind: .note, name: "Multilínea")
    item.fields = [VaultField(role: .custom, label: "Clave pegada", value: pem, secret: true),
                   VaultField(role: .custom, label: "Con CRLF", value: "a\r\nb\\n \"c\" $d", secret: true),
                   VaultField(role: .custom, label: "Ruta", value: "C:\\nueva\\carpeta", secret: false)]
    let text = VaultFolder.dataFile(item)
    #expect(text.components(separatedBy: "\n").filter { $0.hasPrefix("CLAVE_PEGADA=") }.count == 1)
    let parsed = VaultFolder.parseDataFile(text)
    #expect(parsed.fields.map(\.value) == item.fields.map(\.value))
    #expect(parsed.fields.map(\.secret) == [true, true, false])
}

/// Lines without a marker are hidden unless the name is clearly public.
@Test(arguments: [
    ("DATABASE_URL", "postgres://usuario:clave@servidor/base", true), ("DATABASE_URL", "postgres://servidor/base", false),
    ("SIGNING_KEY", "x", true), ("JWT_KEY", "x", true), ("SENTRY_DSN", "x", true), ("CREDENTIALS_JSON", "{}", true),
    ("CLAVE_PORTAL", "x", true), ("APP_KEY", "x", true), ("DB_PASSWORD", "x", true), ("API_KEY", "x", true),
    ("ASC_KEY_ID", "ABC", false), ("PORT", "8080", false), ("DB_HOST", "localhost", false), ("APP_URL", "https://demo.test", false),
    ("ALGO_RARO", "x", true),
])
func unmarkedValuesAreSecretUnlessTheNameIsClearlyPublic(name: String, value: String, secret: Bool) {
    #expect(VaultFolder.looksSecret(name: name, value: value) == secret)
    #expect(VaultFolder.parseDataFile("\(name)=\(VaultFolder.quoted(value))\n").fields.first?.secret == secret)
}

@Test @MainActor func failedIndexCommitKeepsVaultStateAndRemovesStagedBlob() async throws {
    let root = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    let session = newSession(root)
    #expect(await session.create())
    let container = try session.addContainer(kind: .app, name: "Demo", bundleId: nil)
    let before = session.index
    try FileManager.default.removeItem(at: session.disk.indexURL)
    try FileManager.default.createDirectory(at: session.disk.indexURL, withIntermediateDirectories: false)
    let draft = VaultItem(container: container, kind: .file, name: "Synthetic fixture")
    await #expect(throws: (any Error).self) {
        try await session.store(draft, files: [("fixture.txt", Data("test".utf8))])
    }
    #expect(session.index == before)
    #expect(try FileManager.default.contentsOfDirectory(atPath: session.disk.blobsURL.path).isEmpty)
}

@Test @MainActor func oversizedAttachmentRollsBackPreviouslyStagedFiles() async throws {
    let root = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    let session = newSession(root)
    #expect(await session.create())
    let container = try session.addContainer(kind: .app, name: "Demo", bundleId: nil)
    let before = session.index
    let draft = VaultItem(container: container, kind: .file, name: "Synthetic fixture")
    let oversized = Data(count: VaultFolder.maximumFileSize + 1)
    await #expect(throws: VaultError.tooLarge) {
        try await session.store(draft, files: [("fixture.txt", Data("test".utf8)), ("large.bin", oversized)])
    }
    #expect(session.index == before)
    #expect(try FileManager.default.contentsOfDirectory(atPath: session.disk.blobsURL.path).isEmpty)
}

// MARK: Vault and Entornos (what signs and publishes, not what runs)

@Test func doesNotOfferEnvFilesOrSSHKeysAsNewKinds() {
    #expect(!VaultItemKind.offered.contains(.envFile) && !VaultItemKind.offered.contains(.sshKey))
    #expect(VaultItemKind.offered.count == VaultItemKind.allCases.count - 2)
    // An item that already is one keeps its kind among the choices of its sheet.
    #expect(VaultItemKind.choices(keeping: .envFile).contains(.envFile) && !VaultItemKind.choices(keeping: .envFile).contains(.sshKey))
    #expect(VaultItemKind.choices(keeping: .token) == VaultItemKind.offered)
}

@Test @MainActor func keepsOpeningAndListingEnvFilesAndSSHKeysItAlreadyHolds() async throws {
    let root = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    let session = newSession(root)
    #expect(await session.create())
    let app = try session.addContainer(kind: .app, name: "Demo Salud", bundleId: "cl.demo.health")
    var env = VaultItem(container: app, section: .server, kind: .envFile, name: ".env.production")
    env.environment = .prod
    try await session.store(env, files: [(".env.production", Data("APP_KEY=secreto\n".utf8))])
    try await session.store(VaultItem(container: app, section: .server, kind: .sshKey, name: "deploy",
                                      fields: [VaultField(role: .passphrase, value: "frase", secret: true)]), files: [])

    // Locked and opened again, both are there as they were, listed and readable.
    session.lock()
    await session.unlock()
    let items = session.visibleItems(in: app)
    #expect(Set(items.map(\.kind)) == [.envFile, .sshKey])
    let file = try #require(items.first { $0.kind == .envFile }?.files.first)
    #expect(try session.fileData(file) == Data("APP_KEY=secreto\n".utf8))
    #expect(items.first { $0.kind == .envFile }?.environment == .prod)
    // And they travel in a backup like any other item.
    let archive = try await session.exportArchive(nil, password: "contraseña de respaldo")
    let second = newSession(root.appendingPathComponent("b"))
    #expect(await second.create())
    #expect(try await second.importArchive(archive, password: "contraseña de respaldo").added == 2)

    // New ones are not made from Finder: a dropped .env is skipped and the original stays.
    let dropped = root.appendingPathComponent(".env")
    try Data("A=1\n".utf8).write(to: dropped)
    #expect(await session.add(files: [dropped], to: app, section: nil) == 0)
    #expect(session.index.items.count == 2)
    #expect(FileManager.default.fileExists(atPath: dropped.path))
}

@Test func notesReadLikeTextWithoutTheirMarkdownHeading() {
    #expect(VaultNotes.clean("# Demo Salud\nApp de prueba.\n", title: "Demo Salud") == "App de prueba.")
    #expect(VaultNotes.clean("## Claves\nUsar en CI.", title: "Demo Salud") == "Claves\nUsar en CI.")
    #expect(VaultNotes.clean("# Demo Salud\n\n", title: "Demo Salud") == nil)
}

@Test @MainActor func showsTheStagesWithTheNamesOfTheProjectsEnvironments() {
    #expect(VaultEnvironment.test.title == L("env.kind.staging"))
    #expect(VaultEnvironment.prod.title == L("env.kind.production"))
    // What is stored does not change.
    #expect(VaultEnvironment.allCases.map(\.rawValue) == ["none", "test", "prod"])
}
