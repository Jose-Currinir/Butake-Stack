import AppKit
import CryptoKit
import Foundation
import LocalAuthentication

/// The vault in and out of this Mac: the encrypted backup (`.butakevault`) and the plain folder
/// of the master backup layout.
extension VaultSession {
    // MARK: Encrypted backup (.butakevault)

    /// Reads, decrypts and checks every file of the chosen containers. Pure work on a copy of the index: it runs off the main actor.
    nonisolated static func archivePayload(_ containers: [UUID]?, index: VaultIndex, disk: VaultDisk, key: SymmetricKey) throws -> VaultArchive.Payload {
        let ids = containers ?? index.containers.map(\.id)
        let chosen = index.containers.filter { ids.contains($0.id) }
        let items = index.items.filter { ids.contains($0.container) }
        // The file would not import back (`decode` refuses more than the maximum): say so before reading anything.
        // Base64 and the JSON around it take about a third more than the files themselves.
        let total = items.reduce(0) { $0 + $1.files.reduce(0) { $0 + $1.size } }
        guard total / 3 * 4 <= VaultArchive.maximumSize else { throw VaultError.tooLarge }
        var blobs: [String: Data] = [:]
        for item in items {
            for file in item.files {
                try Task.checkCancellation()
                blobs[file.id.uuidString] = try fileData(file, disk: disk, key: key)
            }
        }
        return VaultArchive.Payload(containers: chosen, items: items, blobs: blobs)
    }

    func archivePayload(_ containers: [UUID]?) throws -> VaultArchive.Payload {
        try Self.archivePayload(containers, index: index, disk: disk, key: try requireKey())
    }

    /// The caller has already confirmed presence (export asks every time).
    func exportArchive(_ container: UUID?, password: String) async throws -> Data {
        guard password.count >= VaultArchive.minimumPasswordLength else { throw VaultError.wrongPassword }
        let key = try requireKey()
        let (snapshot, disk) = (index, disk)
        let scope = container.flatMap { index.container($0)?.folderName } ?? "all"
        let iterations = archiveIterations
        let generation = sessionGeneration
        // Reading, decrypting and sealing hundreds of MiB happen together off the main actor.
        let data = try await Task.detached(priority: .userInitiated) {
            let payload = try Self.archivePayload(container.map { [$0] }, index: snapshot, disk: disk, key: key)
            let sealed = try VaultArchive.encode(payload, password: password, scope: scope, iterations: iterations)
            guard sealed.count <= VaultArchive.maximumSize else { throw VaultError.tooLarge }
            return sealed
        }.value
        try checkSession(generation)
        disk.append(VaultAccessEntry(action: .exportArchive, target: container))
        return data
    }

    /// Merges a backup: apps and services matched by folder name, files already there (same hash) skipped.
    @discardableResult func importArchive(_ data: Data, password: String) async throws -> (added: Int, skipped: Int) {
        let key = try requireKey()
        let generation = sessionGeneration
        let (_, payload) = try await Task.detached(priority: .userInitiated) { try VaultArchive.decode(data, password: password) }.value
        try checkSession(generation)
        var candidate = index
        var written: [UUID] = []
        var committed = false
        defer { if !committed { for id in written { disk.deleteBlob(id) } } }
        var added = 0, skipped = 0
        var mapping: [UUID: UUID] = [:]
        for container in payload.containers {
            guard container.kind == .app ? VaultNames.isSafeComponent(container.name) : VaultNames.isServicePath(container.name) else { continue }
            if let existing = candidate.containers.first(where: { $0.kind == container.kind && $0.folderName.lowercased() == container.folderName.lowercased() }) {
                mapping[container.id] = existing.id
            } else {
                var copy = container
                copy.id = UUID()
                candidate.containers.append(copy)
                mapping[container.id] = copy.id
            }
        }
        for original in payload.items {
            guard let target = mapping[original.container] else { continue }
            let existing = candidate.items(in: target)
            let hashes = Set(existing.flatMap { $0.files.map(\.sha256) })
            if (!original.files.isEmpty && original.files.allSatisfy { hashes.contains($0.sha256) })
                || (original.files.isEmpty && existing.contains { $0.name == original.name && $0.kind == original.kind && $0.fields.map(\.value) == original.fields.map(\.value) }) {
                skipped += 1; continue
            }
            var item = original
            item.id = UUID()
            item.container = target
            item.files = []
            for file in original.files {
                guard let blob = payload.blobs[file.id.uuidString] else { throw VaultError.corrupt }
                var copy = file
                copy.id = UUID()
                copy.name = VaultNames.safeFileName(file.name)
                try disk.writeBlob(blob, id: copy.id, key: key)
                written.append(copy.id)
                guard VaultCrypto.sha256(try disk.readBlob(copy.id, key: key)) == file.sha256 else { throw VaultError.corrupt }
                item.files.append(copy)
            }
            candidate.items.append(item)
            added += 1
        }
        try persist(candidate)
        committed = true
        disk.append(VaultAccessEntry(action: .importArchive))
        return (added, skipped)
    }

    // MARK: Plain folder (master backup layout)

    /// Writes a new `3.CLAVES-APPS` folder (never over an existing one) inside `parent`.
    @discardableResult func downloadFolder(_ container: UUID?, into parent: URL, layout: VaultFolder.Layout = .stack) throws -> URL {
        let target = try Self.writeFolder(container, index: index, disk: disk, key: try requireKey(), into: parent, layout: layout)
        disk.append(VaultAccessEntry(action: .downloadFolder, target: container))
        return target
    }

    /// The same, with the reading, decrypting and writing off the main actor.
    @discardableResult func downloadFolderInBackground(_ container: UUID?, into parent: URL, layout: VaultFolder.Layout = .stack) async throws -> URL {
        let key = try requireKey()
        let (snapshot, disk) = (index, disk)
        let target = try await Task.detached(priority: .userInitiated) {
            try Self.writeFolder(container, index: snapshot, disk: disk, key: key, into: parent, layout: layout)
        }.value
        disk.append(VaultAccessEntry(action: .downloadFolder, target: container))
        return target
    }

    nonisolated private static func writeFolder(_ container: UUID?, index: VaultIndex, disk: VaultDisk, key: SymmetricKey,
                                                into parent: URL, layout: VaultFolder.Layout) throws -> URL {
        let ids = container.map { [$0] } ?? index.containers.map(\.id)
        let plan = VaultFolder.plan(index, containers: ids, layout: layout)
        let fm = FileManager.default
        var target = parent.appendingPathComponent("3.CLAVES-APPS", isDirectory: true)
        var counter = 2
        while fm.fileExists(atPath: target.path) {
            target = parent.appendingPathComponent("3.CLAVES-APPS \(counter)", isDirectory: true); counter += 1
        }
        try VaultDisk.makePrivateDirectory(target)
        let base = target.standardizedFileURL.path
        func resolve(_ relative: String) throws -> URL {
            let url = target.appendingPathComponent(relative).standardizedFileURL
            guard url.path.hasPrefix(base + "/") else { throw VaultError.invalidName }
            return url
        }
        for directory in plan.directories { try VaultDisk.makePrivateDirectory(try resolve(directory)) }
        for entry in plan.files {
            try Task.checkCancellation()
            let url = try resolve(entry.path)
            try VaultDisk.makePrivateDirectory(url.deletingLastPathComponent())
            let data: Data
            switch entry.source {
            case .text(let text): data = Data(text.utf8)
            case .blob(let id): data = try disk.readBlob(id, key: key)
            }
            guard !fm.fileExists(atPath: url.path),
                  fm.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) else { throw VaultError.io }
        }
        return target
    }
}
