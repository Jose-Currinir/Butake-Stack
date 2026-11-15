import Foundation

/// What the vault no longer keeps, taken to where it lives now: a `.env` to a project's Entornos and an
/// SSH key to Ajustes › Claves SSH. Only on the user's explicit action, after the vault's own presence
/// check and a confirmation (the sheets in `VaultMoveSheets.swift`). Values go from the decrypted blob,
/// in memory, straight to their store: never to a file of Stack, a log or the screen. The result is
/// read back before the action reports success; the original is never deleted here.
@MainActor enum VaultMove {
    enum Failure: Error, Equatable {
        case noFile, empty, write, verification, passphrase
        var messageKey: String { "vault.move.error.\(self)" }
    }

    /// An environment of the project to move into; `exists` false creates it with that kind and name.
    struct EnvTarget: Hashable, Identifiable {
        let id: String
        let name: String
        let kind: EnvKind
        let exists: Bool
    }

    /// The names the move creates and the ones it replaces in the target environment.
    struct EnvPreview: Equatable {
        let added: [String]
        let replaced: [String]
    }

    // MARK: .env to Entornos

    /// The item's `.env` (its first file), decrypted and parsed in memory.
    static func envPairs(_ item: VaultItem, vault: VaultSession) throws -> [(String, String)] {
        guard let file = item.files.first else { throw Failure.noFile }
        let pairs = DotEnv.parse(String(decoding: try vault.fileData(file), as: UTF8.self))
        guard !pairs.isEmpty else { throw Failure.empty }
        return pairs
    }

    /// Only the variable names, for the preview; the values are dropped right away.
    static func envNames(_ item: VaultItem, vault: VaultSession) throws -> [String] { try envPairs(item, vault: vault).map(\.0) }

    static func preview(names: [String], existing: EnvEnvironment?) -> EnvPreview {
        let present = Set(existing?.entries.map(\.key) ?? [])
        return EnvPreview(added: names.filter { !present.contains($0) }, replaced: names.filter(present.contains))
    }

    /// The environments a project can receive the variables in: its own, then the standard ones it
    /// lacks (created by the move).
    static func targets(_ environments: [EnvEnvironment]) -> [EnvTarget] {
        let own = environments.map { EnvTarget(id: $0.id, name: $0.title, kind: $0.kind, exists: true) }
        let missing = EnvKind.allCases.compactMap { kind in
            kind.standard.flatMap { id in environments.contains { $0.id == id } ? nil : EnvTarget(id: id, name: L("env.kind.\(kind.rawValue)"), kind: kind, exists: false) }
        }
        return own + missing
    }

    /// The stage of the item, as the project's environment it suggests.
    static func suggestedTarget(for item: VaultItem, in targets: [EnvTarget], active: String?) -> EnvTarget? {
        if let kind = item.environment.envKind, let match = targets.first(where: { $0.kind == kind }) { return match }
        return targets.first { $0.id == active } ?? targets.first
    }

    /// Values to the Keychain first (what was there is put back if anything fails), then the names to
    /// the engine (`envMergeSecrets`, secrets with no value in the store, audited «mover» per key),
    /// then both read back. Returns how many variables moved.
    static func moveEnv(_ item: VaultItem, vault: VaultSession, project: String, target: EnvTarget,
                        engine: StackEngine, secrets: EnvSecretStore, actor: String) async throws -> Int {
        let pairs = try envPairs(item, vault: vault)
        let values = Dictionary(pairs, uniquingKeysWith: { _, last in last })
        let keys = Set(values.keys)
        // One read and one write of the environment's Keychain item; what was there is put back if
        // anything fails afterwards.
        guard let before = try? secrets.values(site: project, env: target.id) else { throw Failure.write }
        let previous = before.filter { keys.contains($0.key) }
        func restore() { try? secrets.update(site: project, env: target.id, set: previous, remove: keys.subtracting(previous.keys)) }
        do { try secrets.update(site: project, env: target.id, set: values, remove: []) } catch { throw Failure.write }
        var request: [String: Any] = ["method": "envMergeSecrets", "id": project, "env": target.id, "keys": pairs.map(\.0), "actor": actor]
        if !target.exists { request["kind"] = target.kind.rawValue; request["name"] = target.name }
        let site: ProjectEnvironments
        do {
            site = try await engine.call(json: try JSONSerialization.data(withJSONObject: request), as: ProjectEnvironments.self)
        } catch {
            restore()
            throw error
        }
        guard let environment = site.environments.first(where: { $0.id == target.id }),
              pairs.allSatisfy({ pair in environment.entries.contains { $0.key == pair.0 && $0.secret && $0.value.isEmpty } }),
              let stored = try? secrets.values(site: project, env: target.id),
              values.allSatisfy({ stored[$0.key] == $0.value }) else { throw Failure.verification }
        vault.disk.append(VaultAccessEntry(action: .moveToEnvironments, target: item.id))
        return pairs.count
    }

    // MARK: SSH key to Claves SSH

    /// The item's private key: its first file that holds one.
    static func privateKey(_ item: VaultItem, vault: VaultSession) throws -> (VaultFile, Data) {
        for file in item.files {
            let data = try vault.fileData(file)
            if String(decoding: data, as: UTF8.self).contains("PRIVATE KEY-----") { return (file, data) }
        }
        throw Failure.noFile
    }

    /// Imported with the engine's `sshKeyImport` from a short-lived private copy in the vault's own
    /// `tmp/` (0700, removed right after), as Ajustes › Claves SSH imports any key; the item's
    /// passphrase, if it has one, goes to the Claves SSH Keychain entry. Checked in the list of keys
    /// (and against the fingerprint the vault read, when it has one).
    static func moveKey(_ item: VaultItem, vault: VaultSession, engine: StackEngine) async throws -> SSHKey {
        let (file, data) = try privateKey(item, vault: vault)
        let copy = try vault.disk.temporaryCopy(data, name: file.name)
        defer { try? FileManager.default.removeItem(at: copy.deletingLastPathComponent()) }
        let passphrase = item.field(.passphrase)?.value.isEmpty == false ? item.field(.passphrase)?.value : nil
        var request: [String: Any] = ["method": "sshKeyImport", "path": copy.path, "name": item.name, "description": "", "group": ""]
        if let passphrase { request["passphrase"] = passphrase }
        let key: SSHKey
        do {
            key = try await engine.call(json: try JSONSerialization.data(withJSONObject: request), as: SSHKey.self)
        } catch let failure as EngineFailure where failure.code == "ssh_key_passphrase" {
            throw Failure.passphrase
        }
        if key.encrypted == true, let passphrase { SSHKeyVault.set(passphrase, for: key.id, label: key.name) }
        let keys = try await engine.call(json: try JSONSerialization.data(withJSONObject: ["method": "sshKeys"]), as: [SSHKey].self)
        func bare(_ fingerprint: String) -> String { fingerprint.replacingOccurrences(of: "SHA256:", with: "") }
        let expected = item.metadata.value("vault.meta.fingerprint").map(bare)
        guard keys.contains(where: { $0.id == key.id && $0.fingerprint == key.fingerprint }),
              expected.map({ $0 == bare(key.fingerprint) }) ?? true else { throw Failure.verification }
        vault.disk.append(VaultAccessEntry(action: .moveToKeys, target: item.id))
        return key
    }

    /// What a failed move says: its own reason, the engine's or the vault's.
    static func message(_ error: Error) -> String {
        if let failure = error as? Failure { return L(failure.messageKey) }
        if let failure = error as? EngineFailure { return failure.errorDescription ?? L("engine.requestFailed") }
        return L((error as? VaultError)?.messageKey ?? VaultError.io.messageKey)
    }
}
