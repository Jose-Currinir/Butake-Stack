import Foundation

/// An engine action of the Git tool (`gitAction`): the engine's name and how the app runs it.
/// Network transfers can be stopped («Cancelar»); local writes always finish.
enum GitAction: String, Sendable, CaseIterable {
    case stage, unstage, commit, fetch, pull, push, discard, merge, rebase, stash
    case pullMerge = "pull_merge", pullRebase = "pull_rebase", pullAutostash = "pull_autostash"
    case createBranch = "create_branch", switchBranch = "switch_branch", trackBranch = "track_branch"
    case renameBranch = "rename_branch", deleteBranch = "delete_branch", forceDeleteBranch = "force_delete_branch"
    case commitAmend = "commit_amend", undoCommit = "undo_commit", rebaseAbort = "rebase_abort", stashPop = "stash_pop"
    // Historial, Problemas and «Más…» (G-3).
    case revert, cherryPick = "cherry_pick", continueOperation = "continue_operation", abortOperation = "abort_operation"
    case createBranchAt = "create_branch_at", createTag = "create_tag", deleteTag = "delete_tag"
    case stashApply = "stash_apply", stashDrop = "stash_drop", addRemote = "add_remote", removeRemote = "remove_remote"
    case setIdentity = "set_identity", setGlobalIdentity = "set_global_identity", ignorePath = "ignore_path"
    // «Más…» › Carpetas de trabajo (G-5).
    case addWorktree = "add_worktree", removeWorktree = "remove_worktree"

    /// Talks to the remote: runs as a stoppable call and shows «Cancelar».
    var network: Bool { [.fetch, .pull, .pullMerge, .pullRebase, .pullAutostash, .push].contains(self) }
    /// The engine wants `confirmed`: the user already chose it (a button that names its scope, a
    /// dialog or the pull assistant).
    var needsConfirmation: Bool {
        [.push, .pull, .pullMerge, .pullRebase, .pullAutostash, .merge, .rebase, .rebaseAbort, .stashPop, .discard,
         .deleteBranch, .forceDeleteBranch, .revert, .cherryPick, .abortOperation, .deleteTag, .stashApply, .stashDrop,
         .removeRemote, .removeWorktree].contains(self)
    }
    /// What the button says while it runs («Bajando cambios…»).
    var progressTitle: String { L("git.progress.\(rawValue)") }
    /// What the toast says when it is done.
    var doneTitle: String { L("git.done.\(rawValue)") }
}

/// The operation running in the open repository: one at a time (mutations are serialized), with its
/// title for the primary button and, for a network transfer, the task «Cancelar» stops.
struct GitOperation: Identifiable, Sendable {
    let id = UUID()
    let title: String
    let cancellable: Bool
}
