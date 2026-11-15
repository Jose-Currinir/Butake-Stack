#if DEBUG
import Foundation

/// The steps of Historial, Problemas and their sheets for the Git QA script (`GitQA`), run
/// through the same models the buttons use:
///
///     onlyBranch:<0|1> (the list keeps its own preference: launch with `-git.history.onlyBranch NO`)
///      search:<ámbito>:<texto>  pick:<n>  problem:<id>  problemAction:<id>
///     resolve  organize  organizeCombine:<n>  organizeApply  undoRewrite  syncBranches
///     more:<sección>  identity  continue  abort  revert:<n>  tag:<nombre>:<n>  branchAt:<nombre>:<n>
///
/// Each step reports Historial and Problemas after the general line.
@MainActor enum GitHistoryQA {
    static let organizeNote = Notification.Name("git.qa.organize")
    /// The section «Más…» opens on.
    static var moreSection: GitMoreSection?

    /// Runs `step` when it is one of these; false otherwise.
    static func run(_ name: String, _ argument: String, _ repository: GitRepository) async -> Bool {
        let history = repository.history
        let work = GitWork.shared
        func commit(_ text: String) -> GitCommitSummary? { history.commits[safe: Int(text) ?? 0] }
        switch name {
        case "onlyBranch":
            history.onlyBranch = argument != "0"
            await history.reloadBranch()
        case "search":
            let parts = argument.split(separator: ":", maxSplits: 1).map(String.init)
            history.scope = GitHistorySearchScope(rawValue: parts.first ?? "") ?? .message
            history.search = parts.count > 1 ? parts[1] : ""
            await history.runSearch()
        case "pick": history.selected = commit(argument)?.hash
        case "problem": GitProblemSelection.shared.id = argument
        case "problemAction":
            let problem = GitProblemSources.shared.problems(for: repository).first { $0.id == argument }
            await problem?.action?.run()
        case "resolve": work.resolving = true
        case "organize": work.organizing = true
        case "organizeCombine":
            try? await Task.sleep(for: .seconds(1))
            NotificationCenter.default.post(name: organizeNote, object: "combine:\(argument)")
        case "organizeApply":
            NotificationCenter.default.post(name: organizeNote, object: "apply")
            for _ in 0..<40 where repository.busy || work.organizing { try? await Task.sleep(for: .milliseconds(250)) }
        case "undoRewrite": await repository.undoRewrite()
        case "syncBranches": work.syncingBranches = true
        case "more":
            moreSection = GitMoreSection(rawValue: argument)
            work.more = true
        case "identity": work.identity = true
        case "continue": await repository.continueOperation()
        case "abort": await repository.abortOperation()
        case "revert": if let target = commit(argument) { await repository.perform(.revert, value: target.hash) }
        case "tag", "branchAt":
            let parts = argument.split(separator: ":").map(String.init)
            if parts.count == 2, let target = commit(parts[1]) {
                await repository.perform(name == "tag" ? .createTag : .createBranchAt, value: "\(parts[0]):\(target.hash)")
            }
        default: return false
        }
        return true
    }

    static func report(_ repository: GitRepository) -> String {
        let history = repository.history
        let problems = GitProblemSources.shared.problems(for: repository).map(\.id).joined(separator: ",")
        let shown = history.matches.map { "\($0.count) líneas" } ?? "\(history.commits.count) commits"
        return "QA git historial: \(shown) búsqueda=\(history.scope.rawValue):\(history.search) "
            + "seleccionado=\(history.selectedCommit?.subject ?? "-") respaldo=\(history.lastBackup == nil ? "no" : "sí") problemas=[\(problems)]\n"
    }
}
#endif
