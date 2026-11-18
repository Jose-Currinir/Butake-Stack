import Foundation

/// What happened to a file.
enum GitChangeKind: String, CaseIterable, Identifiable, Sendable {
    case added, modified, deleted, moved, conflict
    var id: String { rawValue }
    var title: String { L("git.kind.\(rawValue)") }
    var symbol: String {
        switch self {
        case .added: Symbols.changeAdded
        case .modified: Symbols.changeModified
        case .deleted: Symbols.changeDeleted
        case .moved: Symbols.changeMoved
        case .conflict: Symbols.warning
        }
    }

    /// The kind of a `git status --porcelain` entry: its index and work tree columns.
    static func status(index: Character, worktree: Character) -> GitChangeKind {
        let conflicted: Set<String> = ["DD", "AU", "UD", "UA", "DU", "AA", "UU"]
        if conflicted.contains(String([index, worktree])) { return .conflict }
        if index == "R" || worktree == "R" || index == "C" { return .moved }
        if index == "?" || index == "A" { return worktree == "D" ? .deleted : .added }
        if index == "D" || worktree == "D" { return .deleted }
        return .modified
    }

    /// The kind of a `--name-status` letter (A, M, D, R…, C…, U).
    static func nameStatus(_ code: String) -> GitChangeKind {
        switch code.prefix(1) {
        case "A": .added
        case "D": .deleted
        case "R", "C": .moved
        case "U": .conflict
        default: .modified
        }
    }
}

/// Lines added and removed in a file; both nil for a binary file.
struct GitLineStats: Equatable, Hashable, Sendable {
    var additions: Int?
    var deletions: Int?
    init(additions: Int? = nil, deletions: Int? = nil) { self.additions = additions; self.deletions = deletions }
    var binary: Bool { additions == nil && deletions == nil }
    var isEmpty: Bool { (additions ?? 0) + (deletions ?? 0) == 0 }

    /// Parses `git diff --numstat -z --no-renames`: entries `added\tdeleted\tpath\0`, `-` for binary.
    static func parseNumstat(_ text: String) -> [(path: String, stats: GitLineStats)] {
        text.split(separator: "\0", omittingEmptySubsequences: true).compactMap { entry in
            let fields = entry.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3 else { return nil }
            return (String(fields[2]).trimmingCharacters(in: .newlines), GitLineStats(additions: Int(fields[0]), deletions: Int(fields[1])))
        }
    }
}

/// How much of a file goes into the next commit.
enum GitInclusion: Sendable, Hashable {
    case none, partial, full
}

/// One changed file, as the change tree receives it.
struct GitChange: Identifiable, Hashable, Sendable {
    var path: String
    var kind: GitChangeKind
    /// Previous path of a moved file.
    var originalPath: String?
    var stats: GitLineStats
    var inclusion: GitInclusion

    init(path: String, kind: GitChangeKind = .modified, originalPath: String? = nil, stats: GitLineStats = GitLineStats(), inclusion: GitInclusion = .none) {
        self.path = path; self.kind = kind; self.originalPath = originalPath; self.stats = stats; self.inclusion = inclusion
    }

    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
    var directory: String { (path as NSString).deletingLastPathComponent }
    var isConflict: Bool { kind == .conflict }
}
