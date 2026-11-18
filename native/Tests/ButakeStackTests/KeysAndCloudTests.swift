import Foundation
import Testing
@testable import ButakeStack

// The SSH keys' own session (Ajustes › Claves SSH, the Terminal) and the accounts list shared by
// the cloud tools. Made-up keys, hosts and accounts.

private let key = SSHKey(id: "servidor", name: "Servidor", description: "", group: "", kind: "ED25519 256",
                         fingerprint: "SHA256:inventada", added: 0, encrypted: false)

/// Who uses a key: the database connections the engine lists and the Terminal's hosts; a key
/// nobody uses can be deleted.
@Test @MainActor func aKeyKnowsWhoUsesItWithoutTheDatabaseClient() {
    let keyring = SSHKeyring()
    #expect(SSHKeyring.users([("servidor", "Remota"), ("otra", "Local"), ("servidor", "Réplica")])
            == ["servidor": ["Remota", "Réplica"], "otra": ["Local"]])
    keyring.connectionUsers = SSHKeyring.users([("servidor", "Remota")])
    let hosts = [
        SSHHost(id: "a", name: "Tienda", group: "", tags: [], host: "tienda.ejemplo.test", user: "deploy", key: "servidor"),
        SSHHost(id: "b", name: "Otro", group: "", tags: [], host: "otro.ejemplo.test", user: "deploy"),
    ]
    let used = keyring.users(of: key, hosts: hosts)
    #expect(used.count == 2 && used[0] == "Remota" && used[1].contains("Tienda"))
    let unused = SSHKey(id: "libre", name: "Libre", description: "", group: "", kind: "", fingerprint: "", added: 0)
    #expect(keyring.users(of: unused, hosts: hosts).isEmpty)
    // A key it does not know is not protected (nothing to ask for).
    #expect(!keyring.encrypted("servidor") && !keyring.encrypted(nil))
    keyring.sshKeys = [SSHKey(id: "servidor", name: "Servidor", description: "", group: "", kind: "", fingerprint: "", added: 0, encrypted: true)]
    #expect(keyring.encrypted("servidor"))
}

/// The SSH keys are the base's: the engine lists them with every tool off.
@Test func sshKeysAnswerWithTheTerminalOff() async throws {
    let keys: [SSHKey] = try await StackEngine().call(["method": "sshKeys"])
    #expect(keys.allSatisfy { !$0.id.isEmpty })
}

/// Google Cloud's accounts in the shared list: a section per kind in order, searched by address.
@Test func cloudAccountsGroupByKindAndSearchByName() throws {
    let accounts = try JSONDecoder().decode([GCPAccount].self, from: Data("""
    [{"account": "qa@ejemplo.test", "kind": "user", "active": true},
     {"account": "despliegue@proyecto.iam.gserviceaccount.com", "kind": "service", "active": false},
     {"account": "otra@ejemplo.test", "kind": "user", "active": false}]
    """.utf8))
    #expect(GCPAccount.Kind.allCases == [.user, .service])
    #expect(accounts.map(\.id) == accounts.map(\.account))
    #expect(accounts.filter { $0.kind == .user }.count == 2)
    #expect(accounts.filter { $0.matches("EJEMPLO") }.count == 2)
    #expect(accounts.filter { $0.matches("") }.count == 3)
    #expect(accounts.filter { $0.matches("iam") }.map(\.kind) == [.service])
}
