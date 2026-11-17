import AppKit
import SwiftUI

extension StackStore {
    // MARK: Links from other apps (butakestack://site/<id>, butakestack://open?path=…, tool, ssh, db, git)
    // Older links stay as aliases: general, plugins and service/web open Ajustes; vault and
    // service/mail|dumps|logs open the tool.
    func handle(_ url: URL) {
        guard url.scheme == "butakestack" else { return }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        switch url.host {
        // butakestack://welcome is an older alias of the same assistant.
        case "setup", "welcome":
            showSetup = true
        case "site":
            let id = url.lastPathComponent
            if projects.contains(where: { $0.id == id }) { openSite(id) }
        // butakestack://project/rename?id=<id>[&newId=<nuevo>]: the rename sheet filled in (P-41).
        case "project":
            handleProjectLink(url)
        case "open":
            guard let standard = Self.linkedFolder(components?.queryItems?.first(where: { $0.name == "path" })?.value) else { return }
            if let project = projects.first(where: { $0.path == standard }) { openSite(project.id) }
            else { Task { await detect(standard) } }
        // butakestack://tool/<id>, …/ssh/<host> and …/db/<connection>: they only show it; a link
        // never opens a session or connects by itself.
        case "tool":
            // butakestack://tool/logs?source=<proceso>|origin=<origen>: Registros already filtered.
            if url.lastPathComponent == "logs" { LogsBrowser.shared.open(components?.queryItems) }
            openTool(url.lastPathComponent)
        // butakestack://vault/import?path=<carpeta>[&path=…]: the import preview with those folders, for the
        // user to review and confirm; locked, it waits for the user to unlock (P-38).
        case "vault":
            openTool("vault")
            if url.path == "/import", pluginEnabled("vault") { VaultSession.shared.propose(components?.queryItems) }
        // butakestack://git/open?path=<repositorio>: the Git tool with that repository open.
        case "git":
            if let path = Self.linkedFolder(components?.queryItems?.first(where: { $0.name == "path" })?.value), pluginEnabled("git") {
                GitTool.shared.show(path)
            } else {
                openTool("git")
            }
        case "service":
            let name = url.lastPathComponent
            if name == "web" { SettingsRouter.shared.open(.network) }
            else if Route.services.contains(name) { route = .service(name) }
            else { openTool(name) }
        case "general":
            SettingsRouter.shared.open(.general)
        case "plugins":
            SettingsRouter.shared.open(.tools)
        case "ssh" where pluginEnabled("ssh-terminal"):
            route = .tool("ssh-terminal")
            SSHTerminal.shared.selection = url.lastPathComponent
        case "db" where pluginEnabled("database-client"):
            route = .tool("database-client")
            let id = url.lastPathComponent
            if DatabaseClient.shared.connection(id) != nil { DatabaseClient.shared.selection = DBSelection(connection: id) }
        default: route = .home
        }
    }

    /// The folder a link names: an absolute path, normalized, that exists and is a folder. Anything else is ignored.
    nonisolated static func linkedFolder(_ path: String?) -> String? {
        guard let path, path.hasPrefix("/"), !path.contains("\0") else { return nil }
        let standard = URL(fileURLWithPath: path).standardizedFileURL.path
        var isFolder: ObjCBool = false
        return FileManager.default.fileExists(atPath: standard, isDirectory: &isFolder) && isFolder.boolValue ? standard : nil
    }

    /// A tool's page; a tool that is off opens Ajustes › Herramientas with its row highlighted.
    func openTool(_ id: String) {
        if id == "logs" || pluginEnabled(id) { route = .tool(id) }
        else if plugins.contains(where: { $0.id == id }) { SettingsRouter.shared.open(.tools, tool: id) }
        else { route = .home }
    }
}
