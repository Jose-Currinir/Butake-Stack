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

    /// The selected branch against the current one (`gitBranchDetails`).
    func comparison(of branch: String) async -> GitBranchComparison? {
        guard branch != snapshot.branch, !snapshot.detached else { return nil }
        return try? await store.call(["method": "gitBranchDetails", "path": root, "branch": branch, "base": snapshot.branch])
    }
}

enum GitDeleteResult { case deleted, notMerged, failed }
