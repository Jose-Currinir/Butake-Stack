import CryptoKit
import Foundation
import LocalAuthentication
import Testing
@testable import ButakeStack

// `butakestack://vault/import?path=…` (P-38): which folders a link may propose, and that it only leaves
// the preview ready: nothing is imported without the sheet's button, and nothing is read or shown while
// the vault is locked. A made-up backup in a temporary folder and in-memory keys only.

@MainActor private final class LinkKeys: VaultKeyStore {
    var keys: [String: SymmetricKey] = [:]
    func create(keyId: String) throws -> SymmetricKey { let key = VaultCrypto.newKey(); keys[keyId] = key; return key }
    func load(keyId: String, context: LAContext?) throws -> SymmetricKey {
        guard let key = keys[keyId] else { throw VaultError.missingKey }
        return key
    }
    func delete(keyId: String) { keys[keyId] = nil }
}

/// `<raíz>/Demo Link (cl.demo.link)/04-ANDROID/PROD/…` and `<raíz>/_SERVICIOS/gcp/…`, all made up.
private func backup() throws -> URL {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("respaldo-enlace-\(UUID().uuidString)", isDirectory: true)
    let files = [
        "Demo Link (cl.demo.link)/04-ANDROID/PROD/google-services.json":
            #"{"project_info": {"project_id": "demo-link"}, "client": [{"client_info": {"android_client_info": {"package_name": "cl.demo.link"}}}]}"#,
        "Demo Link (cl.demo.link)/03-IOS/PROD/notas.md": "# Notas inventadas\n",
        "_SERVICIOS/gcp/leeme.md": "# Cuenta inventada\n",
    ]
    for (path, text) in files {
        let url = root.appendingPathComponent(path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
    return root
}

@MainActor private func session(_ root: URL) async -> VaultSession {
    let session = VaultSession(disk: VaultDisk(root: root.appendingPathComponent(".boveda")), keys: LinkKeys(), auth: ApprovingVaultAuthenticator())
    #expect(await session.create())
    return session
}

private func items(_ paths: [String]) -> [URLQueryItem] { paths.map { URLQueryItem(name: "path", value: $0) } }

private func linked(_ sheet: VaultSession.Sheet?) -> (groups: [VaultFolder.Group], linked: [String])? {
    if case .importFolder(let groups, let linked)? = sheet { return (groups, linked) }
    return nil
}

// MARK: Reading the link

@Test func aLinkProposesExistingAbsoluteFolders() throws {
    let root = try backup()
    defer { try? FileManager.default.removeItem(at: root) }
    let app = root.appendingPathComponent("Demo Link (cl.demo.link)").path
    let services = root.appendingPathComponent("_SERVICIOS").path

    #expect(try VaultImportLink.folders(items([app])).get().map(\.path) == [app])
    // Several, the same folder twice kept once, a trailing slash and `.` normalized.
    let several = try VaultImportLink.folders(items([app, services, app + "/", root.path + "/./_SERVICIOS"])).get().map(\.path)
    #expect(several == [app, services])
    // Other items of the query are not folders.
    #expect(try VaultImportLink.folders([URLQueryItem(name: "otro", value: "/tmp")] + items([services])).get().map(\.path) == [services])
    // From a real URL, with spaces and accents encoded.
    var components = URLComponents(string: "butakestack://vault/import")!
    components.queryItems = items([app, services])
    let url = try #require(components.url)
    #expect(url.host == "vault" && url.path == "/import")
    let parsed = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
    #expect(try VaultImportLink.folders(parsed).get().map(\.path) == [app, services])
}

@Test func aLinkWithABadPathIsTurnedDownWhole() throws {
    let root = try backup()
    defer { try? FileManager.default.removeItem(at: root) }
    let app = root.appendingPathComponent("Demo Link (cl.demo.link)").path
    let file = app + "/03-IOS/PROD/notas.md"
    func reason(_ items: [URLQueryItem]?) -> VaultImportLink.Reason? {
        if case .failure(let problem) = VaultImportLink.folders(items) { return problem.reason }
        return nil
    }
    #expect(reason(nil) == VaultImportLink.Reason.none)
    #expect(reason(items([""])) == .notAbsolute)
    #expect(reason(items(["Demo Link (cl.demo.link)"])) == .notAbsolute)
    #expect(reason(items(["~/respaldo"])) == .notAbsolute)
    #expect(reason(items([app + "/../Demo Link (cl.demo.link)"])) == .parent)
    #expect(reason(items([root.path + "/.."])) == .parent)
    #expect(reason(items([root.path + "/no-existe"])) == .missing)
    #expect(reason(items([file])) == .notFolder)
    // One bad path turns down the good ones with it.
    #expect(reason(items([app, file])) == .notFolder)
    #expect(reason(items(Array(repeating: app, count: VaultImportLink.maximumFolders + 1))) == .tooMany)
    // The message names the path and the reason, in Spanish.
    if case .failure(let problem) = VaultImportLink.folders(items([file])) {
        #expect(VaultImportLink.message(problem).contains(file))
    }
}

// MARK: The link only prepares

@MainActor @Test func aLinkOnlyOpensThePreviewAndImportsNothing() async throws {
    let root = try backup()
    defer { try? FileManager.default.removeItem(at: root) }
    let vault = await session(root)
    let app = root.appendingPathComponent("Demo Link (cl.demo.link)").path
    let services = root.appendingPathComponent("_SERVICIOS").path

    vault.propose(items([app, services]))
    let preview = try #require(linked(vault.sheet))
    // The same sheet as «Importar carpeta…», said to come from a link, with both folders.
    #expect(preview.linked == [app, services])
    #expect(preview.groups.contains { $0.kind == .app && $0.bundleId == "cl.demo.link" })
    #expect(preview.groups.contains { $0.kind == .service && $0.name == "gcp" })
    #expect(vault.proposedFolders.isEmpty)
    // Nothing imported until the user presses the sheet's button.
    #expect(vault.index.containers.isEmpty && vault.index.items.isEmpty)

    // The user's own choice is not marked as a link.
    vault.sheet = nil
    vault.previewImport([URL(fileURLWithPath: app)])
    #expect(linked(vault.sheet)?.linked == [])

    // A link over an open sheet replaces nothing.
    vault.propose(items([services]))
    #expect(linked(vault.sheet)?.linked == [])
    #expect(vault.message == L("vault.link.busy"))

    // Confirming is the sheet's action: only then is there something in the vault.
    let result = await vault.importFolder(preview.groups)
    #expect(result.added > 0 && !vault.index.containers.isEmpty)
}

@MainActor @Test func aBadLinkProposesNothing() async throws {
    let root = try backup()
    defer { try? FileManager.default.removeItem(at: root) }
    let vault = await session(root)
    vault.propose(items(["relativa/carpeta"]))
    #expect(vault.sheet == nil && vault.proposedFolders.isEmpty)
    #expect(vault.message == VaultImportLink.message(.init(path: "relativa/carpeta", reason: .notAbsolute)))
}

@MainActor @Test func aLockedVaultShowsNothingOfTheBackupUntilUnlocked() async throws {
    let root = try backup()
    defer { try? FileManager.default.removeItem(at: root) }
    let vault = await session(root)
    vault.lock()
    #expect(!vault.isUnlocked)
    let app = root.appendingPathComponent("Demo Link (cl.demo.link)")

    vault.propose(items([app.path]))
    // Locked: only the paths wait; no preview, no scan, nothing imported, and the link does not unlock.
    #expect(vault.sheet == nil)
    #expect(vault.proposedFolders == [app])
    #expect(!vault.isUnlocked && vault.state == .locked)
    // Asking for the preview while locked still shows nothing.
    vault.previewProposed()
    vault.previewImport([app], linked: true)
    #expect(vault.sheet == nil && vault.proposedFolders == [app])
    #expect(!vault.linkedPreviewWaiting)

    // The user unlocks (Touch ID or the Mac's password; approved here): then the same preview.
    await vault.unlock()
    let preview = try #require(linked(vault.sheet))
    #expect(preview.linked == [app.path])
    // Unlocked from another page (a project's Resumen), that page says the preview waits in the vault.
    #expect(vault.linkedPreviewWaiting)
    #expect(vault.proposedFolders.isEmpty)
    #expect(vault.index.items.isEmpty)
}

@MainActor @Test func aDiscardedProposalIsNotShownOnUnlock() async throws {
    let root = try backup()
    defer { try? FileManager.default.removeItem(at: root) }
    let vault = await session(root)
    vault.lock()
    vault.propose(items([root.appendingPathComponent("_SERVICIOS").path]))
    vault.proposedFolders = []
    await vault.unlock()
    #expect(vault.sheet == nil)
    #expect(!vault.linkedPreviewWaiting)
}
