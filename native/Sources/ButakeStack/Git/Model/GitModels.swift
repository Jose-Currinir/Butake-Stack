import Foundation

// The answers of the engine's `git*` methods (engine/src/git/status.rs and repositories.rs), as
// the Git tool reads them. Field names follow the engine's JSON.

/// One changed file of `gitChanges` / `gitSnapshot`: Git's two status columns.
struct GitFile: Decodable, Hashable, Sendable, Identifiable {
    var path: String
    var originalPath: String?
    var index: String
    var worktree: String
    var id: String { path }

    /// Unmerged entry: any `U`, or both sides added or deleted.
    var conflicted: Bool { index == "U" || worktree == "U" || (index == "A" && worktree == "A") || (index == "D" && worktree == "D") }
    /// Part of it is staged (goes into the next commit).
    var hasStaged: Bool { !conflicted && index != " " && index != "?" }
    /// Part of it is not staged yet (an untracked file is all unstaged).
    var hasUnstaged: Bool { !conflicted && (worktree != " " || index == "?") }
    var untracked: Bool { index == "?" }
    var kind: GitChangeKind { .status(index: index.first ?? " ", worktree: worktree.first ?? " ") }
    /// Checkbox of the file: staged whole, in part, or not at all.
    var inclusion: GitInclusion { hasStaged ? (hasUnstaged ? .partial : .full) : .none }
    /// New since the last commit, staged when created and edited afterwards: its unstaged patch alone
    /// reads as an edit, so that side shows the whole new file.
    var newInParts: Bool { index == "A" && worktree == "M" }
}

struct GitCommitSummary: Decodable, Hashable, Sendable, Identifiable {
    var hash: String
    var parents: [String]
    var author: String
    /// Seconds since 1970 (UTC), as text.
    var timestamp: String
    var subject: String
    var refs: String
    var id: String { hash }
    var date: Date? { Double(timestamp).map(Date.init(timeIntervalSince1970:)) }
}

struct GitBranch: Decodable, Hashable, Sendable, Identifiable {
    var name: String
    var current: Bool
    var upstream: String
    var ahead: Int
    var behind: Int
    /// Its upstream was deleted on the remote.
    var gone: Bool
    /// Last commit (seconds since 1970, UTC).
    var updated: Int
    var id: String { name }
}

struct GitRemoteBranch: Decodable, Hashable, Sendable, Identifiable {
    /// `origin/feature/x`
    var name: String
    var remote: String
    /// `feature/x`
    var short: String
    var updated: Int
    var id: String { name }
}

/// The state of an open repository (`gitOpen` / `gitSnapshot`).
struct GitSnapshot: Decodable, Equatable, Sendable {
    var root: String
    /// Current branch; "HEAD" when detached.
    var branch: String
    var files: [GitFile]
    var commits: [GitCommitSummary]
    var branches: [GitBranch]
    /// "rebase", "merge", "cherry-pick", "revert" or empty.
    var operation: String
    var ahead: Int
    var behind: Int
    /// URL of `origin`, without credentials.
    var remote: String
    var mainProtected: Bool
    var primaryBranch: String
    var remoteBranches: [GitRemoteBranch]
    var remotes: [String]

    var detached: Bool { branch == "HEAD" }
    var hasRemote: Bool { !remotes.isEmpty }
    var currentBranch: GitBranch? { branches.first { $0.current } }
    /// The current branch has an upstream on the remote (and it still exists).
    var tracked: Bool { currentBranch.map { !$0.upstream.isEmpty && !$0.gone } ?? false }
    var onProtectedMain: Bool { mainProtected && branch == primaryBranch }
    /// The checked-out commit (the history mixes every branch; HEAD's refs say "HEAD").
    var headCommit: GitCommitSummary? { commits.first { $0.refs == "HEAD" || $0.refs.hasPrefix("HEAD ") || $0.refs.hasPrefix("HEAD,") } }
    var name: String { (root as NSString).lastPathComponent }
}

/// Added and removed lines of one side of a file (`gitStats`).
struct GitFileStat: Decodable, Sendable {
    var path: String
    var staged: Bool
    var additions: Int?
    var deletions: Int?
}

/// `gitRepositories`: Stack's projects with a repository, the ones added by hand and the recent ones.
struct GitRepositoryList: Decodable, Equatable, Sendable {
    struct Project: Decodable, Equatable, Sendable { var id: String; var name: String; var path: String }
    struct Saved: Decodable, Equatable, Sendable { var path: String; var name: String; var at: Int; var missing: Bool }
    var projects: [Project] = []
    var added: [Saved] = []
    var recent: [Saved] = []
}

/// `gitCapabilities`: only the version matters to the tool.
struct GitCapabilities: Decodable, Sendable {
    var version: String
}

/// `gitBranchDetails`: a branch against another one (the current branch).
struct GitBranchComparison: Decodable, Sendable {
    struct Author: Decodable, Sendable, Hashable { var name: String; var count: Int }
    struct File: Decodable, Sendable, Hashable { var path: String; var additions: Int?; var deletions: Int? }
    var name: String
    var base: String
    var ahead: Int
    var behind: Int
    var upstream: String
    var authors: [Author]
    var files: [File]
}
