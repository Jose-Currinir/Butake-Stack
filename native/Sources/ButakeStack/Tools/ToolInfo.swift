import AppKit
import Foundation

/// A tool of the catalog (see docs/herramientas.md): a part of the app the user turns on or off
/// in Ajustes › Herramientas; its data is only deleted when asked.
struct ToolInfo: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var installed: Bool
    var enabled: Bool
    var hasData: Bool

    var title: String { L("plugin.\(id).title") }
    var summary: String { L("plugin.\(id).summary") }
    var tech: Tech { .of(id) }
    /// Where its data lives, under Stack's folder (nil when it keeps none).
    var dataPath: String? {
        switch id {
        case "database-client": "config/connections.json"
        case "ssh-terminal": "config/ssh/hosts.json"
        case "vault": "vault"
        case "mail": "mail"
        case "git": "config/git"
        default: nil
        }
    }
    /// The vault's keys and files are only deleted from inside the vault.
    var canDeleteData: Bool { hasData && id != "vault" }
    @MainActor func revealData() {
        guard let dataPath else { return }
        let url = URL(fileURLWithPath: Folder.base + "/" + dataPath)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
    /// The page a tool adds.
    var route: Route { .tool(id) }
}

extension StackStore {
    /// Before the catalog is read the database client and the vault count as on (they start on).
    func pluginEnabled(_ id: String) -> Bool {
        guard let plugin = plugins.first(where: { $0.id == id }) else { return !pluginsLoaded && ["database-client", "vault"].contains(id) }
        return plugin.enabled
    }
    var enabledPlugins: [ToolInfo] { plugins.filter(\.enabled) }

    func loadPlugins() async {
        if let list: [ToolInfo] = try? await call(["method": "pluginCatalog"]) {
            plugins = list
            pluginsLoaded = true
        }
    }
    func setPlugin(_ plugin: ToolInfo, enabled: Bool) async {
        await run(enabled ? L("plugins.enabling") : L("plugins.disabling")) {
            self.plugins = try await self.call(["method": "pluginSetEnabled", "id": plugin.id, "enabled": enabled])
            if !enabled, self.route == plugin.route { self.route = .home }
        }
        if plugin.id == "mail" || plugin.id == "dumps" {
            await loadPlugins()
            await refreshStatus()
        }
        // Git: off, nothing keeps watching its folders; on, the offer to bring the former app's list.
        if plugin.id == "git" {
            if pluginEnabled("git") { GitMigration.shared.offerAfterActivation(in: .settings) } else { GitTool.shared.suspend() }
        }
    }
    func removePlugin(_ plugin: ToolInfo, deleteData: Bool) async {
        await run(L("plugins.removing")) {
            self.plugins = try await self.call(["method": "pluginRemove", "id": plugin.id, "deleteData": deleteData, "confirmed": true])
            if self.route == plugin.route { self.route = .home }
            if plugin.id == "mail" || plugin.id == "dumps" { await self.refreshStatus() }
            if plugin.id == "git" { GitTool.shared.suspend() }
            if deleteData, plugin.id == "database-client" {
                for connection in DatabaseClient.shared.connections where !connection.builtin { DatabaseVault.delete(connection.id) }
            }
            self.notify(String(format: L("plugins.removed"), plugin.title))
        }
    }
}
