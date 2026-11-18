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

/// A presence prompt that takes a moment, as a real one does while the user answers.
@MainActor private struct SlowPresence: VaultAuthenticator {
    func authenticate(_ reason: String) async -> LAContext? {
        try? await Task.sleep(for: .milliseconds(80))
        return LAContext()
    }
}

private func temporaryFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("vault-durable-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func mode(_ url: URL) -> Int {
    ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? NSNumber)?.intValue ?? -1
}

/// Private files are written whole or not at all: 0600 from the start, replacing what was there, no temporary left behind.
@Test func privateWritesReplaceAtomicallyAndLeaveNoTemporary() throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let target = folder.appendingPathComponent("respaldo.butakevault")
    try Data("viejo".utf8).write(to: target)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: target.path)
    let payload = Data(repeating: 7, count: 3_000_000)
    try VaultDisk.writePrivate(payload, to: target, durable: true)
    #expect(try Data(contentsOf: target) == payload)
    #expect(mode(target) == 0o600)
    #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["respaldo.butakevault"])
    // A destination that cannot be written fails and leaves the old file as it was.
    let missing = folder.appendingPathComponent("no-existe/archivo")
    #expect(throws: VaultError.io) { try VaultDisk.writePrivate(Data("x".utf8), to: missing, durable: true) }
    #expect(try Data(contentsOf: target) == payload)
}

/// A save cut short leaves the previous index; the next unlock uses it and puts it back. A finished save leaves none.
@Test func aCutIndexFallsBackToThePreviousOneAndASavedOneLeavesNoCopy() throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let disk = VaultDisk(root: folder.appendingPathComponent("vault"))
    try disk.prepare()
    let key = VaultCrypto.newKey()
    var first = VaultIndex()
    first.containers = [VaultContainer(kind: .app, name: "Primera", bundleId: nil)]
    try disk.saveIndex(first, key: key)
    #expect(!FileManager.default.fileExists(atPath: disk.previousIndexURL.path))
    var second = first
    second.containers.append(VaultContainer(kind: .app, name: "Segunda", bundleId: nil))
    try disk.saveIndex(second, key: key)
    #expect(try disk.loadIndex(key: key).containers.count == 2)
    #expect(!FileManager.default.fileExists(atPath: disk.previousIndexURL.path))

    // Power loss: the previous copy is on disk and the new index is cut short.
    try VaultDisk.writePrivate(try Data(contentsOf: disk.indexURL), to: disk.previousIndexURL)
    try Data(try Data(contentsOf: disk.indexURL).prefix(20)).write(to: disk.indexURL)
    #expect(try disk.loadIndex(key: key).containers.count == 2)
    #expect(try disk.loadIndex(key: key).containers.count == 2)
    #expect(!FileManager.default.fileExists(atPath: disk.previousIndexURL.path))
    // Without a previous copy, a damaged index is still an error.
    try Data("roto".utf8).write(to: disk.indexURL)
    #expect(throws: (any Error).self) { try disk.loadIndex(key: key) }
}

/// A file of a folder to import is read with the checks made again: a link, a folder or a big file is refused.
@Test func folderFilesAreCheckedAgainWhenRead() throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("datos.txt")
    try Data("0123456789".utf8).write(to: file)
    #expect(try VaultDisk.readRegularFile(file, limit: 10) == Data("0123456789".utf8))
    #expect(throws: VaultError.tooLarge) { try VaultDisk.readRegularFile(file, limit: 9) }
    let link = folder.appendingPathComponent("enlace.txt")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
    #expect(throws: VaultError.io) { try VaultDisk.readRegularFile(link, limit: 100) }
    #expect(throws: VaultError.io) { try VaultDisk.readRegularFile(folder, limit: 100) }
    #expect(throws: VaultError.io) { try VaultDisk.readRegularFile(folder.appendingPathComponent("falta"), limit: 100) }
}

/// A backup that could not be imported again is refused before reading a single file.
@Test func exportRefusesWhatImportWouldRefuse() throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    var index = VaultIndex()
    let container = VaultContainer(kind: .app, name: "Grande", bundleId: nil)
    index.containers = [container]
    var item = VaultItem(container: container.id, kind: .file, name: "enorme")
    item.files = [VaultFile(name: "a.bin", size: 300 * 1024 * 1024, sha256: ""), VaultFile(name: "b.bin", size: 300 * 1024 * 1024, sha256: "")]
    index.items = [item]
    let disk = VaultDisk(root: folder.appendingPathComponent("vault"))
    #expect(throws: VaultError.tooLarge) { try VaultSession.archivePayload(nil, index: index, disk: disk, key: VaultCrypto.newKey()) }
}

/// Two clicks on «Crear» while the prompt is open create one vault, not two over each other.
@Test @MainActor func creatingTwiceAtOnceCreatesOneVault() async throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let keys = Keys()
    let session = VaultSession(disk: VaultDisk(root: folder.appendingPathComponent("vault")), keys: keys, auth: SlowPresence())
    async let first = session.create()
    async let second = session.create()
    let results = await [first, second]
    #expect(results.filter { $0 }.count == 1)
    #expect(keys.keys.count == 1)
    #expect(!session.creating)
}

/// The plain download works the same off the main actor.
@Test @MainActor func theFolderCanBeDownloadedInTheBackground() async throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let session = VaultSession(disk: VaultDisk(root: folder.appendingPathComponent("vault")), keys: Keys(), auth: ApprovingVaultAuthenticator())
    #expect(await session.create())
    let app = try session.addContainer(kind: .app, name: "Demo", bundleId: "cl.demo.app")
    var draft = VaultItem(container: app, kind: .file, name: "notas.txt")
    draft.fields = [VaultField(role: .custom, label: "Clave", value: "uno\ndos", secret: true)]
    try await session.store(draft, files: [("notas.txt", Data("contenido".utf8))])
    let parent = folder.appendingPathComponent("salida")
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    let target = try await session.downloadFolderInBackground(nil, into: parent)
    #expect(target.lastPathComponent == "3.CLAVES-APPS")
    let files = FileManager.default.enumerator(atPath: target.path)?.allObjects as? [String] ?? []
    #expect(files.contains { $0.hasSuffix("notas.txt") })
    #expect(session.accessLog().contains { $0.action == .downloadFolder })
}
