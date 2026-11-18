import AppKit
import OSLog
import SwiftUI

/// Everything the window shows. All engine calls go through `StackEngine` (JSON over stdin/stdout).
@MainActor @Observable final class StackStore {
    static let shared = StackStore()
    let engine: StackEngine
    /// Tests give the store an engine of their own (a temporary store).
    init(engine: StackEngine = StackEngine()) { self.engine = engine }
    private static let log = Logger(subsystem: "cl.butake.stack.native", category: "store")

    var route: Route = .home
    var selectedSite: Project.ID?
    var projects: [Project] = []
    /// Sites whose folder isn't there (deleted, moved or on a disconnected drive).
    /// Folders that group sites (sidebar and Home).
    var groups: [ProjectGroup] = []
    /// Folder saves run one at a time and always save the latest state (see `updateGroups`).
    @ObservationIgnored var groupsSaving = false
    @ObservationIgnored var groupsDirty = false
    /// Folders closed by the user: one state for the sidebar and Inicio, kept with this Mac (the key
    /// is the sidebar's, from before Inicio could close them). `looseFolder` stands for «Sin carpeta».
    var closedFolders: Set<String> = Set((UserDefaults.standard.string(forKey: "sidebar.collapsedGroups") ?? "").split(separator: ",").map(String.init)) {
        didSet { UserDefaults.standard.set(closedFolders.sorted().joined(separator: ","), forKey: "sidebar.collapsedGroups") }
    }
    /// A folder being named (new or renamed); the sidebar shows the prompt.
    var groupNaming: GroupNaming?
    /// The folder (its id) a new folder is created in; nil: the projects folder.
    var newFolderParent: String?
    /// What the engine says of the projects folder (the sidebar follows it once `enabled`).
    var disk: DiskState?
    /// A move of a folder on the disk that waits for the user's yes.
    var pendingDiskMove: DiskMoveRequest?
    /// The user closed the first comparison with `groups.json` without deciding: asked again next time.
    var migrationDeferred = false
    /// Tests point the app at a temporary projects folder, never the owner's.
    @ObservationIgnored var projectsFolderOverride: String?
    @ObservationIgnored var diskObserver: Task<Void, Never>?
    /// The project of several parts whose «Iniciar todo» or «Detener todo» is under way.
    var compositeWorking: String?
    /// Current framework and generator versions (npm and Packagist), cached by the engine.
    var projectVersions: [String: String] = [:]
    var status: StackStatus?
    var daemonRunning = false
    /// The supervisor stopped answering a moment ago: «Reconectando…» until `DaemonLiveness.grace` ends.
    var daemonReconnecting = false
    @ObservationIgnored var liveness = DaemonLiveness()
    @ObservationIgnored private var graceTask: Task<Void, Never>?
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?
    var agent: AgentStatus?
    var config: StackConfig?
    var phpRuntimes: [PhpRuntimeSummary] = []
    var installedTools: [String: [ToolManifest]] = [:]
    var availableTools: [String: [AvailableVersion]] = [:]
    var ports: PortOwners?
    var recipes: [EngineRecipe] = []
    var lifecycles: [String: [Cycle]] = [:]
    // Python (Stack's own CPython), toolchains of Rust and Swift, and the terminal's links.
    var pythonRuntimes: [PythonRuntime] = []
    var pythonCatalog: [PythonCatalogEntry] = []
    var pythonCatalogFailed = false
    /// Why a catalog of versions could not be read (by provider id), shown in its picker.
    var catalogErrors: [String: String] = [:]
    var terminalLinks: [String: TerminalLink] = [:]
    var rustToolchains: [RustToolchain] = []
    var rustLoaded = false
    var swiftToolchains: SwiftToolchains?
    var requirements: [String: FrameworkRequirement] = [:]
    func loadLifecycle(_ tool: String) async {
        if lifecycles[tool] == nil, let cycles: [Cycle] = try? await call(["method": "lifecycle", "tool": tool]) { lifecycles[tool] = cycles }
    }
    func cycle(_ tool: String, for version: String) -> Cycle? { lifecycles[tool]?.first { $0.matches(version) } }
    func enginePort(_ id: String) -> Int? { recipes.first { $0.id == id }?.port }
    private var jobs: [(id: UUID, label: String)] = []
    var busy: String? { jobs.last?.label }
    /// Plugins of the catalog and whether it has been read (see `pluginEnabled`).
    var plugins: [ToolInfo] = []
    var pluginsLoaded = false
    /// A plain message for the alert of the window (the text of a failure that has no button).
    var errorMessage: String?
    /// The last failure of an action asked in the window, and the one asked in the menu bar
    /// panel: each surface shows its own, and an error never opens the window (StackStore+Attention).
    var failure: ActionFailure?
    var panelFailure: ActionFailure?
    var toast: String?
    /// The last action that can be undone, offered in the window's notice with «Deshacer» (StackStore+Undo).
    var undoOffer: UndoOffer?
    /// The pages visited, for Atrás and Adelante (RouteHistory).
    var history = RouteHistory()
    /// The window's undo manager (set by `RootView`): what `undoable` registers on (StackStore+Undo).
    @ObservationIgnored weak var undoManager: UndoManager?
    /// True while an undo or redo runs, so the actions it repeats do not register themselves again.
    @ObservationIgnored var replayingUndo = false
    /// The last undo or redo that ran, for tests to wait on.
    @ObservationIgnored var undoTask: Task<Void, Never>?
    var newSite: Detection?
    /// A folder holding several projects, ready to import.
    var importScan: FolderScan?
    var showPalette = false
    /// A configuration file read from Archivo › Restaurar configuración…, waiting for its review.
    var restoreRequest: RestoreRequest?
    /// Edición › Buscar asks the sidebar to focus its search field.
    var findRequests = 0
    /// A project waiting for the confirmation to take it out of Stack (Proyecto › Quitar proyecto…).
    var removing: Project?
    /// A project in the rename sheet (Proyecto › Renombrar…, `butakestack://project/rename`).
    var renaming: RenameRequest?
    /// Renames whose pending steps are being finished (see `completePendingRenames`), and those
    /// whose Keychain step failed in this session: retried at the next launch, never in a loop.
    @ObservationIgnored var renamesRunning = false
    @ObservationIgnored var renameKeychainFailed: Set<String> = []
    /// Projects whose `.env` took another project's new port while their processes run.
    var portRestartOffer: PortRestartOffer?
    var showNewProject = false
    /// «Clonar repositorio…»: the Git tool's clone sheet from anywhere (see `CloneRepositoryEntry`).
    var showClone = false
    /// Last HTTP status of each site (0 = no answer).
    var siteHealth: [String: Int] = [:]
    func refreshHealth() async {
        #if DEBUG
        if QAHooks.simulatesSitesOnline { siteHealth = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, 200) }); return }
        #endif
        if let value: [String: Int] = try? await call(["method": "siteHealth"]), !Task.isCancelled, siteHealth != value { siteHealth = value }
    }
    var logs: [String: [String]] = [:]
    // Local trust (/etc/resolver, local CA), mail catcher, dumps and watched folders (StackStore+Local).
    var localTrust: LocalTrust?
    var mailMessages: [MailSummary] = []
    var dumps: [DumpEntry] = []
    var watchedFolders: [WatchedFolder] = []
    /// Watched folders with projects that are not sites yet, waiting for the user.
    var watchedPending: [FolderScan] = []

    var git: [String: GitInfo] = [:]
    /// Sites shown in the menu bar panel (a preference of this Mac, not of the projects).
    var favoriteSites: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "panel.favorites") ?? []) {
        didSet { UserDefaults.standard.set(Array(favoriteSites).sorted(), forKey: "panel.favorites") }
    }
    func isFavorite(_ id: String) -> Bool { favoriteSites.contains(id) }
    func toggleFavorite(_ id: String) {
        if favoriteSites.contains(id) { favoriteSites.remove(id) } else { favoriteSites.insert(id) }
    }
    var worktrees: [String: [Worktree]] = [:]
    /// What the last branch switch of a site changed, until the user deals with it.
    var branchNotices: [String: BranchChanges] = [:]
    var runningTask: String?

    var envs: [String: EnvState] = [:]
    /// What each project needs now, by id (P-42; StackStore+Attention).
    var attention: [String: [ProjectAttention]] = [:]
    /// A service the user turned off while projects that are on use it, waiting for the
    /// confirmation that names them.
    var serviceStop: ServiceStopRequest?

    /// The setup assistant (first launch, while something is missing, Ayuda).
    var showSetup = false
    var phpCatalog: [PhpCatalogEntry] = []
    /// Apple's command line tools (Git, compiler): needed for new projects and engines built from source.
    var appleTools = true
    /// Developer tools on this Mac for the work profiles (`devTools`).
    var devTools: [String: DevToolStatus] = [:]
    var devUpdates = DevUpdates()
    var pythonLines: [PythonLine] = []
    var phpCatalogFailed = false

    func process(_ id: String) -> ProcessEntry? { status?.processes.first { $0.id == id } }
    func phase(_ id: String) -> ProcessPhase { process(id).map { ProcessPhase($0.status.state) } ?? .stopped }
    var stackProcesses: [ProcessEntry] { status?.processes.filter { $0.id.hasPrefix("stack.") } ?? [] }
    var engineCount: Int { stackProcesses.count }
    var runningEngines: Int { stackProcesses.filter { $0.status.state == "running" }.count }
    var runningSiteProcesses: Int { status?.processes.filter { !["stack.", "share.", "public.", "cloudflare."].contains(where: $0.id.hasPrefix) && $0.status.state == "running" }.count ?? 0 }

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
    /// A call that cancelling its task stops (see `StackEngine.stoppableCall`).
    func stoppableCall<T: Decodable & Sendable>(_ parameters: [String: Any], as type: T.Type = T.self) async throws -> T {
        let data = try JSONSerialization.data(withJSONObject: parameters)
        return try await engine.stoppableCall(json: data, as: type)
    }

    func refresh() async {
        do { projects = try await call(["method": "listProjects"]) } catch { report(error) }
        await loadAttention()
        await refreshDisk()
        groups = (try? await call(["method": "siteGroups"])) ?? groups
        // A transient engine failure keeps the last good value instead of reading as «not installed».
        if let value: StackConfig = try? await call(["method": "stackConfig"]) { config = value }
        await loadPlugins()
        await loadAllEnvs()
        await refreshStatus()
        if let value: AgentStatus = try? await call(["method": "agentStatus"]) { agent = value }
        await refreshTrust()
        if selectedProject == nil { selectedSite = projects.first?.id }
    }
    func refreshStatus() async {
        let value: StackStatus?
        do { value = try await call(["method": "stackStatus"]) } catch {
            // Tells an unreadable answer (engine and app out of step) from a daemon that is simply off.
            if !(error is EngineFailure) { Self.log.error("stackStatus failed: \(String(describing: error), privacy: .public)") }
            value = nil
        }
        applyStatus(value)
    }

    func applyStatus(_ value: StackStatus?, at now: Date = Date()) {
        #if DEBUG
        let value = QAHooks.simulatedStatus ?? value
        #endif
        if status != value { status = value }
        if daemonRunning != (value != nil) { daemonRunning = value != nil }
        liveness.observe(up: value != nil, at: now)
        updateReconnecting(at: now)
        #if DEBUG
        if QAHooks.simulatesReconnecting { daemonReconnecting = true }
        #endif
    }

    /// «Reconectando…» while the grace lasts; a task ends it so the bar says «Detenido» on time.
    private func updateReconnecting(at now: Date) {
        let left = liveness.remaining(at: now)
        let reconnecting = liveness.phase(at: now) == .reconnecting
        if daemonReconnecting != reconnecting { daemonReconnecting = reconnecting }
        graceTask?.cancel()
        guard let left else { return }
        graceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(left + 0.05))
            guard !Task.isCancelled, let self else { return }
            self.updateReconnecting(at: Date())
        }
    }

    /// A Mac that wakes up reads the state at once instead of waiting for the next turn of the poll,
    /// and a read that failed across the sleep does not count as «Detenido».
    private func observeWake() {
        guard wakeObserver == nil else { return }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.liveness.wake(at: Date())
                Task { await self.refreshStatus(); await self.refreshDisk() }
            }
        }
    }
    func refreshRuntimes() async {
        phpRuntimes = (try? await call(["method": "listPhpRuntimes"])) ?? []
        pythonRuntimes = (try? await call(["method": "listPythonRuntimes"])) ?? []
        terminalLinks = (try? await call(["method": "terminalStatus"])) ?? [:]
        recipes = (try? await call(["method": "engineRecipes"])) ?? recipes
        for tool in ["node", "jdk", "caddy"] + Route.allEngines {
            installedTools[tool] = (try? await call(["method": "installedTools", "tool": tool])) ?? []
        }
    }
    /// A catalog that cannot be read is said in its picker (with «Reintentar»), never as an alert.
    func loadAvailable(_ tool: String, refresh: Bool = false) async {
        let job = beginJob(L("busy.catalog"))
        defer { endJob(job) }
        do {
            availableTools[tool] = try await call(["method": "availableTools", "tool": tool, "refresh": refresh])
            catalogErrors[tool] = nil
        } catch { catalogErrors[tool] = EngineFailure.message(error) }
    }
    func refreshPorts() async {
        ports = try? await call(["method": "portStatus"])
        if let value: AgentStatus = try? await call(["method": "agentStatus"]) { agent = value }
    }

    func beginJob(_ label: String) -> UUID {
        let id = UUID()
        jobs.append((id, label))
        return id
    }

    /// New text for a job under way (a long export says how far it got).
    func updateJob(_ id: UUID, _ label: String) {
        if let index = jobs.firstIndex(where: { $0.id == id }) { jobs[index].label = label }
    }

    func endJob(_ id: UUID) {
        jobs.removeAll { $0.id == id }
    }

    /// Runs an engine action with a busy label, then refreshes. A failure is said on the surface that
    /// asked (`surface`), titled `failureTitle`, with «Reintentar» to run the same action again.
    /// `canRetry` is false for work that leaves something behind when it fails (a rename's Keychain copies).
    func run(_ label: String, refresh: Bool = false, from surface: StopSurface = .window, failureTitle: String? = nil,
             canRetry: Bool = true, _ work: @escaping @MainActor () async throws -> Void) async {
        let job = beginJob(label)
        defer { endJob(job) }
        do {
            try await work()
        } catch {
            var retry: (@MainActor () async -> Void)?
            if canRetry {
                retry = { [weak self] in await self?.run(label, refresh: refresh, from: surface, failureTitle: failureTitle, work) }
            }
            report(error, title: failureTitle, from: surface, retry: retry)
        }
        // A partly successful action leaves new state behind even when it fails.
        if refresh { await self.refresh() }
    }
    /// Says what went wrong where the action was asked: the window's alert, or the panel's banner.
    func report(_ error: Error, title: String? = nil, from surface: StopSurface = .window, retry: (@MainActor () async -> Void)? = nil) {
        let failure = ActionFailure(error: error, title: title, retry: retry)
        if surface == .panel { panelFailure = failure } else { self.failure = failure }
    }
    /// What the alert of the window shows: a failure with its buttons, or a plain message.
    var windowFailure: ActionFailure? {
        failure ?? errorMessage.map { ActionFailure(title: L("error.title"), message: $0) }
    }
    func dismissFailure() { failure = nil; errorMessage = nil }
    func notify(_ text: String) {
        withAnimation(.snappy) { toast = text }
        Task { try? await Task.sleep(for: .seconds(2.5)); withAnimation(.snappy) { if toast == text { toast = nil } } }
    }

    @ObservationIgnored private var startup: Task<Void, Never>?
    @ObservationIgnored private var statusObserver: Task<Void, Never>?

    func bootstrap() async {
        if startup == nil {
            startup = Task {
                await refresh()
                // A rename started outside the app (or interrupted) is finished first.
                VaultSession.onUnlock = { [weak self] in Task { @MainActor in await self?.completePendingRenames() } }
                await completePendingRenames()
                await refreshRuntimes()
                await refreshAppleTools()
                // Idle unless the Git tool is on and «Buscar cambios cada 5 minutos» is checked.
                GitStatusBoard.shared.start()
            }
        }
        await startup?.value
    }

    /// State events are shared by the menu bar and the window. Reconnect after the daemon
    /// exits or after an upgrade, without restarting it on behalf of the user.
    func startPolling() {
        startDiskWatch()
        observeWake()
        guard statusObserver == nil else { return }
        statusObserver = Task { [weak self] in
            var delay = 5.0
            while !Task.isCancelled, let self {
                var received = false
                do {
                    for try await value in engine.statusStream() {
                        received = true
                        applyStatus(value)
                    }
                } catch {
                    // The fallback below refreshes and reconnects; the first failure of a run is logged.
                    if delay == 5 { Self.log.error("watch-status ended: \(String(describing: error), privacy: .public)") }
                }
                guard !Task.isCancelled else { return }
                await refreshStatus()
                delay = received ? 5 : min(delay * 2, 15)
                try? await Task.sleep(for: .seconds(delay))
            }
        }
    }

    /// Moving the data folder: the status stream lets go of the daemon's socket until the app restarts.
    func pauseForDataMove() {
        statusObserver?.cancel()
        statusObserver = nil
        stopDiskWatch()
    }

    func refreshVisibleProjects() async {
        await bootstrap()
        await refreshWatched()
        while !Task.isCancelled {
            // Nothing to keep fresh while the app is in the background: wait until it is active again,
            // then refresh at once.
            if !NSApp.isActive {
                for await _ in NotificationCenter.default.notifications(named: NSApplication.didBecomeActiveNotification) { break }
                if Task.isCancelled { return }
                continue
            }
            // Projects and folders changed outside the app (the engine's command line, another Mac's
            // restore) show up here too, not only after Ir › Recargar.
            async let projects: Void = refreshDisk()
            async let health: Void = refreshHealth()
            async let git: Void = refreshGit()
            _ = await (projects, health, git)
            await completePendingRenames()
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
        }
    }

}
