import Foundation

/// The symbols of the providers' screens (accounts, pull requests, clone, create, publish).
extension Symbols {
    /// The accounts of GitHub and Bitbucket (a tab of Ajustes).
    static let gitAccounts = "person.2.crop.square.stack"
    /// Brings a repository of a provider to this Mac.
    static let gitClone = "laptopcomputer.and.arrow.down"
    /// A new repository in a folder of this Mac.
    static let gitCreateRepository = "plus.rectangle.on.folder"
    /// Puts a repository of this Mac on a provider.
    static let gitPublishRepository = "icloud.and.arrow.up"
    /// Opens a new pull request from the current branch.
    static let gitNewPullRequest = "plus.bubble"
    static let gitApprove = "hand.thumbsup"
    static let gitComment = "text.bubble"
    /// The states of a check.
    static let gitCheckFailed = "xmark.circle.fill"
    static let gitCheckRunning = "hourglass.circle"
    static let gitCheckSkipped = "slash.circle"
    /// A pull request that is still a draft, and one that was closed without joining.
    static let gitDraft = "pencil.circle"
    static let gitClosed = "xmark.circle"
    /// Someone asked for changes in a review.
    static let gitChangesRequested = "exclamationmark.circle"
}
