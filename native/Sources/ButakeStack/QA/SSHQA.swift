#if DEBUG
import AppKit
import SwiftUI

/// QA hooks of the SSH terminal (BUTAKE_QA_SSH*), apart from QAHooks.swift so it stays short.
extension QAHooks {
    /// A ~/.ssh/config to import from (BUTAKE_QA_SSH_CONFIG).
    static var sshConfigPath: String? { value("BUTAKE_QA_SSH_CONFIG") }
    /// Opens the key generator (BUTAKE_QA_SSH_KEYS=generate).
    static var sshKeysGenerate: Bool { value("BUTAKE_QA_SSH_KEYS") == "generate" }

    /// The host list's search: BUTAKE_QA_SSH_FIND=<text>[#tag,tag] (text and tag tokens).
    static var sshSearch: (text: String, tags: [String])? {
        guard let value = value("BUTAKE_QA_SSH_FIND") else { return nil }
        let parts = value.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        return (parts[0], parts.count > 1 ? parts[1].split(separator: ",").map(String.init) : [])
    }

    /// BUTAKE_QA_SSH=<host id> selects a host; BUTAKE_QA_SSH_SHEET opens a sheet (host, new,
    /// trust, import, snippets, passphrase, groups, deleteHost); BUTAKE_QA_SSH_INSPECTOR=0|1 hides
    /// or shows the inspector; BUTAKE_QA_SSH_OPEN opens tabs: "connect", "local", "split", "sftp",
    /// "search", "snippet:<id>" (inserts it, never runs it), "download" (BUTAKE_QA_SFTP_FILE into
    /// BUTAKE_QA_SFTP_DOWNLOAD), "hosts" (back to the host's page), "close" (asks to close the tab);
    /// BUTAKE_QA_SFTP_PATH is the folder the browser opens.
    static func ssh(terminal: SSHTerminal, workspace: SSHWorkspace, keyring: SSHKeyring) async {
        guard StackStore.qaWindow else { return }
        let env = Self.env
        if let id = env["BUTAKE_QA_SSH"] { terminal.selection = id }
        workspace.inspector = env["BUTAKE_QA_SSH_INSPECTOR"] == "1"
        if let sheet = env["BUTAKE_QA_SSH_SHEET"] {
            switch sheet {
            case "host": terminal.editing = terminal.host(terminal.selection) ?? SSHHost()
            case "new": terminal.editing = SSHHost()
            case "import": workspace.sheet = .importConfig
            case "snippets": workspace.sheet = .snippets
            case "groups": workspace.sheet = .groups
            case "deleteHost": terminal.deleting = terminal.host(terminal.selection)
            case "passphrase": keyring.prompt = .init(keyID: "qa", name: "QA", resume: { _, _ in })
            case "trust":
                if let host = terminal.host(terminal.selection), let state = await terminal.check(host) {
                    terminal.trustRequest = .init(host: terminal.host(state.host) ?? host, fingerprints: state.fingerprints, then: .none, target: host)
                }
            default: break
            }
        }
        guard let plan = env["BUTAKE_QA_SSH_OPEN"] else { return }
        for step in plan.split(separator: ",").map(String.init) {
            let host = terminal.host(terminal.selection)
            switch step {
            case "connect": if let host { await terminal.open(host) }
            case "local": workspace.openLocal()
            case "split": if let tab = workspace.current { workspace.split(tab, axis: .horizontal) }
            case "splitDown": if let tab = workspace.current { workspace.split(tab, axis: .vertical) }
            case "sftp":
                if let host { await terminal.openFiles(host, path: env["BUTAKE_QA_SFTP_PATH"] ?? "") }
            case "download":
                // Downloads the first file of the listing into BUTAKE_QA_SFTP_DOWNLOAD (a temporary folder).
                if let browser = workspace.current?.browser, let folder = env["BUTAKE_QA_SFTP_DOWNLOAD"],
                   let entry = browser.entries.first(where: { $0.name == (env["BUTAKE_QA_SFTP_FILE"] ?? "") }) {
                    try? await browser.download(entry, to: URL(fileURLWithPath: folder), overwrite: true)
                }
            case "search":
                if let session = workspace.current?.focusedSession {
                    session.searchVisible = true
                    session.searchText = env["BUTAKE_QA_SSH_SEARCH"] ?? "ok"
                    session.find(next: false)
                }
            case "hosts": workspace.selected = nil
            case "close": if let tab = workspace.current { workspace.requestClose(tab) }
            default:
                if step.hasPrefix("snippet:"), let snippet = SSHSnippets.shared.list.first(where: { $0.id == step.dropFirst(8) }) {
                    workspace.current?.focusedSession?.insert(snippet.command, run: false)
                } else if step.hasPrefix("type:") {
                    // Types a harmless command and runs it (QA against the temporary sshd only).
                    workspace.current?.focusedSession?.insert(String(step.dropFirst(5)), run: true)
                } else if step.hasPrefix("wait:"), let seconds = Double(step.dropFirst(5)) {
                    try? await Task.sleep(for: .seconds(seconds))
                }
            }
            try? await Task.sleep(for: .milliseconds(1200))
        }
    }
}
#endif
