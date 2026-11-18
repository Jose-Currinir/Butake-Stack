import Foundation

/// The symbols of the Git tool's screens (the pieces keep theirs in `Pieces/GitSymbols.swift`).
extension Symbols {
    /// Brings the remote's commits.
    static let gitPull = "arrow.down.circle"
    /// Sends this branch's commits.
    static let gitPush = "arrow.up.circle"
    /// Records the included changes as a commit.
    static let gitCommit = "checkmark.circle"
    /// Takes back the last commit, keeping its changes.
    static let gitUndoCommit = "arrow.uturn.backward"
    /// A new branch from the current one.
    static let gitNewBranch = "arrow.branch"
    /// Joins another branch into the current one.
    static let gitMerge = "arrow.triangle.merge"
    /// Throws away changes of the working folder.
    static let gitDiscard = "arrow.uturn.backward.circle.fill"
    /// Changes shown as a flat list.
    static let gitListView = "list.bullet"
    /// Changes shown as folders.
    static let gitTreeView = "list.triangle"
    /// The dictionary of Git's commands and words.
    static let gitDictionary = "character.book.closed"
    /// The tabs of the tool.
    static let gitChanges = "doc.badge.ellipsis"
    static let gitHistory = "clock"
    static let gitPullRequests = "arrow.triangle.pull"
    static let gitProblems = "exclamationmark.bubble.fill"
}
