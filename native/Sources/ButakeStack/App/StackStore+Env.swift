import AppKit
import SwiftUI

extension StackStore {
    // MARK: Environments of each site's .env (secrets in the Keychain, never in the engine's store)
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
    func saveEnvs(_ id: String, _ site: ProjectEnvironments) async -> Bool {
        var ok = false
        await run(L("busy.saving")) {
            let object = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(site))
            let _: ProjectEnvironments = try await self.call(["method": "envSave", "id": id, "site": object, "actor": self.actor])
            ok = true
        }
        await loadEnvs(id)
        return ok
    }
    /// An environment's secret values, read off the main thread (a Keychain prompt must never freeze
    /// the window). Nil, with a message, when the Keychain refuses: nothing was changed or lost.
    func secretValues(_ site: String, _ env: String) async -> [String: String]? {
        let result = await Task.detached { Result { try EnvSecrets.keychain.values(site: site, env: env) } }.value
        if case .success(let values) = result { return values }
        errorMessage = L("env.keychainFailed")
        return nil
    }
    /// Sets and removes an environment's secret values in one Keychain write.
    func updateSecrets(_ site: String, _ env: String, set: [String: String], remove: Set<String> = []) async -> Bool {
        let result = await Task.detached { Result { try EnvSecrets.keychain.update(site: site, env: env, set: set, remove: remove) } }.value
        if case .success = result { return true }
        errorMessage = L("env.keychainFailed")
        return false
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
        var secrets: [String: String] = [:]
        for (index, pair) in pairs.enumerated() {
            if secret[index] { secrets[pair.0] = pair.1 }
            entries.append(EnvEntry(key: pair.0, value: secret[index] ? "" : pair.1, secret: secret[index]))
        }
        guard await updateSecrets(project.id, "local", set: secrets) else { return }
        var site = envs[project.id]?.site ?? ProjectEnvironments(active: nil, environments: [])
        site.environments.removeAll { $0.id == "local" }
        site.environments.insert(EnvEnvironment(id: "local", name: L("env.kind.local"), kind: .local, entries: entries), at: 0)
        site.active = "local"
        if await saveEnvs(project.id, site) { await envAudit(project.id, env: "local", action: "importar"); notify(L("env.imported")) }
    }
    /// A new environment, empty, from `.env.example` (names, non-secret values) or copied from another.
    func createEnvironment(_ project: Project, name: String, kind: EnvKind, from base: String?) async -> String? {
        var site = envs[project.id]?.site ?? ProjectEnvironments(active: nil, environments: [])
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
            let keys = Set(source.entries.filter(\.secret).map(\.key))
            if !keys.isEmpty {
                guard let values = await secretValues(project.id, source.id),
                      await updateSecrets(project.id, slug, set: values.filter { keys.contains($0.key) }) else { return nil }
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
            let _: ProjectEnvironments = try await self.call(["method": "envDelete", "id": project.id, "env": env, "actor": self.actor])
            EnvSecrets.keychain.deleteAll(site: project.id, env: env)
        }
        await loadEnvs(project.id)
    }
    /// Writes the environment as the site's `.env` and refreshes the site. Production needs the typed
    /// confirmation (done by the caller) plus Touch ID or the Mac's password (R4).
    /// `restart: false` leaves the running processes as they are, for the caller to offer it.
    func activateEnvironment(_ project: Project, _ env: EnvEnvironment, confirmedProduction: Bool = false, restart: Bool = true) async {
        if env.kind == .production {
            guard confirmedProduction, await EnvVault.authenticate(String(format: L("env.authProduction"), project.title), fresh: true) else { return }
        }
        guard let secrets = await secretsFor(project, env) else { return }
        await run(String(format: L("env.activating"), env.title)) {
            let _: ProjectEnvironments = try await self.call(["method": "envActivate", "id": project.id, "env": env.id, "secrets": secrets,
                                                         "confirmed": confirmedProduction, "restart": restart, "actor": self.actor])
            self.notify(String(format: L("env.activated"), env.title))
        }
        await loadEnvs(project.id); await refreshStatus()
        try? await Task.sleep(for: .seconds(2)); await refreshHealth()
    }
    /// The value of each secret of the environment ("" when it has none), with one Keychain read.
    private func secretsFor(_ project: Project, _ env: EnvEnvironment) async -> [String: String]? {
        let keys = env.entries.filter(\.secret).map(\.key)
        guard !keys.isEmpty else { return [:] }
        guard let values = await secretValues(project.id, env.id) else { return nil }
        return Dictionary(uniqueKeysWithValues: keys.map { ($0, values[$0] ?? "") })
    }
    /// The project's processes that are running now, which take a new environment only on restart.
    func liveProcessIDs(_ project: Project) -> [String] {
        project.processes.map { "\(project.id).\($0.name)" }.filter { [.running, .starting].contains(phase($0)) }
    }
    func restartProcesses(_ project: Project) async {
        for id in liveProcessIDs(project) { await processAction(id, "restart") }
    }
    /// After `changed` got a new port: the engine already wrote again the `.env` it could (no
    /// secrets); the ones with secrets are written here with the Keychain (never Production, which
    /// asks first: its Entornos says it is out of date). Running processes keep the old port until
    /// they restart, so that is offered, never done without asking.
    func followPortChange(of changed: Project, _ dependents: [PortDependent]) async {
        var updated: [Project] = []
        // Their own `env` changed: the supervisor restarted what was running, and its log says why.
        let restarted = dependents.filter { $0.state == "processes" }.compactMap { d in projects.first { $0.id == d.id } }
            .filter { !liveProcessIDs($0).isEmpty }.map(\.title)
        if !restarted.isEmpty { notify(String(format: L("env.portRestarted"), restarted.joined(separator: ", "), changed.title)) }
        for dependent in dependents where ["rewritten", "outdated"].contains(dependent.state) {
            await loadEnvs(dependent.id)
            guard let project = projects.first(where: { $0.id == dependent.id }) else { continue }
            if dependent.state == "outdated" {
                guard let env = activeEnvironment(project.id), env.kind != .production else { continue }
                await activateEnvironment(project, env, restart: false)
                guard (envs[project.id]?.site.outdated ?? []).isEmpty else { continue }
            }
            if !liveProcessIDs(project).isEmpty { updated.append(project) }
        }
        if !updated.isEmpty { portRestartOffer = PortRestartOffer(changed: changed.title, projects: updated) }
    }
    /// «Pasar el entorno activo a los procesos»: applies from each process's next start.
    func setPassToProcesses(_ project: Project, _ on: Bool) async {
        guard var site = envs[project.id]?.site else { return }
        site.passToProcesses = on
        _ = await saveEnvs(project.id, site)
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
        guard let secrets = await secretsFor(project, env) else { return }
        await run(L("busy.saving")) {
            let _: Bool = try await self.call(["method": "envExport", "id": project.id, "env": env.id, "secrets": secrets, "path": url.path, "actor": self.actor])
            self.notify(String(format: L("env.downloaded"), name))
        }
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
}
