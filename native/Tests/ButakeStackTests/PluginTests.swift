import Foundation
import Testing
@testable import ButakeStack

/// The catalog decodes, the SSH terminal answers only once turned on, and a saved host with its
/// forwards comes back as the app reads it.
@Test func sshTerminalIsAPluginWithSavedHosts() async throws {
    // Its own store: other tests turn tools on and off in the shared one at the same time.
    guard let (engine, _) = try isolatedEngine() else { return }
    let catalog: [ToolInfo] = try await engine.call(["method": "pluginCatalog"])
    #expect(catalog.contains { $0.id == "database-client" && $0.installed && $0.enabled })
    #expect(catalog.contains { $0.id == "ssh-terminal" })
    _ = try await engine.call(["method": "pluginSetEnabled", "id": "ssh-terminal", "enabled": true], as: [ToolInfo].self)
    let host = SSHHost(name: "Bastión QA", group: "Pruebas", host: "bastion.ejemplo.cl", port: 2222, user: "deploy",
                       forwards: [SSHForward(name: "Base", kind: "local", listenPort: 25432, targetHost: "db.interna", targetPort: 5432)])
    let body = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(host)) as? [String: Any])
    let saved: SSHHost = try await engine.call(["method": "sshSaveHost", "host": body])
    #expect(saved.id == "bastion-qa" && saved.forwards.first?.id == "base")
    let overview: SSHOverview = try await engine.call(["method": "sshHosts"])
    #expect(overview.hosts.contains { $0.id == "bastion-qa" && $0.address == "deploy@bastion.ejemplo.cl:2222" })
    #expect(overview.active.isEmpty)
    #expect(try #require(saved.forwards.first).route == "127.0.0.1:25432 → db.interna:5432")

    // A host behind a jump, with tags and a kept-alive forward, as the app sends and reads it.
    let inner = SSHHost(name: "Interno QA", tags: ["qa", " QA ", "aws"], host: "10.0.0.5", user: "app", jump: "bastion-qa",
                        forwards: [SSHForward(kind: "dynamic", listenPort: 28080, keepAlive: true)])
    let innerBody = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(inner)) as? [String: Any])
    let savedInner: SSHHost = try await engine.call(["method": "sshSaveHost", "host": innerBody])
    #expect(savedInner.tags == ["qa", "aws"] && savedInner.jump == "bastion-qa")
    #expect(try #require(savedInner.forwards.first).keepAlive)
    #expect(savedInner.matches("AWS") && !savedInner.matches("nada"))
    struct Launch: Decodable, Sendable { var executable: String; var args: [String]; var title: String }
    let launch: Launch = try await engine.call(["method": "sshSession", "id": savedInner.id])
    #expect(launch.executable == "/usr/bin/ssh" && launch.args.suffix(2) == ["--", "app@10.0.0.5"])
    #expect(launch.args.contains("StrictHostKeyChecking=yes") && launch.args.contains { $0.hasPrefix("ProxyCommand='/usr/bin/ssh'") })
    let line: String = try await engine.call(["method": "sshCommand", "id": savedInner.id])
    #expect(line.hasPrefix("'/usr/bin/ssh' '-o' 'StrictHostKeyChecking=yes'") && line.hasSuffix("'--' 'app@10.0.0.5'"))

    // Snippets: global and per host; escape sequences are refused.
    let snippet = SSHSnippet(name: "Espacio", command: "df -h")
    let snippetBody = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(snippet)) as? [String: Any])
    let savedSnippet: SSHSnippet = try await engine.call(["method": "sshSnippetSave", "snippet": snippetBody])
    #expect(savedSnippet.id == "espacio" && savedSnippet.host == nil)
    do {
        let _: SSHSnippet = try await engine.call(["method": "sshSnippetSave", "snippet": ["name": "x", "command": "printf '\u{1b}]52;c;AA\u{07}'"]])
        Issue.record("A snippet with escape sequences must be refused")
    } catch let error as EngineFailure { #expect(error.code == "invalid_snippet") }

    // Keys belong to the base: they answer with the plugin off too (checked below).
    let deleted: Bool = try await engine.call(["method": "sshDeleteHost", "id": savedInner.id])
    #expect(deleted)
    _ = try await engine.call(["method": "pluginSetEnabled", "id": "ssh-terminal", "enabled": false], as: [ToolInfo].self)
    let keys: [SSHKey] = try await engine.call(["method": "sshKeys"])
    #expect(keys.allSatisfy { !$0.fingerprint.isEmpty })
    do {
        let _: SSHOverview = try await engine.call(["method": "sshHosts"])
        Issue.record("A disabled plugin must not answer")
    } catch let error as EngineFailure {
        #expect(error.code == "plugin_disabled")
        #expect(error.errorDescription == L("error.plugin_disabled"))
    }
}
