import CryptoKit
import Foundation
import LocalAuthentication
import Testing
@testable import ButakeStack

// A real keys backup into the vault (P-33): what the scan recognizes and leaves out, passwords and
// values joined to their files without ever showing them, and «Firma», which crosses it all. Made-up
// files only (`VaultBackupFixture`), in-memory keys: never the Keychain nor real data.

@MainActor private final class Keys: VaultKeyStore {
    var keys: [String: SymmetricKey] = [:]
    func create(keyId: String) throws -> SymmetricKey { let key = VaultCrypto.newKey(); keys[keyId] = key; return key }
    func load(keyId: String, context: LAContext?) throws -> SymmetricKey {
        guard let key = keys[keyId] else { throw VaultError.missingKey }
        return key
    }
    func delete(keyId: String) { keys[keyId] = nil }
}

@MainActor private func vault(_ root: URL) async -> VaultSession {
    let session = VaultSession(disk: VaultDisk(root: root.appendingPathComponent("vault")), keys: Keys(), auth: ApprovingVaultAuthenticator())
    session.archiveIterations = VaultArchive.minimumIterations
    #expect(await session.create())
    return session
}

private func noSentinel(in text: String, _ where_: String) {
    for sentinel in VaultBackupFixture.sentinels { #expect(!text.contains(sentinel), "\(where_) shows a sentinel") }
}

/// Every file under `root` whose bytes contain a sentinel.
private func filesWithSentinels(under root: URL) -> [String] {
    let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])
    var found: [String] = []
    while let url = enumerator?.nextObject() as? URL {
        guard let data = try? Data(contentsOf: url) else { continue }
        if VaultBackupFixture.sentinels.contains(where: { data.range(of: Data($0.utf8)) != nil }) { found.append(url.path) }
    }
    return found
}

// MARK: Layout and companions

@Test func readsTheFoldersOfARealBackup() {
    #expect(VaultBackupLayout.section(forFolder: "03-IOS") == .ios)
    #expect(VaultBackupLayout.section(forFolder: "04-ANDROID") == .android)
    #expect(VaultBackupLayout.section(forFolder: "01-API") == .server)
    #expect(VaultBackupLayout.section(forFolder: "02-WEB") == .server)
    #expect(VaultBackupLayout.section(forFolder: "05-TERCEROS") == .terceros)
    #expect(VaultBackupLayout.section(forFolder: "android") == .android)
    #expect(VaultBackupLayout.environment(forFolder: "QA") == .test)
    #expect(VaultBackupLayout.environment(forFolder: "PROD") == .prod)
    #expect(VaultBackupLayout.excluded(folder: "99-HISTORICO-TRANSICION") == .history)
    #expect(VaultBackupLayout.excluded(folder: "_archive") == .archive)
    #expect(VaultBackupLayout.excluded(folder: "backups") == .backups)
    #expect(VaultBackupLayout.excluded(file: "base.dump") == .dump && VaultBackupLayout.excluded(file: "x.contenido.txt") == .dump)
    #expect(VaultBackupLayout.excluded(file: "dist.p12") == nil)
}

@Test func readsCompanionValuesWithoutGuessing() {
    #expect(VaultCompanions.source(of: "dist.p12.pass") == .password)
    #expect(VaultCompanions.source(of: "dist.clave") == .password)
    #expect(VaultCompanions.passwordTarget("dist.p12.password") == "dist.p12")
    #expect(VaultCompanions.source(of: "CREDENTIALS.txt") == .credentials)
    #expect(VaultCompanions.source(of: "fastlane.env") == .fastlane)
    #expect(VaultCompanions.source(of: "FIREBASE_APP_ID.txt") == .value)
    #expect(VaultCompanions.source(of: "README.txt") == nil)
    #expect(VaultCompanions.password("clave con espacio \n") == "clave con espacio ")
    #expect(VaultCompanions.value("uno\ndos") == nil)
    let same = VaultCompanions.credentials("* Store password: abc\n* Alias: upload\n* Key password: la misma (que la del almacén)\n")
    #expect(same[.storePassword] == "abc" && same[.alias] == "upload" && same[.keyPassword] == "abc")
    let bold = VaultCompanions.credentials("- **Store password:** a b\n- **Alias:** upload\n")
    #expect(bold[.storePassword] == "a b" && bold[.alias] == "upload")
    let other = VaultCompanions.credentials("storePassword=uno\nkeyAlias=key0\nkeyPassword=dos\nstoreFile=upload.jks\n")
    #expect(other[.storePassword] == "uno" && other[.alias] == "key0" && other[.keyPassword] == "dos")
    let asc = VaultCompanions.fastlane("ASC_KEY_ID=\"AB12\"\nASC_ISSUER_ID=uuid-1\nOTRA=x\n")
    #expect(asc[.keyId] == "AB12" && asc[.issuerId] == "uuid-1" && asc.count == 2)
}

@Test func scanRecognizesARealBackupAndShowsNoValue() throws {
    guard let fixture = try VaultBackupFixture.make() else { return }
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let groups = VaultFolder.scan(fixture.root)
    // Nothing the preview holds carries a value: only names, paths and the roles a companion brings.
    noSentinel(in: String(describing: groups), "the scan")
    let app = try #require(groups.first { $0.kind == .app })
    #expect(app.name == "Demo Salud" && app.bundleId == "cl.demo.health")
    func file(_ relative: String) -> VaultFolder.Candidate? { app.files.first { $0.relative.hasSuffix(relative) } }

    let p12 = try #require(file("03-IOS/PROD/dist.p12"))
    #expect(p12.kind == .iosCertificate && p12.section == .ios)
    #expect(p12.companions.map(\.source) == [.password] && p12.companions[0].certain && p12.companions[0].roles == [.password])
    // The same certificate in QA: listed unselected as a copy; the first one counts for both stages.
    let copy = try #require(file("03-IOS/QA/dist.p12"))
    #expect(copy.copyOf != nil && !copy.selected)
    #expect(p12.environment == .none)
    // CREDENTIALS.txt belongs to the keystore: without a JDK there is none, and it stays a note of its own.
    let companionsLeft = app.files.filter { $0.name.hasSuffix(".pass") || $0.name.hasSuffix(".clave") || $0.name == "fastlane.env"
        || ($0.name == "CREDENTIALS.txt" && fixture.hasKeystore) }
    #expect(companionsLeft.isEmpty, "companions listed as files: \(companionsLeft.map(\.relative))")
    #expect(file("AppStore_main.mobileprovision")?.environment == .prod)
    #expect(file("AdHoc_main.mobileprovision")?.environment == .test)
    let key = try #require(file("AuthKey_ABC123DEF4.p8"))
    #expect(key.kind == .appStoreKey && Set(key.companions.flatMap(\.roles)) == [.keyId, .issuerId])
    #expect(file("distribucion.key")?.kind == .certificateKey)
    let firebase = try #require(app.files.first { $0.name == "FIREBASE_APP_ID" })
    #expect(firebase.valueOnly && firebase.kind == .token && firebase.section == .android && firebase.environment == .prod)
    if fixture.hasKeystore {
        let keystore = try #require(file("upload.jks"))
        #expect(keystore.kind == .androidKeystore && Set(keystore.companions.flatMap(\.roles)) == [.storePassword, .alias, .keyPassword])
    }
    // Left out by default: history, archives, dumps and the .env (it goes to Entornos).
    #expect(file("99-HISTORICO-TRANSICION/viejo.cer")?.exclusion == .history)
    #expect(file("_archive/AppStore_2024.mobileprovision")?.exclusion == .archive)
    #expect(file("base.dump")?.exclusion == .dump)
    #expect(file("01-API/PROD/.env")?.kind == .envFile)
    #expect(app.files.filter { $0.exclusion != nil }.allSatisfy { !$0.selected })
    // Services: the push key is told apart from the App Store Connect one.
    #expect(groups.first { $0.name == "apple-apns" }?.files.first?.kind == .apnsKey)
    #expect(groups.first { $0.name == "google-play" }?.files.first?.kind == .serviceAccount)
}

@Test func aPasswordWithoutAClearOwnerIsOnlyProposed() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("propuesta-\(UUID().uuidString)/App (cl.demo.app)/03-IOS", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent().deletingLastPathComponent()) }
    try Data("p12-falso".utf8).write(to: root.appendingPathComponent("certificado.p12"))
    try Data(VaultBackupFixture.p12Password.utf8).write(to: root.appendingPathComponent("otro-nombre.pass"))
    let files = VaultFolder.scan(root.deletingLastPathComponent()).first?.files ?? []
    let p12 = try #require(files.first { $0.name == "certificado.p12" })
    #expect(p12.companions.count == 1 && !p12.companions[0].certain && !p12.companions[0].used)
}

// MARK: Import and «Firma»

@Test @MainActor func importsARealBackupAndChecksItsSigning() async throws {
    guard let fixture = try VaultBackupFixture.make() else { return }
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("boveda-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let session = await vault(root)
    let groups = session.markDuplicates(VaultFolder.scan(fixture.root))
    let result = await session.importFolder(groups)
    #expect(result.failed == 0)

    let items = session.index.items
    let p12 = try #require(items.first { $0.kind == .iosCertificate })
    #expect(p12.field(.password)?.value == VaultBackupFixture.p12Password && p12.field(.password)?.secret == true)
    #expect(p12.metadata.problem == nil && p12.metadata.value("vault.meta.sha1") != nil)
    #expect(items.filter { $0.kind == .iosCertificate }.count == 1)
    let key = try #require(items.first { $0.kind == .appStoreKey })
    #expect(key.field(.keyId)?.value == "ABC123DEF4" && key.field(.issuerId)?.value == VaultBackupFixture.issuerId)
    let firebase = try #require(items.first { VaultSigning.isFirebaseAppId($0) })
    #expect(firebase.files.isEmpty && firebase.field(.token)?.value == VaultBackupFixture.firebaseAppId && firebase.environment == .prod)
    let profile = try #require(items.first { $0.name == "AppStore_main.mobileprovision" })
    #expect(profile.metadata.value("vault.meta.certificates")?.contains(p12.metadata.value("vault.meta.sha1") ?? "-") == true)
    #expect(profile.metadata.value("vault.meta.entitlements")?.contains("HealthKit") == true)
    #expect(!items.contains { $0.kind == .envFile || $0.name == "base.dump" || $0.name == "viejo.cer" })
    if fixture.hasKeystore {
        let keystore = try #require(items.first { $0.kind == .androidKeystore })
        #expect(keystore.field(.storePassword)?.value == VaultBackupFixture.storePassword)
        #expect(keystore.field(.keyPassword)?.value == VaultBackupFixture.storePassword && keystore.field(.alias)?.value == "upload")
        #expect(keystore.metadata.value("vault.meta.alias") == "upload" && keystore.metadata.value("vault.meta.sha256") != nil)
    }

    let app = try #require(session.index.containers.first { $0.kind == .app })
    let prod = VaultSigning.rows(for: app, environment: .prod, in: session.index)
    func status(_ rows: [VaultSigning.Row], _ id: String) -> VaultSigning.Status? { rows.first { $0.id == id }?.status }
    #expect(status(prod, "ios.profile.cl.demo.health") == .ready)
    // The widget's profile includes a certificate whose .p12 is not in the vault.
    #expect(status(prod, "ios.profile.cl.demo.health.widget") == .mismatch)
    #expect(status(prod, "ios.appStoreKey") == .ready)
    #expect(status(prod, "ios.googleServiceInfo") == .ready)
    #expect(status(prod, "android.googleServices") == .ready)
    #expect(status(prod, "android.play") == .ready)
    #expect(status(prod, "android.firebaseAppId") == .ready)
    #expect(status(prod, "android.keystore") == (fixture.hasKeystore ? .ready : .missing))
    let qa = VaultSigning.rows(for: app, environment: .test, in: session.index)
    // QA: the ad hoc profile signs with the vault's certificate; the plist is another app's.
    #expect(status(qa, "ios.profile.cl.demo.health") == .ready)
    #expect(status(qa, "ios.googleServiceInfo") == .mismatch)
    #expect(status(qa, "android.googleServices") == .ready)
    #expect(status(qa, "android.firebaseAppId") == .missing)
    let text = (prod + qa).map { [$0.title, $0.detail, $0.advice ?? ""].joined(separator: " ") }.joined(separator: "\n")
    noSentinel(in: text + VaultSigning.summary(prod), "«Firma»")

    // Nothing in clear on disk: index, blobs and the access log hold no sentinel.
    #expect(filesWithSentinels(under: root).isEmpty)
    noSentinel(in: String(describing: session.accessLog()), "the access log")
    #expect(await session.reread(app.id) == 0)
}

@Test @MainActor func downloadsInTheBackupLayoutAndReadsItBack() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("descarga-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let session = await vault(root.appendingPathComponent("a"))
    let app = try session.addContainer(kind: .app, name: "Demo", bundleId: "cl.demo.app")
    var certificate = VaultItem(container: app, section: .ios, kind: .iosCertificate, name: "dist.p12", environment: .prod)
    certificate.fields = [VaultField(role: .password, value: VaultBackupFixture.p12Password, secret: true, envVar: "IOS_CERTIFICATE_PASSWORD")]
    try await session.store(certificate, files: [("dist.p12", Data("p12-falso".utf8))])
    try await session.store(VaultItem(container: app, section: .android, kind: .googleServices, name: "google-services.json", environment: .test),
                            files: [("google-services.json", Data(String(format: VaultBackupFixture.googleServices, "cl.demo.app.qa").utf8))])
    let parent = root.appendingPathComponent("drive")
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    let folder = try session.downloadFolder(nil, into: parent, layout: .backup)
    let base = folder.appendingPathComponent("Demo (cl.demo.app)")
    #expect(FileManager.default.fileExists(atPath: base.appendingPathComponent("03-IOS/PROD/dist.p12").path))
    #expect(FileManager.default.fileExists(atPath: base.appendingPathComponent("04-ANDROID/QA/google-services.json").path))
    let readme = try String(contentsOf: base.appendingPathComponent("README.md"), encoding: .utf8)
    #expect(!readme.contains(VaultBackupFixture.p12Password))

    let fresh = await vault(root.appendingPathComponent("b"))
    _ = await fresh.importFolder(fresh.markDuplicates(VaultFolder.scan(folder)))
    let back = try #require(fresh.index.items.first { $0.kind == .iosCertificate })
    #expect(back.environment == .prod && back.section == .ios && back.field(.password)?.value == VaultBackupFixture.p12Password)
    #expect(fresh.index.items.first { $0.kind == .googleServices }?.environment == .test)
}

@Test func anIndexWithAKindFromALaterVersionStillOpens() throws {
    let json = #"{"version":1,"containers":[],"items":[{"id":"\#(UUID().uuidString)","container":"\#(UUID().uuidString)","kind":"algoNuevo","name":"x","files":[],"fields":[],"notes":"","environment":"none","created":"2026-11-14T00:00:00Z","updated":"2026-11-14T00:00:00Z","metadata":{"entries":[]}}]}"#
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let index = try decoder.decode(VaultIndex.self, from: Data(json.utf8))
    #expect(index.items.first?.kind == .file)
    // The new kinds are written as kinds every version knows, and read back as themselves.
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let item = VaultItem(container: UUID(), section: .ios, kind: .apnsKey, name: "AuthKey_PUSH123456.p8")
    let data = try encoder.encode(item)
    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["kind"] as? String == "appStoreKey" && object["kindDetail"] as? String == "apnsKey")
    #expect(try decoder.decode(VaultItem.self, from: data).kind == .apnsKey)
    #expect(try JSONSerialization.jsonObject(with: encoder.encode(VaultItem(container: UUID(), kind: .token, name: "x"))) as? [String: Any] != nil)
}
