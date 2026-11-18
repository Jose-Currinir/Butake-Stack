import AppKit
import SwiftUI

extension StackStore {
    // MARK: Setup: what Stack needs on a new Mac, asked for and installed one by one
    func refreshDevTools(refresh: Bool = false) async {
        if let tools: [String: DevToolStatus] = try? await call(["method": "devTools"]) { devTools = tools }
        if let updates: DevUpdates = try? await call(["method": "devToolUpdates", "refresh": refresh]) { devUpdates = updates }
        if pythonLines.isEmpty, let lines: [PythonLine] = try? await call(["method": "pythonVersions"]) { pythonLines = lines }
    }
    /// Installs or updates a utility from its official source (the app asked first), followed
    /// step by step by its sheet (`InstallMonitor`): it throws instead of showing an alert, and
    /// cancelling its task stops the engine and what it started. `acceptLicenses`: the user
    /// accepted the Android SDK's in the sheet.
    func installDevToolFollowed(_ tool: String, shellPath: Bool, acceptLicenses: Bool = false) async throws {
        defer { Task { await self.refreshDevTools(refresh: true) } }
        let _: JSONValue = try await stoppableCall(["method": "installDevTool", "tool": tool, "version": "", "shellPath": shellPath,
                                                     "acceptLicenses": acceptLicenses, "confirmed": true])
    }
    /// Removes what Stack installed of a utility (the app asked first); its settings stay.
    func removeDevTool(_ tool: String) async {
        let title = L("tool.\(tool)")
        await run(String(format: L("utilities.removing"), title)) {
            let _: JSONValue = try await self.call(["method": "removeDevTool", "tool": tool, "confirmed": true])
            self.notify(String(format: L("utilities.removed"), title))
        }
        await refreshDevTools()
    }
    var phpReady: Bool { phpRuntimes.contains(where: \.verified) }
    var caddyReady: Bool { !(installedTools["caddy"] ?? []).isEmpty }
    var agentReady: Bool { agent?.loaded == true }
    /// What must exist for sites to be served at all.
    /// Ready to serve sites: Caddy and the agent; PHP only when the user works with Laravel or PHP.
    var setupComplete: Bool {
        #if DEBUG
        if QAHooks.simulatesStack { return true }
        #endif
        return caddyReady && agentReady && (!WorkProfile.chosen.contains("laravel") || phpReady) && (localTrust?.ready ?? true)
    }
    func refreshAppleTools() async {
        appleTools = await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select"); process.arguments = ["-p"]
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return false }
            process.waitUntilExit()
            return process.terminationStatus == 0
        }.value
    }
    func installAppleTools() {
        _ = try? Process.run(URL(fileURLWithPath: "/usr/bin/xcode-select"), arguments: ["--install"])
    }
    /// Quiet on failure (offline): the PHP step says so instead of an alert.
    /// `refresh`: ask the source again (reload button); otherwise the engine's local copy answers.
    func loadPhpCatalog(refresh: Bool = false) async {
        let job = beginJob(L("busy.catalog"))
        defer { endJob(job) }
        do {
            phpCatalog = try await call(["method": "phpCatalog", "refresh": refresh])
            phpCatalogFailed = false
            catalogErrors["php"] = nil
        } catch {
            phpCatalogFailed = true
            catalogErrors["php"] = EngineFailure.message(error)
        }
    }
    /// A PHP build from the catalog, followed by the picker (`InstallMonitor`) and stoppable.
    func downloadPhpFollowed(_ version: String) async throws {
        defer { Task { await self.refreshRuntimes(); await self.reloadStack() } }
        let _: PhpManifestSummary = try await stoppableCall(["method": "downloadPhp", "version": version, "confirmed": true])
    }
    /// QA and screenshots only (debug builds): open the window at launch.
    static var qaWindow: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["BUTAKE_QA_WINDOW"] != nil
        #else
        false
        #endif
    }
    /// At launch: on the first one, and later while something essential is missing, the window opens
    /// on the setup assistant.
    func checkSetupAtLaunch() async {
        await bootstrap()
        // A separate data folder (QA) must not open the installed app through the URL scheme.
        guard ProcessInfo.processInfo.environment["BUTAKE_STACK_HOME"] == nil else { return }
        if !UserDefaults.standard.bool(forKey: "welcome.seen") || !setupComplete { NSWorkspace.shared.open(URL(string: "butakestack://setup")!) }
    }
}
