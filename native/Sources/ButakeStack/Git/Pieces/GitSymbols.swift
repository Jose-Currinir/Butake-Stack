import Foundation

/// The symbols of the Git pieces, one per concept like the rest of `Symbols`.
extension Symbols {
    /// What happened to a file: added, modified, deleted or moved (a conflict is `Symbols.warning`).
    static let changeAdded = "plus.circle.fill"
    static let changeModified = "pencil.circle.fill"
    static let changeDeleted = "minus.circle.fill"
    static let changeMoved = "arrow.right.circle.fill"
    /// Puts one block of a diff into the commit.
    static let stageHunk = "text.append"
    /// A file whose content is not text.
    static let binaryFile = "doc.badge.gearshape"
    /// An image shown before and after the change.
    static let imageFile = "photo"
    /// A diff too large to show at once.
    static let largeDiff = "scalemass"
    /// A file with nothing to compare.
    static let noChanges = "equal.circle"
}
