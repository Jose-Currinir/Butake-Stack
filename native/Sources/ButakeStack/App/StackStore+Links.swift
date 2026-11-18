import AppKit
import SwiftUI

extension StackStore {
    // MARK: Links from other apps (butakestack://site/<id>, butakestack://open?path=…, tool, ssh, db, git)
    // The reading and its limits are `DeepLink.parse`; this only shows what it returns.
    // Older links stay as aliases: general, plugins and service/web open Ajustes; vault and
    // service/mail|dumps|logs open the tool.
    func handle(_ url: URL) {
        guard url.scheme == "butakestack" else { return }
        // A link that is not valid says why and changes nothing: it never falls back to Inicio.
        switch DeepLink.parse(url) {
        case .failure(let failure):
            errorMessage = failure.message
        case .success(let target):
            show(target)
        }
    }

    private func show(_ target: DeepLink.Target) {
        switch target {
        case .home:
            route = .home
        case .setup:
            showSetup = true
        case .site(let id):
            if projects.contains(where: { $0.id == id }) { openSite(id) } else { errorMessage = String(format: L("error.link.noProject"), id) }
        // butakestack://project/rename?id=<id>[&newId=<nuevo>]: the rename sheet filled in (P-41).
        case .renameProject(let id, let newId):
            guard let project = projects.first(where: { $0.id == id }) else { errorMessage = String(format: L("error.link.noProject"), id); return }
            openSite(project.id)
            renaming = RenameRequest(project: project, proposedId: newId.map(StackStore.slug))
        case .openFolder(let path):
            guard let standard = Self.linkedFolder(path) else { errorMessage = L("error.link.noFolder"); return }
            if let project = projects.first(where: { $0.path == standard }) { openSite(project.id) }
            else { Task { await detect(standard) } }
        // butakestack://tool/<id>, …/ssh/<host> and …/db/<connection>: they only show it; a link
        // never opens a session or connects by itself.
        case .tool(let id, let items):
            // butakestack://tool/logs?source=<proceso>|origin=<origen>: Registros already filtered.
            if id == "logs" { LogsBrowser.shared.open(items) }
            openTool(id)
        // butakestack://vault/import?path=<carpeta>[&path=…]: the import preview with those folders, for the
        // user to review and confirm; locked, it waits for the user to unlock (P-38).
        case .vault(let paths):
            openTool("vault")
            if let paths, pluginEnabled("vault") { VaultSession.shared.propose(paths) }
        // butakestack://git/open?path=<repositorio>: the Git tool with that repository open.
        case .git(let path):
            if let path, let folder = Self.linkedFolder(path), pluginEnabled("git") {
                GitTool.shared.show(folder)
            } else {
                openTool("git")
            }
        case .service(let name):
            if name == "web" { SettingsRouter.shared.open(.network) }
            else if Route.services.contains(name) { route = .service(name) }
            else { openTool(name) }
        case .settingsGeneral:
            SettingsRouter.shared.open(.general)
        case .settingsTools:
            SettingsRouter.shared.open(.tools)
        case .ssh(let host):
            guard pluginEnabled("ssh-terminal") else { return }
            route = .tool("ssh-terminal")
            SSHTerminal.shared.selection = host
        case .database(let id):
            guard pluginEnabled("database-client") else { return }
            route = .tool("database-client")
            if DatabaseClient.shared.connection(id) != nil { DatabaseClient.shared.selection = DBSelection(connection: id) }
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
        else { errorMessage = String(format: L("error.link.noTool"), String(id.prefix(40))) }
    }
}
