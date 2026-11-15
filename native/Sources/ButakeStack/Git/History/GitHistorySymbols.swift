import Foundation

/// The symbols of Historial, Problemas, conflicts, «Organizar commits», «Sincronizar ramas» and
/// «Más…», one per concept (the rest come from `Symbols`).
extension Symbols {
    /// A new commit that undoes another one.
    static let gitRevert = "arrow.uturn.backward.square"
    /// Copies commits to another branch.
    static let gitCopyCommits = "arrow.right.doc.on.clipboard"
    /// Reorders, combines, renames or removes unpublished commits.
    static let gitOrganize = "rectangle.stack"
    /// What each of two branches has that the other lacks.
    static let gitSyncBranches = "arrow.left.and.right.square"
    /// Resolves files in conflict.
    static let gitResolve = "checkmark.rectangle.stack"
    /// Finishes an operation left halfway.
    static let gitContinue = "arrow.forward.circle"
    /// Cancels an operation left halfway.
    static let gitAbort = "stop.circle"
    /// Changes kept aside for later.
    static let gitStash = "tray.and.arrow.down"
    /// Other working folders of the same repository.
    static let gitWorktree = "rectangle.on.rectangle"
    /// More commits at the end of the list.
    static let gitLoadMore = "chevron.down.circle"
    /// Moves a commit up or down in «Organizar commits».
    static let gitMoveUp = "chevron.up"
    static let gitMoveDown = "chevron.down"
    /// Joins commits into one, or splits them again.
    static let gitCombine = "arrow.down.right.and.arrow.up.left"
    static let gitSplit = "arrow.up.left.and.arrow.down.right"
    /// The remote can't be reached.
    static let gitOffline = "wifi.exclamationmark"
    /// The branch is not on the remote.
    static let gitNotPublished = "icloud.slash"
    /// Both the branch and the remote moved.
    static let gitDiverged = "arrow.up.arrow.down"
}
