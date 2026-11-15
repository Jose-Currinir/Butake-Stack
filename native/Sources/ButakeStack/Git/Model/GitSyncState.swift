import Foundation

/// The primary sync button of the toolbar: one button whose title says the state and the count
/// (DISENO.md, «Botón principal de sincronización»). A pure rule over the snapshot, so every state
/// is tested without a window.
enum GitSyncState: Equatable, Sendable {
    /// A Git operation of this tool is running (its title, and whether «Cancelar» stops it).
    case running(title: String, cancellable: Bool)
    /// A merge, rebase or copy was left halfway: «Continuar…» leads to Problemas.
    case unfinished(operation: String)
    /// The repository has no remote: «Publicar repositorio…» (G-4, see `GitHooks.publishRepository`).
    case publishRepository
    /// The branch exists only here: «Publicar rama» pushes it with its upstream.
    case publishBranch
    /// Commits to bring; `thenPush` commits to send right after (both sides moved).
    case pull(count: Int, thenPush: Int)
    case push(count: Int)
    /// Up to date: «Actualizar» asks the remote, with when it was last asked.
    case fetch(last: Date?)

    static func of(_ snapshot: GitSnapshot, running: GitOperation?, lastFetch: Date?) -> GitSyncState {
        if let running { return .running(title: running.title, cancellable: running.cancellable) }
        if !snapshot.operation.isEmpty { return .unfinished(operation: snapshot.operation) }
        if !snapshot.hasRemote { return .publishRepository }
        // A detached HEAD has nothing to publish or pull: it can only ask the remote.
        if snapshot.detached { return .fetch(last: lastFetch) }
        if !snapshot.tracked { return .publishBranch }
        if snapshot.behind > 0 { return .pull(count: snapshot.behind, thenPush: snapshot.ahead) }
        if snapshot.ahead > 0 { return .push(count: snapshot.ahead) }
        return .fetch(last: lastFetch)
    }

    var title: String {
        switch self {
        case .running(let title, _): title
        case .unfinished: L("git.sync.continue")
        case .publishRepository: L("git.sync.publishRepository")
        case .publishBranch: L("git.sync.publishBranch")
        case .pull(let count, _): String(format: L("git.sync.pull"), count)
        case .push(let count): String(format: L("git.sync.push"), count)
        case .fetch: L("git.sync.fetch")
        }
    }

    var symbol: String {
        switch self {
        case .running: Symbols.reload
        case .unfinished: Symbols.warning
        case .publishRepository, .publishBranch, .push: Symbols.gitPush
        case .pull: Symbols.gitPull
        case .fetch: Symbols.reload
        }
    }

    /// What the button does, said in its tooltip.
    var help: String {
        switch self {
        case .running: L("git.sync.runningHelp")
        case .unfinished(let operation): String(format: L("git.sync.continueHelp"), L("git.operation.\(operation)"))
        case .publishRepository: L("git.sync.publishRepositoryHelp")
        case .publishBranch: L("git.sync.publishBranchHelp")
        case .pull(_, let thenPush): thenPush > 0 ? String(format: L("git.sync.pullThenPushHelp"), thenPush) : L("git.sync.pullHelp")
        case .push: L("git.sync.pushHelp")
        case .fetch(let last):
            last.map { String(format: L("git.sync.fetchedAgo"), $0.formatted(.relative(presentation: .named))) } ?? L("git.sync.fetchHelp")
        }
    }

    /// The button's identifier names its state (`git.sync.pull`…), for QA and for assistive tools.
    var identifier: String {
        switch self {
        case .running: "git.sync.running"
        case .unfinished: "git.sync.continue"
        case .publishRepository: "git.sync.publishRepository"
        case .publishBranch: "git.sync.publishBranch"
        case .pull: "git.sync.pull"
        case .push: "git.sync.push"
        case .fetch: "git.sync.fetch"
        }
    }
}
