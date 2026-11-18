#if DEBUG
import AppKit
import Foundation

/// The Git tool driven without clicks (debug builds with BUTAKE_QA_WINDOW and a separate
/// BUTAKE_STACK_HOME): screenshots and the end-to-end check run against repositories made for the
/// occasion, with a local bare remote, a temporary HOME and Git configuration. Each step goes
/// through the same model the buttons use (`GitRepository`), so what works here works there.
///
///     BUTAKE_QA_GIT_REQUIREMENT=missing|outdated   Git as if it were missing or too old
///     BUTAKE_QA_GIT_COMMIT=<texto>                 the commit box's summary, already written
///     BUTAKE_QA_GIT_PULL=<acción>                  the assistant's preselected choice
///     BUTAKE_QA_GIT=<paso>;<paso>…                 steps, in order:
///       open:<ruta>  tab:<pestaña>  select:<archivo>  staged  include:<archivo>  exclude:<archivo>
///       hunk:<n>  commit:<resumen>  amend:<resumen>  undo  sync  fetch  push  pull
///       assistant:<acción>  newBranch:<nombre>  switch:<rama>  merge:<rama>  branch:<rama>
///       createSheet  discard:<archivo>  running  wait:<segundos>  log
///       and the steps of Historial and Problemas (`GitHistoryQA`)
///     Every step writes «QA git: <paso> → <estado>» to the standard error.
@MainActor enum GitQA {
    private static func value(_ name: String) -> String? {
        let env = ProcessInfo.processInfo.environment
        return StackStore.qaWindow && env["BUTAKE_STACK_HOME"] != nil ? env[name] : nil
    }

    static var requirement: GitRequirement? {
        switch value("BUTAKE_QA_GIT_REQUIREMENT") {
        case "missing": .missing
        case "outdated": .outdated(version: "2.17.1")
        default: nil
        }
    }
    static var commitSummary: String? { value("BUTAKE_QA_GIT_COMMIT") }
    static var pullChoice: GitAction? { value("BUTAKE_QA_GIT_PULL").flatMap(GitAction.init(rawValue:)) }

    private static var started = false
    /// G-5 sheets opened by a step: the dictionary's mode, the new worktree sheet, the worktree whose
    /// removal is asked (by its branch).
    static var dictionaryMode: String?
    static var worktreeAdding = false
    static var worktreeRemoving: String?

    static func start(_ tool: GitTool) async {
        guard !started, let script = value("BUTAKE_QA_GIT") else { return }
        started = true
        for step in script.split(separator: ";").map(String.init) {
            await run(step, tool)
            report(step, tool)
        }
    }

    private static func run(_ step: String, _ tool: GitTool) async {
        let parts = step.split(separator: ":", maxSplits: 1).map(String.init)
        let argument = parts.count > 1 ? parts[1] : ""
        if parts[0] == "open" { await tool.open(argument); return }
        if parts[0] == "wait" { try? await Task.sleep(for: .seconds(Double(argument) ?? 1)); return }
        if parts[0] == "tab" { tool.tab = GitTab(rawValue: argument) ?? .changes; return }
        // G-5: the dictionary, «Traer mis repositorios» (from the temporary HOME's made-up copy),
        // the menu bar's summary and the tool turned off.
        switch parts[0] {
        case "dictionary":
            dictionaryMode = argument.isEmpty ? nil : argument
            tool.showingDictionary = true
            return
        case "migration":
            GitMigration.shared.check()
            GitMigration.shared.presenter = .tool
            return
        case "migrationRun":
            let result = await GitMigration.shared.bring(tool: tool)
            FileHandle.standardError.write(Data("QA git: migración → agregados=\(result.added) ya=\(result.known) faltan=\(result.missing) fallos=\(result.failed)\n".utf8))
            return
        case "board":
            await GitStatusBoard.shared.refresh()
            FileHandle.standardError.write(Data("QA git: barra → \(GitStatusBoard.shared.rows.map { "\($0.entry.name)[\($0.detail)]" })\n".utf8))
            return
        case "boardPull", "boardPush":
            if let entry = tool.entries.first(where: { $0.name == argument }) {
                await GitStatusBoard.shared.transfer(parts[0] == "boardPull" ? .pull : .push, entry)
            }
            return
        case "toolOff":
            if let plugin = StackStore.shared.plugins.first(where: { $0.id == "git" }) { await StackStore.shared.setPlugin(plugin, enabled: false) }
            return
        default: break
        }
        guard let repository = tool.repository else { return }
        switch parts[0] {
        case "worktreeSheet":
            GitHistoryQA.moreSection = .worktrees
            worktreeAdding = true
            GitWork.shared.more = true
            return
        case "worktreeAdd", "worktreeRemove":
            // `rama`: the new folder goes beside the repository, «<repositorio>-<rama>».
            let folder = (repository.root as NSString).deletingLastPathComponent + "/" + (repository.root as NSString).lastPathComponent
                + "-" + argument.replacingOccurrences(of: "/", with: "-")
            let done = parts[0] == "worktreeAdd" ? await repository.perform(.addWorktree, value: folder + "\n" + argument)
                : await repository.perform(.removeWorktree, value: folder)
            GitMoreRefresh.shared.after(done)
            return
        case "worktreeRemoveDialog":
            GitHistoryQA.moreSection = .worktrees
            worktreeRemoving = argument
            GitWork.shared.more = true
            return
        default: break
        }
        switch parts[0] {
        case "select": repository.selectedFile = argument
        case "staged": repository.showStaged = true
        case "include", "exclude":
            repository.include([argument], parts[0] == "include")
            await repository.chain?.value
        case "hunk":
            try? await Task.sleep(for: .seconds(1))
            repository.stageHunk(Int(argument) ?? 0)
            await repository.chain?.value
        case "commit": _ = await repository.commit(summary: argument, description: "", amend: false)
        case "amend": _ = await repository.commit(summary: argument, description: "", amend: true)
        case "undo": await repository.perform(.undoCommit)
        case "sync": await repository.sync()
        case "fetch": await repository.perform(.fetch)
        case "push": await repository.perform(.push)
        case "pull": await repository.perform(.pull)
        case "assistant": if let action = GitAction(rawValue: argument) { await repository.resolvePull(action) }
        case "newBranch": _ = await repository.createBranch(argument)
        case "switch": await repository.switchTo(argument)
        case "merge": await repository.merge(argument)
        case "branch": repository.selectedBranch = argument
        case "createSheet": tool.creatingBranch = true
        case "discard": repository.discarding = repository.files.filter { $0.path == argument }
        // The primary button while a transfer runs (only its look: nothing is sent).
        case "running": repository.operation = GitOperation(title: GitAction.pull.progressTitle, cancellable: true)
        case "refresh": await repository.refresh()
        default: _ = await GitHistoryQA.run(parts[0], argument, repository)
        }
    }

    private static func report(_ step: String, _ tool: GitTool) {
        guard let repository = tool.repository else {
            FileHandle.standardError.write(Data("QA git: \(step) → sin repositorio (\(tool.requirement))\n".utf8))
            return
        }
        let snapshot = repository.snapshot
        let files = repository.files.map { "\($0.index)\($0.worktree) \($0.path)" }.joined(separator: ", ")
        let line = "QA git: \(step) → rama=\(snapshot.branch) ↑\(snapshot.ahead) ↓\(snapshot.behind) operación=\(snapshot.operation.isEmpty ? "-" : snapshot.operation) "
            + "último=\(snapshot.headCommit?.subject ?? "-") botón=\(repository.syncState.identifier) asistente=\(repository.pullProblem?.code ?? "-") "
            + "error=\(repository.failure?.code ?? "-") archivos=[\(files)]\n"
        FileHandle.standardError.write(Data((line + GitHistoryQA.report(repository)).utf8))
    }
}
#endif
