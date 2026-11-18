import AppKit
import Foundation

/// What Historial, Problemas and their sheets ask of the repository beyond `perform`: copying
/// commits to another branch, reorganizing and undoing it, finishing or cancelling an operation.
extension GitRepository {
    /// Copies commits (newest first, as the list shows them) onto `target` and comes back.
    @discardableResult
    func copyCommits(_ hashes: [String], to target: String) async -> Bool {
        let request: [String: Any] = ["method": "gitCopyCommits", "target": target, "hashes": hashes, "confirmed": true]
        switch await run(L("git.progress.copyCommits"), request, as: Int.self) {
        case .success(let count):
            store.notify(String(format: L("git.done.copyCommits"), count, target))
            return true
        case .failure(let failure):
            report(failure)
            return false
        }
    }

    /// Applies a plan of «Organizar commits». A collision leaves the reorganization halfway (its
    /// backup is kept so it can still be undone) and the conflicts in Problemas.
    func applyRewrite(_ plan: GitRewritePlan, branch: String) async -> Bool {
        let request: [String: Any] = ["method": "gitRewriteApply", "plan": plan.json, "confirmed": true]
        switch await run(L("git.progress.rewrite"), request, done: L("git.done.rewrite"), as: GitRewriteResult.self) {
        case .success(let result):
            history.lastBackup = GitRewriteBackup(reference: result.backup, branch: branch)
            return true
        case .failure(let failure):
            if failure.code == "rewrite_conflicts", let range = failure.detail.range(of: #"refs/butake/backup/\S+"#, options: .regularExpression) {
                history.lastBackup = GitRewriteBackup(reference: String(failure.detail[range]), branch: branch)
                GitTool.shared.tab = .problems
            }
            report(failure)
            return false
        }
    }

    /// «Deshacer» of the last reorganization: the branch goes back to its copy (and a reorganization
    /// left halfway is cancelled first).
    func undoRewrite() async {
        guard let backup = history.lastBackup else { return }
        if snapshot.operation == "rebase" { guard await perform(.rebaseAbort, notify: false) else { return } }
        let request: [String: Any] = ["method": "gitRewriteUndo", "backup": backup.reference, "confirmed": true]
        switch await run(L("git.progress.rewriteUndo"), request, done: L("git.done.rewriteUndo"), as: String.self) {
        case .success: history.lastBackup = nil
        case .failure(let failure): report(failure)
        }
    }

    /// «Continuar» of an operation halfway (a reorganization stays undoable afterwards).
    func continueOperation() async { await perform(.continueOperation) }

    /// «Cancelar la operación», confirmed: back to before it started.
    func abortOperation() async {
        let wasRewrite = snapshot.operation == "rebase" && history.lastBackup != nil
        if await perform(.abortOperation), wasRewrite { history.lastBackup = nil }
    }

    /// Puts a commit's identifier on the pasteboard.
    func copyIdentifier(_ hash: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(hash, forType: .string)
        store.notify(L("git.history.copied"))
    }
}

/// The answer of `gitRewriteApply`.
struct GitRewriteResult: Decodable, Sendable {
    var backup: String
    var head: String
}

/// A plan of «Organizar commits» for the engine: the steps oldest first, each with its commits.
struct GitRewritePlan: Sendable {
    struct Step: Sendable {
        var hashes: [String]
        var drop: Bool
        var message: String?
    }
    var head: String
    var base: String
    var steps: [Step]

    var json: [String: Any] {
        ["head": head, "base": base, "steps": steps.map { step -> [String: Any] in
            var value: [String: Any] = ["hashes": step.hashes, "drop": step.drop]
            if let message = step.message { value["message"] = message }
            return value
        }]
    }
}
