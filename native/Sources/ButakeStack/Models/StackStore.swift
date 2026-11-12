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
    static let languages = ["php", "node", "python", "java", "rust", "swift"]
}

/// Everything the window shows. All engine calls go through `StackEngine` (JSON over stdin/stdout).
@MainActor @Observable final class StackStore {
    static let shared = StackStore()
    let engine = StackEngine()

    var route: Route = .home
    var selectedSite: Project.ID?
    var projects: [Project] = []
    /// Sites whose folder isn't there (deleted, moved or on a disconnected drive).
    var missingSites: [MissingSite] = []
    /// Folders that group sites (sidebar and Home).
    var groups: [SiteGroup] = []
    /// Folder saves run one at a time and always save the latest state (see `updateGroups`).
    @ObservationIgnored var groupsSaving = false
    @ObservationIgnored var groupsDirty = false
    /// A folder being named (new or renamed); the sidebar shows the prompt.
    var groupNaming: GroupNaming?
    /// Current framework and generator versions (npm and Packagist), cached by the engine.
    var projectVersions: [String: String] = [:]
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
    /// A folder holding several projects, ready to import.
    var importScan: FolderScan?
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

    // MARK: Environments of each site's .env (secrets in the Keychain, never in the engine's store)
    var envs: [String: EnvState] = [:]
    var actor: String { NSUserName() }
    func loadEnvs(_ id: String) async {
        if let value: EnvState = try? await call(["method": "envList", "id": id]) { envs[id] = value }
    }
    func loadAllEnvs() async { for project in projects { await loadEnvs(project.id) } }
    func activeEnvironment(_ id: String) -> EnvEnvironment? { envs[id]?.site.activeEnvironment }
    func envAudit(_ id: String, env: String, action: String, key: String = "") async {
        let _: Bool? = try? await call(["method": "envAudit", "id": id, "env": env, "action": action, "key": key, "actor": actor])
    }
    /// Saves keys and non-secret values; secret values were already put in the Keychain.
    func saveEnvs(_ id: String, _ site: SiteEnvironments) async -> Bool {
        var ok = false
        await run(L("busy.saving")) {
            let object = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(site))
            let _: SiteEnvironments = try await self.call(["method": "envSave", "id": id, "site": object, "actor": self.actor])
            ok = true
        }
        await loadEnvs(id)
        return ok
    }
    func classify(_ keys: [String]) async -> [Bool] {
        (try? await call(["method": "envClassify", "keys": keys])) ?? keys.map { _ in true }
    }
    /// The site's current `.env` becomes "Local": secrets go to the Keychain, nothing is lost (R8).
    func importCurrentEnv(_ project: Project) async {
        guard let text = try? String(contentsOfFile: (project.path as NSString).appendingPathComponent(".env"), encoding: .utf8) else { return }
        let pairs = DotEnv.parse(text)
        let secret = await classify(pairs.map(\.0))
        var entries: [EnvEntry] = []
        for (index, pair) in pairs.enumerated() {
            if secret[index] {
                EnvVault.set(pair.1, site: project.id, env: "local", key: pair.0)
                entries.append(EnvEntry(key: pair.0, value: "", secret: true))
            } else {
                entries.append(EnvEntry(key: pair.0, value: pair.1, secret: false))
            }
        }
        var site = envs[project.id]?.site ?? SiteEnvironments(active: nil, environments: [])
        site.environments.removeAll { $0.id == "local" }
        site.environments.insert(EnvEnvironment(id: "local", name: L("env.kind.local"), kind: .local, entries: entries), at: 0)
        site.active = "local"
        if await saveEnvs(project.id, site) { await envAudit(project.id, env: "local", action: "importar"); notify(L("env.imported")) }
    }
    /// A new environment, empty, from `.env.example` (names, non-secret values) or copied from another.
    func createEnvironment(_ project: Project, name: String, kind: EnvKind, from base: String?) async -> String? {
        var site = envs[project.id]?.site ?? SiteEnvironments(active: nil, environments: [])
        // Standard environments use their standard name as id (and as APP_ENV); custom ones a slug.
        let slug = kind.standard ?? Self.slug(name)
        guard !slug.isEmpty, !site.environments.contains(where: { $0.id == slug }) else { errorMessage = L("env.nameTaken"); return nil }
        var entries: [EnvEntry] = []
        if base == "__example__" {
            let path = (project.path as NSString).appendingPathComponent(".env.example")
            let pairs = DotEnv.parse((try? String(contentsOfFile: path, encoding: .utf8)) ?? "")
            let secret = await classify(pairs.map(\.0))
            entries = pairs.enumerated().map { EnvEntry(key: $1.0, value: secret[$0] ? "" : $1.1, secret: secret[$0]) }
        } else if let base, let source = site.environments.first(where: { $0.id == base }) {
            if source.kind == .production, !(await EnvVault.authenticate(L("env.authCopy"), fresh: true)) { return nil }
            entries = source.entries
            for entry in source.entries where entry.secret {
                if let value = EnvVault.get(site: project.id, env: source.id, key: entry.key) { EnvVault.set(value, site: project.id, env: slug, key: entry.key) }
            }
        }
        // APP_ENV is the environment's standard name; APP_DEBUG only where nobody else looks.
        func upsert(_ key: String, _ value: String) {
            if let index = entries.firstIndex(where: { $0.key == key }) { entries[index] = EnvEntry(key: key, value: value, secret: false) }
            else { entries.append(EnvEntry(key: key, value: value, secret: false)) }
        }
        upsert("APP_ENV", slug)
        if kind != .other { upsert("APP_DEBUG", kind.debug ? "true" : "false") }
        site.environments.append(EnvEnvironment(id: slug, name: name, kind: kind, entries: entries))
        return await saveEnvs(project.id, site) ? slug : nil
    }
    func deleteEnvironment(_ project: Project, _ env: String) async {
        await run(L("busy.saving")) {
            let _: SiteEnvironments = try await self.call(["method": "envDelete", "id": project.id, "env": env, "actor": self.actor])
            EnvVault.deleteAll(site: project.id, env: env)
        }
        await loadEnvs(project.id)
    }
    /// Writes the environment as the site's `.env` and refreshes the site. Production needs the typed
    /// confirmation (done by the caller) plus Touch ID or the Mac's password (R4).
    func activateEnvironment(_ project: Project, _ env: EnvEnvironment, confirmedProduction: Bool = false) async {
        if env.kind == .production {
            guard confirmedProduction, await EnvVault.authenticate(String(format: L("env.authProduction"), project.title), fresh: true) else { return }
        }
        // Off the main thread: a Keychain prompt must never freeze the window.
        let keys = env.entries.filter(\.secret).map(\.key)
        let site = project.id, envID = env.id
        var secrets: [String: String] = await Task.detached {
            Dictionary(uniqueKeysWithValues: keys.map { ($0, EnvVault.get(site: site, env: envID, key: $0) ?? "") })
        }.value
        await run(String(format: L("env.activating"), env.title)) {
            let _: SiteEnvironments = try await self.call(["method": "envActivate", "id": project.id, "env": env.id, "secrets": secrets,
                                                         "confirmed": confirmedProduction, "actor": self.actor])
            self.notify(String(format: L("env.activated"), env.title))
        }
        secrets.removeAll()
        await loadEnvs(project.id); await refreshStatus()
        try? await Task.sleep(for: .seconds(2)); await refreshHealth()
    }
    /// Downloads the environment as `.env.<id>` with its real values, where the user chooses (R9):
    /// Touch ID or the Mac's password first (fresh for Production), mode 600, audited; inside a Git
    /// repository only if the file is ignored.
    func downloadEnv(_ project: Project, _ env: EnvEnvironment) async {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = ".env.\(env.id)"
        panel.directoryURL = URL(fileURLWithPath: project.path)
        panel.showsHiddenFiles = true
        panel.canCreateDirectories = true
        panel.message = String(format: L("env.downloadMessage"), env.title)
        panel.prompt = L("env.download")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let folder = url.deletingLastPathComponent().path, name = url.lastPathComponent
        guard name.hasPrefix(".env") else { errorMessage = L("env.downloadName"); return }
        if Self.insideRepository(folder), !Self.ignored(folder, name) {
            errorMessage = String(format: L("env.downloadNotIgnored"), name); return
        }
        guard await EnvVault.authenticate(String(format: L("env.authDownload"), env.title), fresh: env.kind == .production) else { return }
        let keys = env.entries.filter(\.secret).map(\.key)
        let site = project.id, envID = env.id
        var secrets: [String: String] = await Task.detached {
            Dictionary(uniqueKeysWithValues: keys.map { ($0, EnvVault.get(site: site, env: envID, key: $0) ?? "") })
        }.value
        await run(L("busy.saving")) {
            let _: Bool = try await self.call(["method": "envExport", "id": project.id, "env": env.id, "secrets": secrets, "path": url.path, "actor": self.actor])
            self.notify(String(format: L("env.downloaded"), name))
        }
        secrets.removeAll()
    }
    nonisolated static func git(_ folder: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", folder] + arguments
        process.environment = ["PATH": "/usr/bin:/bin", "GIT_OPTIONAL_LOCKS": "0"]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
    nonisolated static func insideRepository(_ folder: String) -> Bool { git(folder, ["rev-parse", "--is-inside-work-tree"]) }
    nonisolated static func ignored(_ folder: String, _ name: String) -> Bool { git(folder, ["check-ignore", "-q", "--", name]) }

    /// A template without secret values, next to the project (R9).
    func exportTemplate(_ project: Project, _ env: EnvEnvironment) async {
        let text = "# Plantilla del entorno «\(env.title)» (sin valores secretos)\n" + env.entries.map { "\($0.key)=\($0.secret ? "" : $0.value)" }.joined(separator: "\n") + "\n"
        let name = ".env.\(env.id).example"
        let path = (project.path as NSString).appendingPathComponent(name)
        do {
            try text.write(toFile: path, atomically: true, encoding: .utf8)
            await envAudit(project.id, env: env.id, action: "exportar")
            notify(String(format: L("env.exported"), name))
        } catch { errorMessage = L("env.exportFailed") }
    }
    static func slug(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
        return String(folded.map { $0.isLetter || $0.isNumber ? $0 : "-" }).split(separator: "-").joined(separator: "-").prefix(40).description
    }

    // MARK: Setup: what Stack needs on a new Mac, asked for and installed one by one
    var showSetup = false
    var phpCatalog: [PhpCatalogEntry] = []
    /// Apple's command line tools (Git, compiler): needed for new projects and engines built from source.
    var appleTools = true
    /// Developer tools on this Mac for the work profiles (`devTools`).
    var devTools: [String: DevToolStatus] = [:]
    var devUpdates = DevUpdates()
    var pythonLines: [PythonLine] = []
    func refreshDevTools(refresh: Bool = false) async {
        if let tools: [String: DevToolStatus] = try? await call(["method": "devTools"]) { devTools = tools }
        if let updates: DevUpdates = try? await call(["method": "devToolUpdates", "refresh": refresh]) { devUpdates = updates }
        if pythonLines.isEmpty, let lines: [PythonLine] = try? await call(["method": "pythonVersions"]) { pythonLines = lines }
    }
    /// Installs or updates a developer tool from its official source (the app asked first).
    func installDevTool(_ tool: String, version: String = "", shellPath: Bool = true, acceptLicenses: Bool = false) async {
        let title = L("tool.\(tool)")
        await run(String(format: L("tools.installing"), title)) {
            let _: JSONAny = try await self.call(["method": "installDevTool", "tool": tool, "version": version, "shellPath": shellPath, "acceptLicenses": acceptLicenses, "confirmed": true])
        }
        await refreshDevTools(refresh: true)
        if devTools[tool == "python" ? "uv" : tool]?.installed == true { notify(String(format: L("tools.installed"), title)) }
    }
    var phpReady: Bool { phpRuntimes.contains(where: \.verified) }
    var caddyReady: Bool { !(installedTools["caddy"] ?? []).isEmpty }
    var agentReady: Bool { agent?.loaded == true }
    /// What must exist for sites to be served at all.
    /// Ready to serve sites: Caddy and the agent; PHP only when the user works with Laravel or PHP.
    var setupComplete: Bool { caddyReady && agentReady && (!WorkProfile.chosen.contains("laravel") || phpReady) }
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
    /// `refresh`: ask the source again (reload button); otherwise the engine's local copy answers.
    func loadPhpCatalog(refresh: Bool = false) async {
        busy = L("busy.catalog"); defer { busy = nil }
        if let value: [PhpCatalogEntry] = try? await call(["method": "phpCatalog", "refresh": refresh]) { phpCatalog = value; phpCatalogFailed = false } else { phpCatalogFailed = true }
    }
    func downloadPhp(_ version: String) async {
        await run(L("busy.installing")) {
            let _: PhpManifestSummary = try await self.call(["method": "downloadPhp", "version": version, "confirmed": true])
            self.notify(L("toast.installed"))
        }
        await refreshRuntimes(); await reloadStack()
    }
    /// QA and screenshots only (debug builds): open the window at launch.
    static var qaWindow: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["BUTAKE_QA_WINDOW"] != nil
        #else
        false
        #endif
    }
    /// At launch: when something essential is missing, the window opens on the setup sheet.
    func checkSetupAtLaunch() async {
        await refresh(); await refreshRuntimes(); await refreshAppleTools()
        // A separate data folder (QA) must not open the installed app through the URL scheme.
        if !setupComplete, ProcessInfo.processInfo.environment["BUTAKE_STACK_HOME"] == nil { NSWorkspace.shared.open(URL(string: "butakestack://setup")!) }
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
    func loadProjectVersions() async {
        if let versions: [String: String] = try? await call(["method": "projectVersions"]) { projectVersions = versions }
    }
    /// Creates a project of any kind (`kind`, `name`, `parent` and that kind's options). The sheet
    /// shows progress, the result and what's next, so this doesn't navigate or toast by itself.
    func createProject(_ request: [String: Any]) async -> Result<CreatedProject, CreateFailure> {
        var payload = request
        payload["method"] = "createProject"
        do {
            let created: CreatedProject = try await call(payload)
            await refresh()
            return .success(created)
        } catch let failure as EngineFailure {
            return .failure(CreateFailure(message: failure.errorDescription ?? L("engine.requestFailed")))
        } catch {
            return .failure(CreateFailure(message: L("engine.requestFailed")))
        }
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
        missingSites = (try? await call(["method": "missingProjects"])) ?? []
        groups = (try? await call(["method": "siteGroups"])) ?? groups
        config = try? await call(["method": "stackConfig"])
        await loadAllEnvs()
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
        for tool in ["node", "jdk", "caddy"] + Route.allEngines {
            installedTools[tool] = (try? await call(["method": "installedTools", "tool": tool])) ?? []
        }
    }
    func loadAvailable(_ tool: String, refresh: Bool = false) async {
        await run(L("busy.catalog")) {
            self.availableTools[tool] = try await self.call(["method": "availableTools", "tool": tool, "refresh": refresh])
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
            EnvVault.deleteAll(site: project.id)
            self.selectedSite = nil
            self.route = .home
        }
    }
    /// Removes a site whose folder is gone: its record, environments and Keychain secrets.
    func forget(_ site: MissingSite) async {
        await run(L("busy.saving"), refresh: true) {
            let _: Bool = try await self.call(["method": "deleteProject", "id": site.id])
            EnvVault.deleteAll(site: site.id)
        }
    }
    /// Opens a project folder, or (`scan`) a folder that holds several projects.
    func chooseFolder(scan: Bool = false) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.prompt = L("site.chooseFolder")
        if scan { panel.prompt = L("import.choose"); panel.message = L("import.chooseMessage") }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await openFolder(url.path, scan: scan) }
    }
    /// A project folder opens in the site editor; a folder that holds several projects opens the import.
    func openFolder(_ path: String, scan forceScan: Bool = false) async {
        if let scan: FolderScan = try? await call(["method": "scanFolder", "path": path]), forceScan || !scan.rootIsProject, !scan.projects.isEmpty {
            importScan = scan
        } else {
            await detect(path)
        }
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

struct MissingSite: Codable, Identifiable, Sendable, Hashable {
    let id: String
    let path: String
}

struct CreateFailure: Error { let message: String }
