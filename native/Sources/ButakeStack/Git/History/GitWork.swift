import Foundation

/// Actions of Historial and Problemas waiting for the user (a confirmation, a name or a sheet),
/// wherever they were asked: a commit's menu, its detail, a problem's button. The lists of both
/// tabs show them (`gitWorkDialogs`), so each one exists once.
@MainActor @Observable final class GitWork {
    static let shared = GitWork()
    var reverting: GitCommitSummary?
    var copying: GitCopyRequest?
    var naming: GitNameRequest?
    var organizing = false
    var syncingBranches = false
    var more = false
    /// The list «Más…» opens on.
    var moreSection: GitMoreSection = .stashes
    var resolving = false
    var identity = false
    var aborting = false
    /// Big files waiting for «Dejar fuera e ignorar» to be confirmed.
    var ignoring: [String]?
}

/// «Copiar a otra rama»: the commits (newest first) and the branch that receives them.
struct GitCopyRequest: Identifiable, Equatable {
    var hashes: [String]
    var title: String
    var target: String
    var id: String { target + hashes.joined() }
}

/// «Crear rama desde aquí…» or «Etiquetar…» on a commit.
struct GitNameRequest: Identifiable, Equatable {
    enum Kind { case branch, tag }
    var kind: Kind
    var commit: GitCommitSummary
    var id: String { "\(kind)-\(commit.hash)" }
}
