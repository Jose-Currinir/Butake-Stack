import AppKit
import Foundation
import Security
import SwiftUI

// MARK: - Passphrases

/// Passphrases of Stack's SSH keys, only in the macOS Keychain: one generic password per key id,
/// this device only, never synchronized. They go to the engine per request (which hands them to
/// ssh-add / ssh-keygen through its askpass) and are never written or logged.
enum SSHKeyVault {
    /// A QA store (BUTAKE_STACK_HOME) keeps its passphrases apart from the real ones.
    static let service = "cl.butake.stack.ssh-key" + (ProcessInfo.processInfo.environment["BUTAKE_STACK_HOME"] == nil ? "" : ".qa")

    private static func base(_ id: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: id,
         kSecAttrSynchronizable as String: false]
    }
    @discardableResult static func set(_ value: String, for id: String, label: String) -> Bool {
        let query = base(id)
        let data = Data(value.utf8)
        if SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecSuccess { return true }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        add[kSecAttrLabel as String] = "Stack · SSH · \(label)"
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
    static func get(_ id: String) -> String? {
        var query = base(id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
    static func has(_ id: String) -> Bool {
        var query = base(id)
        query[kSecReturnAttributes as String] = true
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }
    static func delete(_ id: String) { SecItemDelete(base(id) as CFDictionary) }
}

// MARK: - Keys (base)

struct SSHAgentState: Codable, Sendable {
    var available: Bool
    var loaded: [String]
}

/// SSH keys of Stack's base, their own session: the list, generation, import of protected keys,
/// names and groups, the public half, the agent and who uses each key. Ajustes › Claves SSH, the
/// Terminal and the database client's connection editor read it.
@MainActor @Observable final class SSHKeyring {
    static let shared = SSHKeyring()
    let store = StackStore.shared
    var agent = SSHAgentState(available: true, loaded: [])
    var sshKeys: [SSHKey] = []
    /// Names of the database connections that use each key, by key id (read from the engine while
    /// the database client is on; the tool's own session is not needed).
    var connectionUsers: [String: [String]] = [:]
    /// A passphrase the app needs from the user (protected key without a saved one, or a wrong one).
    var prompt: PassphraseRequest?
    struct PassphraseRequest: Identifiable {
        let id = UUID()
        let keyID: String
        let name: String
        var wrong = false
        let resume: (String?, Bool) async -> Void
    }

    func encrypted(_ id: String?) -> Bool { id.flatMap { id in sshKeys.first { $0.id == id }?.encrypted } ?? false }
    func loaded(_ id: String) -> Bool { agent.loaded.contains(id) }

    func load() async {
        if let state: SSHAgentState = try? await store.call(["method": "sshKeyAgent"]) { agent = state }
        await loadKeys()
    }
    func loadKeys() async {
        sshKeys = (try? await store.call(["method": "sshKeys"])) ?? sshKeys
    }

    /// Who uses a key (it cannot be removed while someone does): database connections and the
    /// Terminal's hosts, by name.
    func users(of key: SSHKey, hosts: [SSHHost]) -> [String] {
        (connectionUsers[key.id] ?? []) + hosts.filter { $0.key == key.id }.map { String(format: L("ssh.keys.hostUser"), $0.name) }
    }
    /// The database connections that use each key, straight from the engine.
    func loadConnectionUsers() async {
        guard store.pluginEnabled("database-client") else { connectionUsers = [:]; return }
        struct Connection: Decodable { struct SSH: Decodable { var key: String? }; var name: String; var ssh: SSH? }
        guard let list: [Connection] = try? await store.call(["method": "dbConnections"]) else { return }
        connectionUsers = Self.users(list.compactMap { connection in connection.ssh?.key.map { ($0, connection.name) } })
    }
    /// (key id, connection name) pairs grouped by key, in their order.
    nonisolated static func users(_ pairs: [(String, String)]) -> [String: [String]] {
        pairs.reduce(into: [:]) { $0[$1.0, default: []].append($1.1) }
    }

    func updateKey(_ key: SSHKey) async {
        do {
            let _: SSHKey = try await store.call(["method": "sshKeyUpdate", "id": key.id, "name": key.name, "description": key.description, "group": key.group])
            await loadKeys()
        } catch { store.report(error) }
    }
    /// Deletes a key the user confirmed; its saved passphrase goes with it.
    func deleteKey(_ key: SSHKey) async {
        do {
            let _: Bool = try await store.call(["method": "sshKeyDelete", "id": key.id])
            await loadKeys()
            if !sshKeys.contains(where: { $0.id == key.id }) { SSHKeyVault.delete(key.id) }
        } catch { store.report(error) }
    }

    /// Imports a key; a protected one asks for its passphrase (and may keep it in the Keychain).
    func importKey(_ url: URL, name: String, description: String, group: String, passphrase: String? = nil, remember: Bool = true) async -> Bool {
        var request: [String: Any] = ["method": "sshKeyImport", "path": url.path, "name": name, "description": description, "group": group]
        if let passphrase { request["passphrase"] = passphrase }
        do {
            let key: SSHKey = try await store.call(request)
            if let passphrase, remember, key.encrypted == true { SSHKeyVault.set(passphrase, for: key.id, label: key.name) }
            await load()
            store.notify(String(format: L("ssh.keys.imported"), key.name))
            return true
        } catch let failure as EngineFailure where failure.code == "ssh_key_passphrase" {
            prompt = PassphraseRequest(keyID: "", name: name.isEmpty ? url.lastPathComponent : name, wrong: passphrase != nil) { value, keep in
                guard let value else { return }
                _ = await self.importKey(url, name: name, description: description, group: group, passphrase: value, remember: keep)
            }
            return true
        } catch { store.report(error); return false }
    }

    func generate(name: String, description: String, group: String, comment: String, passphrase: String, remember: Bool) async -> Bool {
        var request: [String: Any] = ["method": "sshKeyGenerate", "name": name, "description": description, "group": group, "comment": comment]
        if !passphrase.isEmpty { request["passphrase"] = passphrase }
        do {
            let key: SSHKey = try await store.call(request)
            if !passphrase.isEmpty, remember { SSHKeyVault.set(passphrase, for: key.id, label: key.name) }
            await load()
            store.notify(String(format: L("ssh.keys.generated"), key.name))
            return true
        } catch { store.report(error); return false }
    }

    func publicKey(_ id: String) async -> String? {
        do { return try await store.call(["method": "sshKeyPublic", "id": id]) as String } catch { store.report(error); return nil }
    }
    func copyPublicKey(_ id: String) async {
        guard let text = await publicKey(id) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        store.notify(L("ssh.keys.publicCopied"))
    }
    func exportPublicKey(_ key: SSHKey) async {
        guard let text = await publicKey(key.id) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(key.id).pub"
        panel.message = L("ssh.keys.exportMessage")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try (text + "\n").write(to: url, atomically: true, encoding: .utf8) } catch { store.errorMessage = L("ssh.keys.exportFailed") }
    }

    /// Makes sure a protected key is in the agent (BatchMode forwards and SFTP need it). With
    /// `interactive`, a missing or wrong passphrase is asked; otherwise it just reports false.
    func ensureAgent(_ id: String?, interactive: Bool = true) async -> Bool {
        // Called by the database client and the Terminal before the keys were shown anywhere.
        if sshKeys.isEmpty { await loadKeys() }
        guard let id, encrypted(id) else { return true }
        if let state: SSHAgentState = try? await store.call(["method": "sshKeyAgent"]) { agent = state }
        if loaded(id) { return true }
        if !agent.available { if interactive { store.errorMessage = L("error.ssh_agent_missing") }; return false }
        if let saved = SSHKeyVault.get(id), await loadIntoAgent(id, passphrase: saved, quiet: true) { return true }
        guard interactive else { return false }
        let name = sshKeys.first { $0.id == id }?.name ?? id
        return await withCheckedContinuation { continuation in
            prompt = PassphraseRequest(keyID: id, name: name, wrong: SSHKeyVault.has(id)) { value, keep in
                guard let value else { continuation.resume(returning: false); return }
                let ok = await self.loadIntoAgent(id, passphrase: value, quiet: false)
                if ok, keep { SSHKeyVault.set(value, for: id, label: name) }
                continuation.resume(returning: ok)
            }
        }
    }
    /// Puts a key in the agent whether it is protected or not: Git's own `ssh` only finds Stack's
    /// keys there. A protected one asks for its passphrase as `ensureAgent` does.
    func offerToAgent(_ key: SSHKey) async -> Bool {
        if key.encrypted == true { return await ensureAgent(key.id) }
        if let state: SSHAgentState = try? await store.call(["method": "sshKeyAgent"]) { agent = state }
        if !agent.available { store.errorMessage = L("error.ssh_agent_missing"); return false }
        return await loadIntoAgent(key.id, passphrase: "", quiet: false)
    }
    @discardableResult func loadIntoAgent(_ id: String, passphrase: String, quiet: Bool) async -> Bool {
        do {
            let _: Bool = try await store.call(["method": "sshKeyAgentLoad", "id": id, "passphrase": passphrase])
            if let state: SSHAgentState = try? await store.call(["method": "sshKeyAgent"]) { agent = state }
            return true
        } catch { if !quiet { store.report(error) }; return false }
    }
    func unload(_ id: String) async {
        do {
            let _: Bool = try await store.call(["method": "sshKeyAgentUnload", "id": id])
            if let state: SSHAgentState = try? await store.call(["method": "sshKeyAgent"]) { agent = state }
        } catch { store.report(error) }
    }
}
