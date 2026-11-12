import AppKit
import SwiftUI

/// Sidebar destinations, structured like a settings window: each site, each service and each
/// language has its own page.
enum Route: Hashable {
    case home
    case site(String)
    case service(String)
    case language(String)
    case general

    var title: String {
        switch self {
        case .home: L("route.home")
        case .site: L("route.sites")
        case .service(let name): Tech.of(name).title
        case .language(let name): Tech.of(name).title
        case .general: L("route.general")
        }
    }
    /// Service types, like a catalog: each groups the engines of that kind.
    static let services = ["database", "cache", "broadcasting", "search", "storage", "web"]
    static func engines(in category: String) -> [String] {
        switch category {
        case "database": ["mysql", "postgres", "mongodb"]
        case "cache": ["redis", "valkey"]
        case "search": ["meilisearch", "typesense"]
        case "storage": ["rustfs"]
        default: []
        }
    }
    static let allEngines = services.flatMap { engines(in: $0) }
    /// Engines that cannot be offered with a one-click install, with the honest reason.
    static func unavailable(in category: String) -> [(String, String)] {
        category == "database" ? [("MariaDB", L("unavailable.mariadb"))] : []
    }
    static func category(of engine: String) -> String {
        services.first { engines(in: $0).contains(engine) } ?? "web"
    }
    static let languages = ["php", "node"]
}

/// Everything the window shows. All engine calls go through `StackEngine` (JSON over stdin/stdout).
@MainActor @Observable final class StackStore {
    static let shared = StackStore()
    let engine = StackEngine()

    var route: Route = .home
    var selectedSite: Project.ID?
    var projects: [Project] = []
    var status: StackStatus?
    var daemonRunning = false
    var agent: AgentStatus?
    var config: StackConfig?
    var phpRuntimes: [PhpRuntimeSummary] = []
    var installedTools: [String: [ToolManifest]] = [:]
    var availableTools: [String: [AvailableVersion]] = [:]
    var ports: PortOwners?
    var recipes: [EngineRecipe] = []
    var lifecycles: [String: [Cycle]] = [:]
    func loadLifecycle(_ tool: String) async {
        if lifecycles[tool] == nil, let cycles: [Cycle] = try? await call(["method": "lifecycle", "tool": tool]) { lifecycles[tool] = cycles }
    }
    func cycle(_ tool: String, for version: String) -> Cycle? { lifecycles[tool]?.first { $0.matches(version) } }
    func enginePort(_ id: String) -> Int? { recipes.first { $0.id == id }?.port }
    var busy: String?
    var errorMessage: String?
    var toast: String?
    var newSite: Detection?
    var showPalette = false
    var showNewProject = false
    /// Last HTTP status of each site (0 = no answer).
    var siteHealth: [String: Int] = [:]
    func refreshHealth() async { if let value: [String: Int] = try? await call(["method": "siteHealth"]) { siteHealth = value } }
    var logs: [String: [String]] = [:]

    // MARK: Git (read-only): branch, pending changes, worktrees and branch switches
    var git: [String: GitInfo] = [:]
    var worktrees: [String: [Worktree]] = [:]
    /// What the last branch switch of a site changed, until the user deals with it.
    var branchNotices: [String: BranchChanges] = [:]
    var runningTask: String?
    func refreshGit() async {
        guard let value: [String: GitInfo] = try? await call(["method": "gitStatus"]) else { return }
        git = value
        let defaults = UserDefaults.standard
        for (id, info) in value where !info.head.isEmpty {
            let key = "git.head.\(id)"
            let seen = defaults.string(forKey: key)
            defaults.set(info.head, forKey: key)
            guard let seen, seen != info.head else { continue }
            if let changes: BranchChanges = try? await call(["method": "branchChanges", "id": id, "from": seen, "to": info.head]), changes.any {
                branchNotices[id] = changes
            }
        }
    }
    func loadWorktrees(_ id: String) async {
        worktrees[id] = (try? await call(["method": "worktrees", "id": id])) ?? []
    }
    func serveWorktree(_ project: Project, _ worktree: Worktree) async {
        await run(L("busy.saving"), refresh: true) {
            let site: Project = try await self.call(["method": "addWorktreeSite", "id": project.id, "path": worktree.path])
            self.notify(String(format: L("worktree.served"), site.title))
        }
        await loadWorktrees(project.id)
    }
    /// Composer, npm or migrations for a site, with the stack's own PHP and Node.
    func runSiteTask(_ project: Project, _ task: String) async {
        runningTask = "\(project.id).\(task)"
        defer { runningTask = nil }
        await run(L("task.\(task).busy")) {
            let _: Bool = try await self.call(["method": "siteTask", "id": project.id, "task": task])
            self.notify(L("task.\(task).done"))
        }
    }
    func stepLog(_ name: String) async -> [String] { (try? await call(["method": "stepLog", "name": name])) ?? [] }
    /// A service type has something installed (or, for broadcasting, a site that runs Reverb).
    func categoryInstalled(_ category: String) -> Bool {
        switch category {
        case "web": true
        case "broadcasting": projects.contains { $0.processes.contains { $0.args.contains("reverb:start") } }
        default: Route.engines(in: category).contains { engineVersion($0) != nil }
        }
    }

    // MARK: Setup: what Stack needs on a new Mac, asked for and installed one by one
    var showSetup = false
    var phpCatalog: [PhpCatalogEntry] = []
    /// Apple's command line tools (Git, compiler): needed for new projects and engines built from source.
    var appleTools = true
    var phpReady: Bool { phpRuntimes.contains(where: \.verified) }
    var caddyReady: Bool { !(installedTools["caddy"] ?? []).isEmpty }
    var agentReady: Bool { agent?.loaded == true }
    /// What must exist for sites to be served at all.
    var setupComplete: Bool { phpReady && caddyReady && agentReady }
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
    var phpCatalogFailed = false
    /// Quiet on failure (offline): the PHP step says so instead of an alert.
    func loadPhpCatalog() async {
        busy = L("busy.catalog"); defer { busy = nil }
        if let value: [PhpCatalogEntry] = try? await call(["method": "phpCatalog"]) { phpCatalog = value; phpCatalogFailed = false } else { phpCatalogFailed = true }
    }
    func downloadPhp(_ version: String) async {
        await run(L("busy.installing")) {
            let _: PhpManifestSummary = try await self.call(["method": "downloadPhp", "version": version, "confirmed": true])
            self.notify(L("toast.installed"))
        }
        await refreshRuntimes(); await reloadStack()
    }
    /// At launch: when something essential is missing, the window opens on the setup sheet.
    func checkSetupAtLaunch() async {
        await refresh(); await refreshRuntimes(); await refreshAppleTools()
        if !setupComplete { NSWorkspace.shared.open(URL(string: "butakestack://setup")!) }
    }

    // MARK: Links from other apps (butakestack://site/<id>, butakestack://open?path=…)
    func handle(_ url: URL) {
        guard url.scheme == "butakestack" else { return }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        switch url.host {
        case "setup":
            showSetup = true
        case "site":
            let id = url.lastPathComponent
            if projects.contains(where: { $0.id == id }) { openSite(id) }
        case "open":
            guard let path = components?.queryItems?.first(where: { $0.name == "path" })?.value, path.hasPrefix("/") else { return }
            let standard = URL(fileURLWithPath: path).standardizedFileURL.path
            if let project = projects.first(where: { $0.path == standard }) { openSite(project.id) }
            else { Task { await detect(standard) } }
        default: route = .home
        }
    }

    var selectedProject: Project? { projects.first { $0.id == selectedSite } }
    func openSite(_ id: String) { selectedSite = id; route = .site(id) }
    /// Creates a Laravel project and opens its page; returns false on failure.
    func createLaravel(name: String, parent: String, kit: String, testing: String, database: String, git: Bool) async -> Bool {
        var ok = false
        await run(L("new.creating"), refresh: true) {
            let project: Project = try await self.call(["method": "createLaravel", "name": name, "parent": parent, "kit": kit, "testing": testing, "database": database, "git": git])
            self.openSite(project.id)
            ok = true
        }
        if ok { notify(L("new.done")) }
        return ok
    }
    /// Turns a site on (served, processes running) or off.
    func setSite(_ project: Project, enabled: Bool) async {
        await run(enabled ? L("busy.start") : L("busy.stop"), refresh: true) {
            let _: Project = try await self.call(["method": "setSiteEnabled", "id": project.id, "enabled": enabled])
        }
        try? await Task.sleep(for: .seconds(2))
        await refreshHealth()
    }

    func process(_ id: String) -> ProcessEntry? { status?.processes.first { $0.id == id } }
    func phase(_ id: String) -> ProcessPhase { process(id).map { ProcessPhase($0.status.state) } ?? .stopped }
    var stackProcesses: [ProcessEntry] { status?.processes.filter { $0.id.hasPrefix("stack.") } ?? [] }
    var engineCount: Int { stackProcesses.count }
    var runningEngines: Int { stackProcesses.filter { $0.status.state == "running" }.count }
    var runningSiteProcesses: Int { status?.processes.filter { !$0.id.hasPrefix("stack.") && $0.status.state == "running" }.count ?? 0 }

    /// One state per site: served and every auto-start process up (running), something failed
    /// (crashed), still coming up (starting) or not served (stopped).
    func sitePhase(_ project: Project) -> ProcessPhase {
        guard project.enabled, daemonRunning, phase("stack.caddy") == .running else { return .stopped }
        // The site itself must answer: no response or a server error is a problem.
        if let code = siteHealth[project.id], code == 0 || code >= 500 { return .crashed }
        let phases = project.processes.filter(\.autostart).map { phase("\(project.id).\($0.name)") }
        if phases.contains(.crashed) { return .crashed }
        if phases.contains(where: { $0 != .running }) { return .starting }
        return .running
    }
    /// Aggregate state of a service type: running when every enabled engine runs.
    func categoryPhase(_ category: String) -> ProcessPhase {
        guard daemonRunning else { return .stopped }
        if category == "web" { return phase("stack.caddy") }
        if category == "broadcasting" {
            let ids = projects.flatMap { p in p.processes.filter { $0.args.contains("reverb:start") }.map { "\(p.id).\($0.name)" } }
            if ids.isEmpty { return .stopped }
            return ids.contains { phase($0) == .running } ? .running : .stopped
        }
        let phases = Route.engines(in: category).filter(engineEnabled).map { phase("stack.\($0)") }
        if phases.isEmpty { return .stopped }
        if phases.contains(.crashed) { return .crashed }
        return phases.allSatisfy { $0 == .running } ? .running : .starting
    }
    func runningProcesses(_ project: Project) -> Int {
        project.processes.filter { phase("\(project.id).\($0.name)") == .running }.count
    }
    var globalPhp: String { config?.versions["php"] ?? "8.2" }

    /// Overall light for the status bar and the menu bar: green, amber (something stopped or crashed) or red (no daemon).
    var health: Color {
        guard daemonRunning, let status else { return .red }
        let crashed = status.processes.contains { $0.status.state == "crashed" }
        let web = status.listeners["http"]?.mode != "unavailable"
        return crashed || !web ? .orange : .green
    }

    func call<T: Decodable & Sendable>(_ parameters: [String: Any], as type: T.Type = T.self) async throws -> T {
        let data = try JSONSerialization.data(withJSONObject: parameters)
        return try await engine.call(json: data, as: type)
    }

    func refresh() async {
        do { projects = try await call(["method": "listProjects"]) } catch { report(error) }
        config = try? await call(["method": "stackConfig"])
        await refreshStatus()
        agent = try? await call(["method": "agentStatus"])
        if selectedProject == nil { selectedSite = projects.first?.id }
    }
    func refreshStatus() async {
        if let value: StackStatus = try? await call(["method": "stackStatus"]) {
            status = value; daemonRunning = true
        } else {
            status = nil; daemonRunning = false
        }
    }
    func refreshRuntimes() async {
        phpRuntimes = (try? await call(["method": "listPhpRuntimes"])) ?? []
        recipes = (try? await call(["method": "engineRecipes"])) ?? recipes
        for tool in ["node", "caddy"] + Route.allEngines {
            installedTools[tool] = (try? await call(["method": "installedTools", "tool": tool])) ?? []
        }
    }
    func loadAvailable(_ tool: String) async {
        await run(L("busy.catalog")) {
            self.availableTools[tool] = try await self.call(["method": "availableTools", "tool": tool])
        }
    }
    func refreshPorts() async {
        ports = try? await call(["method": "portStatus"])
        agent = try? await call(["method": "agentStatus"])
    }

    /// Runs an engine action with a busy label, then refreshes; errors become a readable alert.
    func run(_ label: String, refresh: Bool = false, _ work: @escaping @MainActor () async throws -> Void) async {
        busy = label
        defer { busy = nil }
        do {
            try await work()
            if refresh { await self.refresh() }
        } catch { report(error) }
    }
    func report(_ error: Error) {
        if let failure = error as? EngineFailure { errorMessage = failure.errorDescription } else { errorMessage = L("engine.requestFailed") }
    }
    func notify(_ text: String) {
        withAnimation(.snappy) { toast = text }
        Task { try? await Task.sleep(for: .seconds(2.5)); withAnimation(.snappy) { if toast == text { toast = nil } } }
    }

    // MARK: Engines (MySQL, Redis) run directly by the stack
    func engineEnabled(_ name: String) -> Bool { config?.engines?[name]?.enabled == true }
    func engineVersion(_ name: String) -> String? { installedTools[name]?.first?.version }
    func setEngine(_ name: String, enabled: Bool) async {
        await run(enabled ? L("busy.start") : L("busy.stop")) {
            self.config = try await self.call(["method": "setEngine", "engine": name, "enabled": enabled])
        }
        try? await Task.sleep(for: .milliseconds(900))
        await refreshStatus()
    }

    /// Keeps the menu bar panel current even with no window open.
    private var polling: Task<Void, Never>?
    func startPolling() {
        guard polling == nil else { return }
        polling = Task { [weak self] in
            await self?.refresh()
            await self?.refreshRuntimes()
            if let projects = self?.projects { SitePreviews.shared.refreshAll(projects) }
            var tick = 0
            while !Task.isCancelled {
                if tick % 5 == 0 { await self?.refreshHealth(); await self?.refreshGit() }
                tick += 1
                try? await Task.sleep(for: .seconds(3))
                await self?.refreshStatus()
            }
        }
    }

    // MARK: Daemon and processes
    func startDaemon() async {
        await run(L("busy.starting"), refresh: true) { let _: StackStatus = try await self.call(["method": "startDaemon"]) }
    }
    func reloadStack() async {
        await run(L("busy.reloading")) { let _: Bool = try await self.call(["method": "reloadStack"]) }
        try? await Task.sleep(for: .milliseconds(800))
        await refreshStatus()
    }
    func processAction(_ id: String, _ action: String) async {
        await run(L("busy.\(action)")) { let _: Bool = try await self.call(["method": "processAction", "id": id, "action": action]) }
        try? await Task.sleep(for: .milliseconds(600))
        await refreshStatus()
    }
    func loadLogs(_ id: String) async {
        // Only a real change re-renders the log.
        if let lines: [String] = try? await call(["method": "processLogs", "id": id]), logs[id] != lines { logs[id] = lines }
    }

    // MARK: Sites
    func save(_ project: Project) async -> Bool {
        var ok = false
        await run(L("busy.saving"), refresh: true) {
            let data = try JSONEncoder().encode(project)
            let object = try JSONSerialization.jsonObject(with: data)
            let saved: Project = try await self.call(["method": "saveProject", "project": object])
            self.openSite(saved.id)
            ok = true
        }
        if ok { notify(L("toast.saved")) }
        return ok
    }
    func delete(_ project: Project) async {
        await run(L("busy.saving"), refresh: true) {
            let _: Bool = try await self.call(["method": "deleteProject", "id": project.id])
            self.selectedSite = nil
            self.route = .home
        }
    }
    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.prompt = L("site.chooseFolder")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await detect(url.path) }
    }
    func detect(_ path: String) async {
        await run(L("busy.detecting")) { self.newSite = try await self.call(["method": "detect", "path": path]) }
    }
    func setGlobalPhp(_ series: String) async {
        guard var config else { return }
        config.versions["php"] = series
        await run(L("busy.saving"), refresh: true) {
            let object = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(config))
            let _: StackConfig = try await self.call(["method": "stackConfig", "config": object])
            let _: Bool? = try? await self.call(["method": "reloadStack"])
        }
    }

    // MARK: Runtimes
    func installTool(_ tool: String, _ version: String) async {
        await run(L("busy.installing"), refresh: false) {
            let _: ToolManifest = try await self.call(["method": "installTool", "tool": tool, "version": version, "confirmed": true])
            self.notify(L("toast.installed"))
        }
        await refreshRuntimes(); await refreshStatus()
    }
    func removeTool(_ tool: String, _ version: String) async {
        await run(L("busy.removing")) {
            let _: Bool = try await self.call(["method": "removeTool", "tool": tool, "version": version, "confirmed": true])
        }
        await refreshRuntimes(); await refreshStatus()
    }
    func installPhpPackage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.gzip]
        panel.prompt = L("runtimes.installPackage")
        panel.message = L("runtimes.packageHelp")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            await run(L("busy.installing")) {
                let _: PhpManifestSummary = try await self.call(["method": "installPhpPackage", "path": url.path, "confirmed": true])
                self.notify(L("toast.installed"))
            }
            await refreshRuntimes(); await reloadStack()
        }
    }

    // MARK: Session agent (ports 53/80/443)
    func installAgent() async {
        await run(L("busy.agent")) { let _: [String: Bool] = try await self.call(["method": "installAgent", "confirmed": true]) }
        try? await Task.sleep(for: .seconds(2))
        await refresh(); await refreshPorts()
    }
    func uninstallAgent() async {
        await run(L("busy.agent")) { let _: [String: Bool] = try await self.call(["method": "uninstallAgent", "confirmed": true]) }
        await refresh(); await refreshPorts()
    }
}
