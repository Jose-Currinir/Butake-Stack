import AppKit
import SwiftUI

extension StackStore {
    // MARK: Runtimes
    /// A version from the engine's catalog, followed by its picker (`InstallMonitor`): stoppable, and it throws.
    func installToolFollowed(_ tool: String, _ version: String) async throws {
        defer { Task { await self.refreshRuntimes(); await self.refreshStatus() } }
        let _: ToolManifest = try await stoppableCall(["method": "installTool", "tool": tool, "version": version, "confirmed": true])
    }
    /// Rebuilds an installed version in place (PostgreSQL without its extensions); the data stays,
    /// the running service restarts on the new build. Followed like an install.
    func reinstallToolFollowed(_ tool: String, _ version: String) async throws {
        defer { Task { await self.refreshRuntimes(); await self.refreshStatus() } }
        let _: ToolManifest = try await stoppableCall(["method": "installTool", "tool": tool, "version": version, "confirmed": true, "replace": true])
    }
    /// The installed PostgreSQL lacks its standard extensions (built before they were included).
    var postgresWithoutExtensions: Bool { installedTools["postgres"]?.first?.extensions == false }
    func removeTool(_ tool: String, _ version: String) async {
        await run(L("busy.removing")) {
            let _: Bool = try await self.call(["method": "removeTool", "tool": tool, "version": version, "confirmed": true])
        }
        await refreshRuntimes(); await refreshStatus()
    }
    /// A PHP package on this Mac (`php-<versión>-macos-arm64.tar.gz` beside its catalog.json).
    func choosePhpPackage() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.gzip]
        panel.prompt = L("runtimes.choosePackage")
        panel.message = L("runtimes.packageHelp")
        return panel.runModal() == .OK ? panel.url : nil
    }
    /// Installs it, followed by its sheet (`InstallMonitor`): checked against its catalog, then placed.
    func installPhpPackageFollowed(_ url: URL) async throws {
        defer { Task { await self.refreshRuntimes(); await self.reloadStack() } }
        let _: PhpManifestSummary = try await stoppableCall(["method": "installPhpPackage", "path": url.path, "confirmed": true])
    }
}
