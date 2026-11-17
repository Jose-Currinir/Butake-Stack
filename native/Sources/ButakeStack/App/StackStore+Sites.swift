import AppKit
import SwiftUI

extension StackStore {
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
        // With a root password, a new MySQL database gets its own account instead of root.
        if let root = DatabaseVault.get(DatabaseVault.mysqlRoot) { payload["mysqlPassword"] = root }
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
        // A project without its folder never starts: it is found again or removed first.
        // A project without a server has no switch.
        guard !project.isMissing, project.isServed else { return }
        var started: [String] = []
        await run(enabled ? L("busy.start") : L("busy.stop"), refresh: true) {
            let answer: SiteSwitch = try await self.call(["method": "setSiteEnabled", "id": project.id, "enabled": enabled])
            started = answer.servicesStarted ?? []
        }
        // Its services that were off came on with it: said, never silent (P-42).
        if !started.isEmpty {
            notify(String(format: L("attention.servicesStarted"), started.map { Tech.of($0).title }.joined(separator: ", "), project.title))
        }
        // Its databases' extensions are checked as it starts (P-43).
        if enabled { await checkExtensionsAfterStart(project) }
        try? await Task.sleep(for: .seconds(2))
        await refreshHealth()
    }
    // MARK: Sites
    func save(_ project: Project) async -> Bool {
        var dependents: [PortDependent]?
        await run(L("busy.saving"), refresh: true) {
            let data = try JSONEncoder().encode(project)
            let object = try JSONSerialization.jsonObject(with: data)
            let saved: SavedProject = try await self.call(["method": "saveProject", "project": object, "actor": self.actor])
            self.openSite(saved.project.id)
            dependents = saved.portDependents
        }
        guard let dependents else { return false }
        notify(L("toast.saved"))
        await followPortChange(of: project, dependents)
        return true
    }
    func delete(_ project: Project) async {
        var dependents: [PortDependent] = []
        await run(L("busy.saving"), refresh: true) {
            let removed: RemovedProject = try await self.call(["method": "deleteProject", "id": project.id, "actor": self.actor])
            await Task.detached { EnvSecrets.keychain.deleteAll(site: project.id) }.value
            self.selectedSite = nil
            self.route = .home
            dependents = removed.portDependents
        }
        // Their `.env` keeps the old port and Entornos says the project is gone.
        for dependent in dependents { await loadEnvs(dependent.id) }
    }
    /// «Buscar carpeta…» of a project whose folder was moved or renamed: the folder chosen must be
    /// a project that no other one uses; the engine keeps the rest of its record.
    func findFolder(_ project: Project) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        let near = URL(fileURLWithPath: project.path).deletingLastPathComponent()
        panel.directoryURL = FileManager.default.fileExists(atPath: near.path) ? near : Folder.ensureProjects()
        panel.prompt = L("missing.findPrompt")
        panel.message = String(format: L("missing.findMessage"), project.title)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            var found = false
            await run(L("busy.saving"), refresh: true) {
                let _: Project = try await self.call(["method": "relocateProject", "id": project.id, "path": url.path])
                found = true
            }
            if found { openSite(project.id); notify(L("missing.found")) }
        }
    }
    /// Opens a project folder, or (`scan`) a folder that holds several projects.
    func chooseFolder(scan: Bool = false) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.directoryURL = Folder.ensureProjects()
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
}
