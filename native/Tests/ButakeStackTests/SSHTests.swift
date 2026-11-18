import Foundation
import Testing
@testable import ButakeStack

private let hosts = [
    SSHHost(id: "a", name: "A", group: "AWS", tags: ["prod", "aws"], host: "a.ejemplo.cl", user: "u"),
    SSHHost(id: "b", name: "B", group: "AWS", tags: ["Prod"], host: "b.ejemplo.cl", user: "u"),
    SSHHost(id: "c", name: "C", group: "Casa", tags: [], host: "c.ejemplo.cl", user: "u"),
    SSHHost(id: "d", name: "D", group: "", tags: ["qa"], host: "d.ejemplo.cl", user: "u"),
]

/// Renaming a group moves only its hosts; to an existing name it merges; deleting sends them to
/// «Sin grupo» and «Sin grupo» itself can't be renamed.
@Test func groupsAreRenamedMergedAndDeleted() {
    let renamed = SSHHost.renaming(group: "AWS", to: "  Nube  ", in: hosts)
    #expect(renamed.map(\.id) == ["a", "b"] && renamed.allSatisfy { $0.group == "Nube" })
    #expect(SSHHost.renaming(group: "AWS", to: "Casa", in: hosts).allSatisfy { $0.group == "Casa" })
    #expect(SSHHost.renaming(group: "AWS", to: "", in: hosts).allSatisfy { $0.group.isEmpty })
    #expect(SSHHost.renaming(group: "", to: "Otro", in: hosts).isEmpty)
    #expect(SSHHost.renaming(group: "AWS", to: "AWS", in: hosts).isEmpty)
    #expect(SSHHost.cleanGroup(String(repeating: "x", count: 80)).count == 60)
}

/// Tags match ignoring case, like the engine; renaming onto another tag merges them without repeats.
@Test func tagsAreRenamedMergedAndDeleted() {
    #expect(hosts[1].has(tag: "PROD") && !hosts[2].has(tag: "prod"))
    let renamed = SSHHost.renaming(tag: "prod", to: "producción", in: hosts)
    #expect(renamed.map(\.id) == ["a", "b"])
    #expect(renamed[0].tags == ["producción", "aws"] && renamed[1].tags == ["producción"])
    let merged = SSHHost.renaming(tag: "prod", to: "aws", in: hosts)
    #expect(merged[0].tags == ["aws"])
    #expect(SSHHost.removing(tag: "PROD", in: hosts).allSatisfy { !$0.has(tag: "prod") })
    #expect(SSHHost.cleanTags([" a ", "A", "b,c", "", String(repeating: "t", count: 40)]) == ["a", "b c", String(repeating: "t", count: 30)])
    #expect(SSHHost.cleanTags((1...20).map { "t\($0)" }).count == 12)
}

/// ⌃Tab goes through the host's page and every tab, and comes back to the start.
@MainActor @Test func tabsCycleThroughTheHostPage() {
    let workspace = SSHWorkspace()
    let first = WorkspaceTab(session: TerminalSession(kind: .local(LocalConsoles.launch(.shell, directory: NSHomeDirectory())), title: "1"))
    let second = WorkspaceTab(session: TerminalSession(kind: .ssh("a"), title: "2"))
    workspace.tabs = [first, second]
    workspace.selected = nil
    workspace.cycle(1)
    #expect(workspace.selected == first.id)
    workspace.cycle(1)
    #expect(workspace.selected == second.id && second.hostID == "a" && first.hostID == nil)
    workspace.cycle(1)
    #expect(workspace.selected == nil)
    workspace.cycle(-1)
    #expect(workspace.selected == second.id)
    // A tab without a running process closes at once.
    workspace.requestClose(second)
    #expect(workspace.closing == nil && workspace.tabs.count == 1)
}

/// Every literal text of the SSH terminal and Ajustes › Claves SSH has its Spanish text, and so does
/// every key the views compose at run time.
@MainActor @Test func sshTextsExist() throws {
    let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Sources/ButakeStack")
    // The Terminal and the SSH keys of the base.
    let files = try ["Tools/Terminal", "SSHKeys"].flatMap { folder in
        try #require(FileManager.default.enumerator(at: sources.appendingPathComponent(folder), includingPropertiesForKeys: nil)?.compactMap { $0 as? URL })
    }
    let pattern = try Regex(#"L\("([A-Za-z0-9_.\-]+)"\)"#)
    var keys: Set<String> = []
    for file in files where file.pathExtension == "swift" {
        let source = try String(contentsOf: file, encoding: .utf8)
        for match in source.matches(of: pattern) { if let key = match.output[1].substring { keys.insert(String(key)) } }
    }
    #expect(keys.count > 150)
    for state in ["unchecked", "known", "unknown", "changed", "unreachable"] {
        keys.formUnion(["ssh.hostState.\(state)", "ssh.hostState.\(state).detail"])
    }
    for kind in ["local", "remote", "dynamic"] { keys.formUnion(["ssh.forward.kind.\(kind)", "ssh.forward.help.\(kind)"]) }
    for auth in ["agent", "stack", "file"] { keys.insert("ssh.authHelp.\(auth)") }
    // The warnings of the configuration import (engine/src/ssh/config.rs).
    for warning in ["forward_bind_loopback", "forward_skipped", "identity_unusable", "identity_extra", "jump_multi_hop", "port_invalid", "proxy_command_ignored"] {
        keys.insert("ssh.config.warning.\(warning)")
    }
    // Chosen with a condition: L(flag ? "a" : "b").
    keys.formUnion(["ssh.groups.delete", "ssh.groups.deleteTag", "ssh.groups.deleteEllipsis", "ssh.groups.deleteTagEllipsis",
                    "ssh.groups.mergeNote", "ssh.groups.mergeTagNote", "ssh.groups.merge", "ssh.groups.rename",
                    "ssh.tabs.closeDetail", "ssh.tabs.closeTransfersDetail", "ssh.authFooter", "ssh.authFooterFile", "ssh.authFooterAgent",
                    "ssh.hostCount", "ssh.groups.deleteDetail", "ssh.groups.deleteTagDetail",
                    "ssh.local.open", "ssh.connect", "ssh.tabs.new", "ssh.local.openHelp", "ssh.connectHelp",
                    "ssh.local.reopen", "ssh.terminal.reconnect", "ssh.hosts.section", "ssh.noGroup"])
    // The programs of «Este Mac»: their names and what they are.
    for program in LocalConsoles.assistants { keys.formUnion(["tool.\(program)", "toolDetail.\(program)"]) }
    let missing = keys.filter { localized($0) == nil }.sorted()
    #expect(missing.isEmpty, "Missing texts: \(missing.joined(separator: ", "))")
    #expect(String(format: L("ssh.hostCount"), 1) == "1 host" && String(format: L("ssh.hostCount"), 3) == "3 hosts")
}
