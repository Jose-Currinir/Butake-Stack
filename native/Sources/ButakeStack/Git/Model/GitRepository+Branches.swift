import Foundation

/// What Ramas and the branch menu of the toolbar ask for. The confirmations (switching with
/// changes, deleting, combining) live in the views; these run what was confirmed.
extension GitRepository {
    var localBranches: [GitBranch] { snapshot.branches.sorted { ($0.current ? 0 : 1, $0.name.lowercased()) < ($1.current ? 0 : 1, $1.name.lowercased()) } }
    /// Remote branches without a local branch of the same name (those are already listed).
    var remoteOnlyBranches: [GitRemoteBranch] {
        let local = Set(snapshot.branches.map(\.name))
        return snapshot.remoteBranches.filter { !local.contains($0.short) }.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    /// The primary branch is protected here: it can't be renamed or deleted from the tool.
    func isProtected(_ branch: String) -> Bool { branch == snapshot.primaryBranch }

    func createBranch(_ name: String) async -> Bool {
        await perform(.createBranch, value: name.trimmingCharacters(in: .whitespaces))
    }

    /// Switches to a local branch, or to a local copy that follows a remote one.
    func switchTo(_ name: String) async {
        if snapshot.branches.contains(where: { $0.name == name }) {
            await perform(.switchBranch, value: name)
        } else if let remote = snapshot.remoteBranches.first(where: { $0.name == name }) {
            await perform(.trackBranch, value: remote.name)
        }
    }

    func renameBranch(_ old: String, to new: String) async -> Bool {
        await perform(.renameBranch, value: "\(old):\(new.trimmingCharacters(in: .whitespaces))")
    }

    /// Deletes a merged branch; one with commits nowhere else asks again before forcing it.
    func deleteBranch(_ name: String, force: Bool) async -> GitDeleteResult {
        guard operation == nil else { return .failed }
        let ok = await perform(force ? .forceDeleteBranch : .deleteBranch, value: name)
        if ok {
            if selectedBranch == name { selectedBranch = nil }
            return .deleted
        }
        if failure?.code == "branch_not_merged" {
            failure = nil
            return .notMerged
        }
        return .failed
    }

    func merge(_ name: String) async { await perform(.merge, value: name) }

    // MARK: After a merged pull request

    /// Where to go back after a merged branch: develop when the repository has it (here or on the
    /// remote), otherwise the primary branch.
    var landingBranch: String {
        let names = Set(snapshot.branches.map(\.name)).union(snapshot.remoteBranches.map(\.short))
        return names.contains("develop") ? "develop" : snapshot.primaryBranch
    }

    /// Branches other than the current one whose pull request was merged and whose remote branch
    /// was deleted: they are only left on this Mac.
    var mergedGoneBranches: [GitBranch] { localBranches.filter { !$0.current && $0.mergedAndGone && !isProtected($0.name) } }

    /// «Volver a develop y borrar la rama»: the current branch was merged on the provider and its
    /// remote branch deleted. Goes to `landingBranch`, brings it up to date and deletes the branch
    /// (the engine checks again that all its commits are on the remote). Only with no changes.
    func leaveMergedBranch() async {
        guard operation == nil, files.isEmpty, let current = snapshot.currentBranch, current.mergedAndGone else { return }
        let target = landingBranch
        guard target != current.name else { return }
        await switchTo(target)
        guard snapshot.branch == target else { return }
        if snapshot.tracked {
            guard await perform(.pull, notify: false) else { return }
        }
        guard await perform(.deleteMergedBranch, value: current.name, notify: false) else { return }
        if selectedBranch == current.name { selectedBranch = nil }
        store.notify(String(format: L("git.branch.leftMerged"), target, current.name))
    }

    /// «Borrar de este Mac» for every `mergedGoneBranches`: one that is not all on the remote any
    /// more (a commit added meanwhile) stays, with the engine's reason.
    func deleteMergedBranches() async {
        var deleted = 0
        for branch in mergedGoneBranches {
            if await perform(.deleteMergedBranch, value: branch.name, notify: false) {
                deleted += 1
                if selectedBranch == branch.name { selectedBranch = nil }
            } else {
                break
            }
        }
        guard deleted > 0 else { return }
        store.notify(deleted == 1 ? L("git.done.delete_merged_branch") : String(format: L("git.done.deleteMergedBranches"), deleted))
    }

    /// The selected branch against the current one (`gitBranchDetails`).
    func comparison(of branch: String) async -> GitBranchComparison? {
        guard branch != snapshot.branch, !snapshot.detached else { return nil }
        return try? await store.call(["method": "gitBranchDetails", "path": root, "branch": branch, "base": snapshot.branch])
    }
}

enum GitDeleteResult { case deleted, notMerged, failed }
