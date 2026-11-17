import AppKit
import SwiftUI

/// What `renameProject` answers.
struct RenamedProject: Decodable, Sendable {
    let project: Project
    let restarted: Bool
    let pending: [String]
}

/// What `moveProject` answers. `envReapply`: the active environment's `.env` is not in the new folder.
struct MovedProject: Decodable, Sendable {
    let project: Project
    let restarted: Bool
    let envReapply: Bool
}

/// A rename whose steps outside the engine are not done yet (`pendingRenames`).
struct PendingRename: Decodable, Sendable, Equatable {
    let from: String
    let to: String
    let steps: [String]
}

/// The rename sheet's request: from the project's menu, or a link that proposes a new id.
struct RenameRequest: Identifiable, Equatable {
    let project: Project
    var proposedId: String?
    var id: String { project.id }
}

extension StackStore {
    /// Where the Entornos items live: the Keychain, or an isolated memory store in a QA window.
    var renameSecrets: EnvSecrets {
        #if DEBUG
        if let qa = RenameQA.secrets { return qa }
        #endif
        return EnvSecrets.keychain
    }

    /// Renames a project (P-41). The Keychain goes first: its items are copied to the new id, and if
    /// it does not answer nothing is renamed. Then the engine changes everything else in one step;
    /// if it refuses, the copies go and the project stays as it was. Only after both are the old
    /// items deleted.
    @discardableResult func renameProject(_ project: Project, to newId: String, name: String, domain: Bool, secrets: EnvSecrets? = nil) async -> Bool {
        let (from, secrets) = (project.id, secrets ?? renameSecrets)
        let copied = await Task.detached { Result { try secrets.copyAll(site: from, to: newId) } }.value
        guard case .success(let created) = copied else {
            errorMessage = L("rename.keychainFailed")
            return false
        }
        var renamed: RenamedProject?
        await run(L("busy.renaming")) {
            renamed = try await self.call(["method": "renameProject", "id": from, "newId": newId, "name": name,
                                           "domain": domain, "keychainMoved": true, "actor": self.actor])
        }
        guard let renamed else {
            await Task.detached { secrets.removeCopies(created) }.value
            return false
        }
        await Task.detached { secrets.deleteAll(site: from) }.value
        await completePendingRenames(secrets: secrets)
        await refresh()
        openSite(renamed.project.id)
        notify(renamed.restarted ? L("rename.doneRestarted") : L("rename.done"))
        return true
    }

    /// Finishes what renames left to the app: the Keychain items, the vault's links (once it is
    /// unlocked) and this Mac's preferences. Runs at launch, every refresh and after each unlock.
    func completePendingRenames(secrets: EnvSecrets? = nil) async {
        guard !renamesRunning else { return }
        renamesRunning = true
        defer { renamesRunning = false }
        guard let pending: [PendingRename] = try? await call(["method": "pendingRenames"]), !pending.isEmpty else { return }
        for rename in pending {
            for step in rename.steps {
                guard await complete(step, of: rename, secrets: secrets ?? renameSecrets) else { continue }
                do {
                    let _: [PendingRename] = try await call(["method": "renameStepDone", "from": rename.from, "to": rename.to, "step": step])
                } catch {
                    // Said once per rename and step: it is tried again at every refresh.
                    if renameKeychainFailed.insert("\(rename.from)>\(rename.to)#\(step)").inserted { report(error) }
                }
            }
        }
    }

    private func complete(_ step: String, of rename: PendingRename, secrets: EnvSecrets) async -> Bool {
        switch step {
        case "keychain":
            let key = "\(rename.from)>\(rename.to)"
            guard !renameKeychainFailed.contains(key) else { return false }
            let result = await Task.detached { Result { try secrets.move(site: rename.from, to: rename.to) } }.value
            guard case .success = result else {
                renameKeychainFailed.insert(key)
                errorMessage = String(format: L("rename.keychainPending"), rename.to)
                return false
            }
            await loadEnvs(rename.to)
            return true
        case "vault":
            let vault = VaultSession.shared
            guard vault.isUnlocked else { return false }
            return (try? vault.relinkProject(from: rename.from, to: rename.to)) != nil
        case "app":
            renamePreferences(from: rename.from, to: rename.to)
            return true
        default:
            return false
        }
    }

    /// What this Mac keeps under a project's id: favorite of the menu bar panel, last branch seen,
    /// the page open and what is shown of it until the next refresh.
    func renamePreferences(from: String, to: String) {
        if favoriteSites.remove(from) != nil { favoriteSites.insert(to) }
        if !StackStore.qaWindow {
            let defaults = UserDefaults.standard
            if let head = defaults.string(forKey: "git.head.\(from)") {
                defaults.set(head, forKey: "git.head.\(to)")
                defaults.removeObject(forKey: "git.head.\(from)")
            }
        }
        envs[from] = nil; git[from] = nil; worktrees[from] = nil; branchNotices[from] = nil; siteHealth[from] = nil
        if selectedSite == from { selectedSite = to }
        if route == .site(from) { route = .site(to) }
    }

    /// «Cambiar carpeta…»: the project points at another folder; no file is moved or copied.
    func changeFolder(_ project: Project) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        let near = URL(fileURLWithPath: project.path).deletingLastPathComponent()
        panel.directoryURL = FileManager.default.fileExists(atPath: near.path) ? near : Folder.ensureProjects()
        panel.prompt = L("move.prompt")
        panel.message = String(format: L("move.message"), project.title)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await moveProject(project, to: url.path) }
    }

    func moveProject(_ project: Project, to path: String) async {
        var moved: MovedProject?
        await run(L("busy.saving"), refresh: true) {
            moved = try await self.call(["method": "moveProject", "id": project.id, "path": path])
        }
        guard let moved else { return }
        openSite(moved.project.id)
        if moved.envReapply, let env = activeEnvironment(project.id) {
            notify(String(format: L("move.envReapply"), env.title))
        } else {
            notify(L("move.done"))
        }
    }

    /// `butakestack://project/rename?id=<id>[&newId=<nuevo>]`: the rename sheet, filled in, for the
    /// user to review and confirm. A link never renames by itself.
    func handleProjectLink(_ url: URL) {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let value = { (name: String) in items.first { $0.name == name }?.value }
        guard url.path == "/rename", let project = projects.first(where: { $0.id == value("id") }) else { return }
        openSite(project.id)
        renaming = RenameRequest(project: project, proposedId: value("newId").map(StackStore.slug))
    }
}
