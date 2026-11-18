import Foundation
import Testing
@testable import ButakeStack

// Historial, Problemas, conflicts and «Organizar commits» against the real engine and Git, through
// the same models the buttons use: repositories made for the test with a local bare remote, Git's
// configuration in a temporary file (never the user's), no network.

private let isolatedConfig: URL = {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("stack-git-g3-\(ProcessInfo.processInfo.processIdentifier)")
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let config = folder.appendingPathComponent("gitconfig")
    if !FileManager.default.fileExists(atPath: config.path) {
        try? "[user]\n\tname = Stack QA\n\temail = qa@example.invalid\n[commit]\n\tgpgsign = false\n[init]\n\tdefaultBranch = develop\n"
            .write(to: config, atomically: true, encoding: .utf8)
    }
    // The same variables as the other Git tests of this process (whichever runs first sets them).
    if ProcessInfo.processInfo.environment["GIT_CONFIG_GLOBAL"] == nil { setenv("GIT_CONFIG_GLOBAL", config.path, 1) }
    setenv("GIT_CONFIG_NOSYSTEM", "1", 1)
    return folder
}()

@discardableResult private func run(_ folder: URL, _ arguments: String...) throws -> String {
    _ = isolatedConfig
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = arguments
    process.currentDirectoryURL = folder
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let text = String(decoding: data, as: UTF8.self)
    guard process.terminationStatus == 0 else { throw EngineFailure(code: "git", messageKey: "git", detail: text) }
    return text
}

private func write(_ folder: URL, _ name: String, _ text: String) throws {
    let url = folder.appendingPathComponent(name)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
}

private func commit(_ folder: URL, _ name: String, _ text: String, _ message: String) throws {
    try write(folder, name, text)
    try run(folder, "add", name)
    try run(folder, "commit", "-q", "-m", message)
}

/// «mine» (the tool's) and «theirs» (someone else's) working copies of one bare remote.
private struct Sandbox {
    let root: URL, remote: URL, mine: URL, theirs: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("stack-git-g3-\(UUID().uuidString)").resolvingSymlinksInPath()
        remote = root.appendingPathComponent("remoto.git")
        mine = root.appendingPathComponent("mio")
        theirs = root.appendingPathComponent("ajeno")
        for folder in [remote, mine] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        try run(remote, "init", "-q", "--bare", "-b", "develop")
        try run(mine, "init", "-q", "-b", "develop")
        try commit(mine, "a.txt", "a 1\na 2\na 3\n", "chore: base")
        try commit(mine, "b.txt", "b 1\nb 2\n", "feat: archivo b")
        try run(mine, "remote", "add", "origin", remote.path)
        try run(mine, "push", "-q", "-u", "origin", "develop")
        try run(root, "clone", "-q", remote.path, theirs.path)
    }

    func theirCommit(_ file: String, _ text: String, _ message: String) throws {
        try run(theirs, "pull", "-q", "--ff-only")
        try commit(theirs, file, text, message)
        try run(theirs, "push", "-q", "origin", "HEAD")
    }
}

@MainActor private func open(_ store: StackStore, _ path: URL) async throws -> GitRepository {
    let _: [ToolInfo] = try await store.call(["method": "pluginSetEnabled", "id": "git", "enabled": true])
    let snapshot: GitSnapshot = try await store.call(["method": "gitOpen", "path": path.path])
    return GitRepository(snapshot: snapshot, store: store)
}

@MainActor private func ids(_ repository: GitRepository) -> [String] {
    GitProblemSources.shared.problems(for: repository).filter { $0.id.hasPrefix("git.") }.map(\.id)
}

@MainActor private func problem(_ repository: GitRepository, _ id: String) -> GitProblem? {
    GitProblemSources.shared.problems(for: repository).first { $0.id == id }
}

/// Waits for a background check (identity, sizes) to settle.
@MainActor private func eventually(_ condition: () -> Bool) async {
    for _ in 0..<100 where !condition() { try? await Task.sleep(for: .milliseconds(50)) }
}

// MARK: - Search

@Test func everySearchScopeBecomesItsQuery() throws {
    #expect(GitHistorySearch.arguments(.message, text: "  ", onlyBranch: true) == nil)
    let message = try #require(GitHistorySearch.arguments(.message, text: "iva", onlyBranch: true))
    #expect(message.contains("--grep=iva") && message.contains("--fixed-strings") && message.last == "HEAD")
    let author = try #require(GitHistorySearch.arguments(.author, text: "Ana", onlyBranch: false))
    #expect(author.contains("--author=Ana") && author.contains("--branches"))
    #expect(GitHistorySearch.arguments(.file, text: "nada", onlyBranch: true, paths: ["a.txt"]) == nil)
    #expect(GitHistorySearch.arguments(.file, text: "A.T", onlyBranch: true, paths: ["a.txt", "b.txt"])?.suffix(2) == ["--", "a.txt"])
    #expect(GitHistorySearch.arguments(.identifier, text: "xyz1", onlyBranch: true) == nil)
    #expect(GitHistorySearch.arguments(.identifier, text: "ABCD12", onlyBranch: true)?.contains("abcd12") == true)
    #expect(GitHistorySearch.arguments(.content, text: "hola", onlyBranch: true)?.first == "grep")
    #expect(GitHistorySearch.matches("src/a:b.ts\u{0}12\u{0}  hola mundo\n") == [GitContentMatch(path: "src/a:b.ts", line: 12, text: "hola mundo")])
}

@Test func datesAreUnderstoodInPlainWords() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/Santiago")!
    let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 14, hour: 15)))
    #expect(GitHistoryDate.range("2026-11-14", now: now, calendar: calendar)! == ("2026-11-14 00:00:00", "2026-11-15 00:00:00"))
    #expect(GitHistoryDate.range("14/11/2026", now: now, calendar: calendar)! == ("2026-11-14 00:00:00", "2026-11-15 00:00:00"))
    #expect(GitHistoryDate.range("2026-11", now: now, calendar: calendar)! == ("2026-11-01 00:00:00", "2026-12-01 00:00:00"))
    #expect(GitHistoryDate.range("2026", now: now, calendar: calendar)! == ("2026-01-01 00:00:00", "2027-01-01 00:00:00"))
    #expect(GitHistoryDate.range("hoy", now: now, calendar: calendar)! == ("2026-11-14 00:00:00", "2026-11-15 00:00:00"))
    #expect(GitHistoryDate.range("ayer", now: now, calendar: calendar)! == ("2026-11-13 00:00:00", "2026-11-14 00:00:00"))
    #expect(GitHistoryDate.range("este mes", now: now, calendar: calendar)!.since == "2026-11-01 00:00:00")
    for wrong in ["31/02/2026", "mañana", "2026-13", "abc"] { #expect(GitHistoryDate.range(wrong, now: now, calendar: calendar) == nil, "\(wrong)") }
}

@MainActor @Test func searchingByEveryScopeFindsWhatItShould() async throws {
    let sandbox = try Sandbox()
    defer { try? FileManager.default.removeItem(at: sandbox.root) }
    try commit(sandbox.mine, "src/total.ts", "export const iva = 1.19;\n", "fix(carrito): iva correcto")
    let store = StackStore(engine: StackEngine())
    let repository = try await open(store, sandbox.mine)
    defer { repository.stopWatching() }
    let history = repository.history
    await history.reloadBranch()
    #expect(history.commits.map(\.subject) == ["fix(carrito): iva correcto", "feat: archivo b", "chore: base"])

    func search(_ scope: GitHistorySearchScope, _ text: String) async -> [String] {
        history.scope = scope
        history.search = text
        await history.runSearch()
        return history.results?.map(\.subject) ?? []
    }
    #expect(await search(.message, "IVA") == ["fix(carrito): iva correcto"])
    #expect(await search(.author, "stack qa").count == 3)
    #expect(await search(.author, "nadie").isEmpty)
    #expect(await search(.file, "b.txt") == ["feat: archivo b"])
    #expect(await search(.date, L("git.history.date.today")).count == 3)
    #expect(await search(.date, "1999-01-01").isEmpty)
    let base = try run(sandbox.mine, "rev-list", "--max-parents=0", "HEAD").trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(await search(.identifier, String(base.prefix(8))) == ["chore: base"])
    history.scope = .content
    history.search = "1.19"
    await history.runSearch()
    #expect(history.matches == [GitContentMatch(path: "src/total.ts", line: 1, text: "export const iva = 1.19;")])
    history.search = ""
    await history.runSearch()
    #expect(history.results == nil && history.matches == nil)
}

@MainActor @Test func aSearchThatEndsEarlyMakesTheOneInFlightStale() async throws {
    let sandbox = try Sandbox()
    defer { try? FileManager.default.removeItem(at: sandbox.root) }
    let store = StackStore(engine: StackEngine())
    let repository = try await open(store, sandbox.mine)
    defer { repository.stopWatching() }
    let history = repository.history
    await history.reloadBranch()

    // A message search is asked; before it answers the scope changes to a date the text is not.
    history.scope = .message
    history.search = "chore"
    let inFlight = Task { await history.runSearch() }
    await Task.yield()
    history.scope = .date
    await history.runSearch()
    await inFlight.value
    #expect(history.results?.isEmpty == true)
    #expect(history.searchNote != nil)
    #expect(!history.searching)
}

// MARK: - Organize

@Test func organizingCombinesSplitsRemovesAndReorders() {
    func commit(_ hash: String) -> GitRewriteCandidates.Commit { .init(hash: hash + "000000", subject: hash, message: hash, author: "a", timestamp: "0") }
    let candidates = GitRewriteCandidates(branch: "f", head: "h", base: "b", commits: [commit("c1"), commit("c2"), commit("c3")], boundary: "upstream")
    var plan = GitOrganizePlan(candidates)
    #expect(plan.items.map(\.subject) == ["c3", "c2", "c1"] && !plan.changed)
    let joined = plan.combine(Set(plan.items.prefix(2).map(\.id)))
    #expect(joined != nil && plan.items.count == 2 && plan.items[0].commits.map(\.subject) == ["c2", "c3"])
    #expect(plan.plan(candidates).steps.map(\.hashes) == [["c1000000"], ["c2000000", "c3000000"]])
    #expect(plan.plan(candidates).steps.allSatisfy { $0.message == nil })
    plan.items[0].message = "feat: juntos"
    #expect(plan.plan(candidates).steps[1].message == "feat: juntos" && plan.renamed == 1)
    plan.split([plan.items[0].id])
    #expect(plan.items.count == 3)
    plan.toggleDrop([plan.items[2].id])
    #expect(plan.removed == 1 && plan.valid)
    // Some removed: the button removes all; then nothing would remain.
    plan.toggleDrop(Set(plan.items.map(\.id)))
    #expect(plan.items.allSatisfy(\.drop) && !plan.valid)
    plan.reset()
    plan.move(plan.items[0].id, by: 1)
    #expect(plan.items.map(\.subject) == ["c2", "c3", "c1"] && plan.changed)
}

@MainActor @Test func threeCommitsAreOrganizedAndUndone() async throws {
    let sandbox = try Sandbox()
    defer { try? FileManager.default.removeItem(at: sandbox.root) }
    for index in 1...3 { try commit(sandbox.mine, "c\(index).txt", "\(index)\n", "feat: paso \(index)") }
    let store = StackStore(engine: StackEngine())
    let repository = try await open(store, sandbox.mine)
    defer { repository.stopWatching() }
    let before = try run(sandbox.mine, "rev-parse", "HEAD")

    let candidates: GitRewriteCandidates = try await store.call(["method": "gitRewriteCandidates", "path": sandbox.mine.path])
    #expect(candidates.commits.map(\.subject) == ["feat: paso 1", "feat: paso 2", "feat: paso 3"])
    var plan = GitOrganizePlan(candidates)
    let combined = plan.combine(Set(plan.items.map(\.id)))
    let joined = try #require(combined)
    let index = try #require(plan.items.firstIndex { $0.id == joined })
    plan.items[index].message = "feat: tres pasos"
    #expect(await repository.applyRewrite(plan.plan(candidates), branch: "develop"))
    #expect(try run(sandbox.mine, "log", "-1", "--format=%s").trimmingCharacters(in: .whitespacesAndNewlines) == "feat: tres pasos")
    #expect(repository.snapshot.ahead == 1 && repository.history.lastBackup != nil)
    for index in 1...3 { #expect(FileManager.default.fileExists(atPath: sandbox.mine.appendingPathComponent("c\(index).txt").path)) }

    await repository.undoRewrite()
    #expect(try run(sandbox.mine, "rev-parse", "HEAD") == before)
    #expect(repository.history.lastBackup == nil && repository.snapshot.ahead == 3 && repository.failure == nil)
}

// MARK: - Conflicts

@MainActor @Test func twoFilesInConflictAreResolvedWithoutAConsole() async throws {
    let sandbox = try Sandbox()
    defer { try? FileManager.default.removeItem(at: sandbox.root) }
    try run(sandbox.mine, "switch", "-q", "-c", "feature/x")
    try commit(sandbox.mine, "a.txt", "a 1\nfeature\na 3\n", "feat: a en feature")
    try commit(sandbox.mine, "b.txt", "b feature\nb 2\n", "feat: b en feature")
    try run(sandbox.mine, "switch", "-q", "develop")
    try commit(sandbox.mine, "a.txt", "a 1\ndevelop\na 3\n", "feat: a en develop")
    try commit(sandbox.mine, "b.txt", "b develop\nb 2\n", "feat: b en develop")
    let store = StackStore(engine: StackEngine())
    let repository = try await open(store, sandbox.mine)
    defer { repository.stopWatching() }

    await repository.merge("feature/x")
    repository.failure = nil
    #expect(Set(repository.conflicts.map(\.path)) == ["a.txt", "b.txt"])
    #expect(ids(repository).first == "git.conflicts")
    let conflicts = try #require(problem(repository, "git.conflicts"))
    #expect(conflicts.secondary?.id == "abort" && conflicts.items.count == 2)
    await conflicts.action?.run()
    #expect(GitWork.shared.resolving)
    GitWork.shared.resolving = false

    // What the sheet does: «Tu versión» for a.txt, «Usar ambas» for b.txt (merging: ours is mine).
    for (file, choose) in [("a.txt", { (v: GitConflictVersions) in v.ours }), ("b.txt", { (v: GitConflictVersions) in v.ours + v.theirs })] {
        let versions: GitConflictVersions = try await store.call(["method": "gitConflict", "path": repository.root, "file": file])
        let request: [String: Any] = ["method": "gitResolveConflict", "file": file, "content": choose(versions), "expected": versions.working, "confirmed": true]
        let result = await repository.run(L("git.progress.resolve"), request, as: String.self)
        #expect((try? result.get()) != nil)
    }
    #expect(repository.conflicts.isEmpty && repository.snapshot.operation == "merge")
    let unfinished = try #require(problem(repository, "git.unfinished"))
    await unfinished.action?.run()
    #expect(repository.snapshot.operation.isEmpty && repository.failure == nil)
    #expect(!ids(repository).contains("git.unfinished"))
    #expect(try String(contentsOf: sandbox.mine.appendingPathComponent("a.txt"), encoding: .utf8) == "a 1\ndevelop\na 3\n")
    #expect(try String(contentsOf: sandbox.mine.appendingPathComponent("b.txt"), encoding: .utf8) == "b develop\nb 2\nb feature\nb 2\n")

    // And cancelled: everything as before.
    try run(sandbox.mine, "switch", "-q", "feature/x")
    try commit(sandbox.mine, "a.txt", "a otra vez\n", "feat: a otra vez")
    try run(sandbox.mine, "switch", "-q", "develop")
    try commit(sandbox.mine, "a.txt", "a de nuevo\n", "feat: a de nuevo")
    await repository.refresh()
    let head = try run(sandbox.mine, "rev-parse", "HEAD")
    await repository.merge("feature/x")
    repository.failure = nil
    #expect(!repository.conflicts.isEmpty)
    await repository.abortOperation()
    let after = try run(sandbox.mine, "rev-parse", "HEAD")
    #expect(repository.snapshot.operation.isEmpty && repository.conflicts.isEmpty && after == head)
}

// MARK: - Problems, one by one, each solved from its button

@MainActor @Test func everyProblemOfTheBranchIsSolvedFromItsButton() async throws {
    let sandbox = try Sandbox()
    defer { try? FileManager.default.removeItem(at: sandbox.root) }
    let store = StackStore(engine: StackEngine())
    let repository = try await open(store, sandbox.mine)
    defer { repository.stopWatching() }
    #expect(ids(repository).isEmpty)

    // A branch only on this Mac: «Publicar rama». With a commit of its own, so that once deleted on
    // the remote it is not one already merged (`everyMergedBranchIsDeletedFromItsButton`).
    #expect(await repository.createBranch("feature/sola"))
    try commit(sandbox.mine, "sola.txt", "sola\n", "feat: sola")
    await repository.refresh()
    #expect(ids(repository) == ["git.notPublished"])
    await problem(repository, "git.notPublished")?.action?.run()
    #expect(ids(repository).isEmpty && repository.snapshot.tracked)

    // Its remote branch was deleted: «Publicar de nuevo».
    try run(sandbox.theirs, "push", "-q", "origin", "--delete", "feature/sola")
    await repository.perform(.fetch)
    #expect(ids(repository) == ["git.upstreamGone"])
    await problem(repository, "git.upstreamGone")?.action?.run()
    #expect(ids(repository).isEmpty)
    await repository.switchTo("develop")

    // Both sides moved: «Bajar y combinar…» opens the assistant, which combines.
    try sandbox.theirCommit("ajeno.txt", "ajeno\n", "feat: ajeno")
    try commit(sandbox.mine, "mio.txt", "mío\n", "feat: mío")
    await repository.perform(.fetch)
    #expect(ids(repository) == ["git.diverged"])
    await problem(repository, "git.diverged")?.action?.run()
    #expect(repository.pullProblem?.code == "pull_diverged")
    await repository.resolvePull(.pullMerge)
    #expect(ids(repository).isEmpty)

    // A pull stopped by local changes: «Guardar mis cambios temporalmente».
    try sandbox.theirCommit("a.txt", "a 1 ajena\na 2\na 3\n", "fix: a")
    try write(sandbox.mine, "a.txt", "a 1\na 2\na 3 mía\n")
    await repository.perform(.fetch)
    await repository.sync()
    repository.pullProblem = nil
    #expect(ids(repository) == ["git.lastSync"])
    await problem(repository, "git.lastSync")?.action?.run()
    #expect(ids(repository).isEmpty)
    #expect(try String(contentsOf: sandbox.mine.appendingPathComponent("a.txt"), encoding: .utf8) == "a 1 ajena\na 2\na 3 mía\n")

    // The remote out of reach: «Intentar de nuevo» once it is back.
    let moved = sandbox.root.appendingPathComponent("lejos.git")
    try FileManager.default.moveItem(at: sandbox.remote, to: moved)
    await repository.perform(.fetch)
    repository.failure = nil
    #expect(ids(repository).contains("git.remoteAccess"))
    try FileManager.default.moveItem(at: moved, to: sandbox.remote)
    await problem(repository, "git.remoteAccess")?.action?.run()
    #expect(!ids(repository).contains("git.remoteAccess"))
}

/// Pull requests merged on the provider with «delete the branch»: the branches only left on this Mac
/// are listed once and go with one button; one deleted there without merging stays.
@MainActor @Test func everyMergedBranchIsDeletedFromItsButton() async throws {
    let sandbox = try Sandbox()
    defer { try? FileManager.default.removeItem(at: sandbox.root) }
    for name in ["feature/a", "feature/b", "feature/c"] {
        try run(sandbox.mine, "switch", "-q", "-c", name, "develop")
        try commit(sandbox.mine, "\(name.dropFirst(8)).txt", "\(name)\n", "feat: \(name)")
        try run(sandbox.mine, "push", "-q", "-u", "origin", name)
    }
    try run(sandbox.mine, "switch", "-q", "develop")
    let store = StackStore(engine: StackEngine())
    let repository = try await open(store, sandbox.mine)
    defer { repository.stopWatching() }
    #expect(ids(repository).isEmpty)

    // The provider merges a and b into develop and deletes them; c is deleted without merging.
    try run(sandbox.theirs, "fetch", "-q")
    try run(sandbox.theirs, "merge", "-q", "--no-ff", "-m", "Merge pull request #1", "origin/feature/a")
    try run(sandbox.theirs, "merge", "-q", "--no-ff", "-m", "Merge pull request #2", "origin/feature/b")
    try run(sandbox.theirs, "push", "-q", "origin", "develop")
    try run(sandbox.theirs, "push", "-q", "origin", "--delete", "feature/a", "feature/b", "feature/c")

    // «Bajar» prunes them, as «Actualizar» does.
    #expect(await repository.perform(.pull))
    #expect(!repository.snapshot.remoteBranches.contains { $0.short.hasPrefix("feature/") })
    let merged = try #require(problem(repository, "git.mergedBranches"))
    #expect(merged.title == "2 ramas ya combinadas siguen en este Mac")
    #expect(merged.items == ["feature/a", "feature/b"])
    await merged.action?.run()
    #expect(repository.snapshot.branches.map(\.name).sorted() == ["develop", "feature/c"])
    #expect(problem(repository, "git.mergedBranches") == nil)
}

@MainActor @Test func everyProblemOfTheFolderIsSolvedFromItsButton() async throws {
    let sandbox = try Sandbox()
    defer { try? FileManager.default.removeItem(at: sandbox.root) }
    let store = StackStore(engine: StackEngine())
    let repository = try await open(store, sandbox.mine)
    defer { repository.stopWatching() }
    let work = GitWork.shared

    // A file too big: «Dejar fuera e ignorar…».
    let big = sandbox.mine.appendingPathComponent("datos/volcado.sql")
    try FileManager.default.createDirectory(at: big.deletingLastPathComponent(), withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: big.path, contents: nil)
    let handle = try FileHandle(forWritingTo: big)
    try handle.truncate(atOffset: GitProblemChecks.largeFileLimit + 1)
    try handle.close()
    await repository.refresh()
    await eventually { !repository.checks.largeFiles.isEmpty }
    #expect(ids(repository) == ["git.largeFiles"])
    await problem(repository, "git.largeFiles")?.action?.run()
    let paths = try #require(work.ignoring)
    work.ignoring = nil
    for path in paths { #expect(await repository.perform(.ignorePath, value: path)) }
    await eventually { repository.checks.largeFiles.isEmpty }
    #expect(!ids(repository).contains("git.largeFiles"))
    #expect(try String(contentsOf: sandbox.mine.appendingPathComponent(".gitignore"), encoding: .utf8) == "/datos/volcado.sql\n")

    // No identity: «Configurar identidad…» saves it for this repository.
    repository.checks.identityMissing = true
    #expect(ids(repository).first == "git.identity")
    await problem(repository, "git.identity")?.action?.run()
    #expect(work.identity)
    work.identity = false
    #expect(await repository.perform(.setIdentity, value: "Ana Pérez\nana@example.invalid"))
    await eventually { !repository.checks.identityMissing }
    #expect(!ids(repository).contains("git.identity"))
    #expect(try run(sandbox.mine, "config", "--local", "user.email").contains("ana@example.invalid"))

    // Working on the protected main branch: «Pasar a una rama nueva…».
    try run(sandbox.mine, "add", ".gitignore")
    try run(sandbox.mine, "commit", "-q", "-m", "chore: ignorar volcados")
    try run(sandbox.mine, "switch", "-q", "-c", "main")
    try run(sandbox.mine, "config", "butake.protectMain", "true")
    try write(sandbox.mine, "c.txt", "c\n")
    await repository.refresh()
    #expect(repository.snapshot.onProtectedMain)
    #expect(ids(repository).contains("git.protectedMain"))
    await problem(repository, "git.protectedMain")?.action?.run()
    #expect(GitTool.shared.creatingBranch)
    GitTool.shared.creatingBranch = false
    #expect(await repository.createBranch("feature/c"))
    #expect(!ids(repository).contains("git.protectedMain"))

    // A source of another part of the tool joins the list and the count.
    let mine = ObjectIdentifier(repository)
    GitProblemSources.shared.register("test.checks") { other in
        ObjectIdentifier(other) == mine
            ? [GitProblem(id: "test.checks", severity: .warning, title: "x", reason: "y", symbol: Symbols.warning, action: nil)] : []
    }
    defer { GitProblemSources.shared.unregister("test.checks") }
    #expect(GitTab.problems.badge(repository) == GitProblemSources.shared.problems(for: repository).count)
    #expect(GitProblemSources.shared.problems(for: repository).contains { $0.id == "test.checks" })
}

@MainActor @Test func gitMissingIsAProblemWithItsWayOut() async throws {
    let sandbox = try Sandbox()
    defer { try? FileManager.default.removeItem(at: sandbox.root) }
    let repository = try await open(StackStore(engine: StackEngine()), sandbox.mine)
    defer { repository.stopWatching() }
    let tool = GitTool.shared
    let previous = tool.requirement
    defer { tool.requirement = previous }
    tool.requirement = .outdated(version: "2.17.1")
    #expect(problem(repository, "git.requirement")?.action?.id == "utilities")
    tool.requirement = .ready(version: "2.50.1")
    #expect(problem(repository, "git.requirement") == nil)
}

/// The texts built at run time: scopes, dates, marks, severities, boundaries, sections and every
/// new action's progress and toast.
@MainActor @Test func everyTextOfHistoryAndProblemsExists() {
    for scope in GitHistorySearchScope.allCases {
        for family in ["scope", "prompt", "note"] { #expect(localized("git.history.\(family).\(scope.rawValue)") != nil, "\(family).\(scope)") }
    }
    for word in GitHistoryDate.words { #expect(localized("git.history.date.\(word)") != nil) }
    for kind in ["head", "branch", "remote", "tag"] { #expect(localized("git.history.ref.\(kind)") != nil) }
    for severity in [GitProblem.Severity.error, .warning, .note] { #expect(!severity.title.hasPrefix("git.")) }
    for boundary in ["upstream", "merge", "root", "limit"] { #expect(localized("git.organize.boundary.\(boundary)") != nil) }
    for section in GitMoreSection.allCases { #expect(localized("git.more.\(section.rawValue)") != nil) }
}
