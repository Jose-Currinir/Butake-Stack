import Foundation

/// A place a skill found by `skillsImportScan` lives: the folder of an assistant, as a real folder or a link.
struct ImportSource: Decodable, Hashable, Sendable {
    let agent: String
    let path: String
    /// "folder" or "link".
    let kind: String

    var isLink: Bool { kind == "link" }
}

/// One skill found in the folders of the assistants (`skillsImportScan`). Entries with the same real
/// folder or the same bytes are one candidate with several sources; the same name with different
/// content is `identical == false` and the user picks the source to copy.
struct ImportCandidate: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let description: String
    let sources: [ImportSource]
    let identical: Bool
    let valid: Bool
    let reason: String?
    let hidden: Bool

    /// Offered checked: valid and not hidden.
    var preselected: Bool { valid && !hidden }
}

/// `skillsImportPlan`: what the import does. `replace` is every source that becomes a link to Stack's
/// copy: `trash` the real folders (moved to the import trash), `unlink` the links of other origin
/// (only the link goes). `conflicts` stay as they are.
struct ImportPlan: Decodable, Sendable {
    struct Copy: Decodable, Hashable, Sendable { let from: String; let id: String }
    let copy: [Copy]
    let replace: [String]
    let trash: [String]
    let unlink: [String]
    let conflicts: [SkillLinkPlan.Conflict]
}

/// `skillsImportApply`.
struct ImportResult: Decodable, Sendable {
    let imported: [Skill]
    let conflicts: [SkillLinkPlan.Conflict]
}

/// An entry of the import trash (`skillsImportTrashList`).
struct ImportTrashEntry: Decodable, Identifiable, Hashable, Sendable {
    let trashId: String
    let id: String
    let created: Int
    let path: String
    let sources: [ImportSource]

    var createdDate: Date { Date(timeIntervalSince1970: TimeInterval(created)) }
}

/// `skillsImportUndo` with `plan`: the folders that come back, the links of other origin that are
/// put back, the links to Stack's copy that go, and Stack's copy, which goes to the skills trash.
struct ImportUndoPlan: Decodable, Sendable {
    struct Restore: Decodable, Hashable, Sendable { let from: String; let to: String }
    struct Relink: Decodable, Hashable, Sendable { let path: String; let target: String }
    let restore: [Restore]
    let relink: [Relink]
    let remove: [String]
    let trash: [String]
    let conflicts: [SkillLinkPlan.Conflict]
}

/// `skillsImportTrashEmpty` with `plan`: the folders it removes for good.
struct ImportEmptyPlan: Decodable, Sendable {
    let delete: [String]
}

/// What the import trash asks the user to confirm.
enum ImportConfirmation: Identifiable, Hashable, Sendable {
    case undo(ImportTrashEntry)
    case empty([ImportTrashEntry])

    var id: String {
        switch self {
        case .undo(let entry): "undo.\(entry.trashId)"
        case .empty: "empty"
        }
    }
}
