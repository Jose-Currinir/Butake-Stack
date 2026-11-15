import AppKit
import SwiftUI

extension StackStore {
    // MARK: Git (read-only): branch, pending changes, worktrees and branch switches
    func refreshGit() async {
        guard let value: [String: GitInfo] = try? await call(["method": "gitStatus"]), !Task.isCancelled else { return }
        if git != value { git = value }
        let defaults = UserDefaults.standard
        for (id, info) in value where !info.head.isEmpty {
            let key = "git.head.\(id)"
            let seen = defaults.string(forKey: key)
            if seen != info.head { defaults.set(info.head, forKey: key) }
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
}
