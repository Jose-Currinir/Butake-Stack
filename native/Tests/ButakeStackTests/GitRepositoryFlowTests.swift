import Foundation
import Testing
@testable import ButakeStack

// The daily work of the Git tool against the real engine and Git, through the same model the
// buttons use: repositories made for the test with a local bare remote, Git's configuration in a
// temporary file (never the user's), no network.

/// A temporary Git configuration with an identity, for this process and the engines it starts.
private let isolatedGit: URL = {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("stack-git-config-\(ProcessInfo.processInfo.processIdentifier)")
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let config = folder.appendingPathComponent("gitconfig")
    try? "[user]\n\tname = Stack QA\n\temail = qa@example.invalid\n[commit]\n\tgpgsign = false\n[init]\n\tdefaultBranch = develop\n"
        .write(to: config, atomically: true, encoding: .utf8)
    setenv("GIT_CONFIG_GLOBAL", config.path, 1)
    setenv("GIT_CONFIG_NOSYSTEM", "1", 1)
    return folder
}()

@discardableResult private func git(_ folder: URL, _ arguments: String...) throws -> String {
    _ = isolatedGit
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
    try text.write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
}

/// Two working copies of one bare remote: «mine» (the tool's) and «theirs» (someone else's).
private struct Sandbox {
    let root: URL
    let remote: URL
    let mine: URL
    let theirs: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("stack-git-flow-\(UUID().uuidString)").resolvingSymlinksInPath()
        remote = root.appendingPathComponent("remoto.git")
        mine = root.appendingPathComponent("mio")
        theirs = root.appendingPathComponent("ajeno")
        for folder in [remote, mine] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        try git(remote, "init", "-q", "--bare", "-b", "develop")
        try git(mine, "init", "-q", "-b", "develop")
        try write(mine, "base.txt", (1...30).map { "línea \($0)" }.joined(separator: "\n") + "\n")
        try git(mine, "add", "base.txt")
        try git(mine, "commit", "-q", "-m", "chore: base")
        try git(mine, "remote", "add", "origin", remote.path)
        try git(mine, "push", "-q", "-u", "origin", "develop")
        try git(root, "clone", "-q", remote.path, theirs.path)
    }

    /// Someone else commits and pushes a file.
    func theirCommit(_ file: String, _ text: String, _ message: String) throws {
        try git(theirs, "pull", "-q", "--ff-only")
        try write(theirs, file, text)
        try git(theirs, "add", file)
        try git(theirs, "commit", "-q", "-m", message)
        try git(theirs, "push", "-q", "origin", "develop")
    }
}

@MainActor private func openRepository(_ store: StackStore, _ path: URL) async throws -> GitRepository {
    let _: [ToolInfo] = try await store.call(["method": "pluginSetEnabled", "id": "git", "enabled": true])
    let snapshot: GitSnapshot = try await store.call(["method": "gitOpen", "path": path.path])
    return GitRepository(snapshot: snapshot, store: store)
}

/// Waits for the diff of the selected file (it loads on its own).
@MainActor private func diffLoaded(_ repository: GitRepository) async {
    for _ in 0..<100 where repository.diffText.isEmpty { try? await Task.sleep(for: .milliseconds(50)) }
}

@MainActor @Test func changesCommitPushPullAndTheAssistantWithoutAConsole() async throws {
    let sandbox = try Sandbox()
    defer { try? FileManager.default.removeItem(at: sandbox.root) }
    let store = StackStore(engine: StackEngine())
    let repository = try await openRepository(store, sandbox.mine)
    defer { repository.stopWatching() }
    #expect(repository.syncState == .fetch(last: nil))

    // Two blocks changed in one file: only the first goes into the commit.
    var lines = (1...30).map { "línea \($0)" }
    lines[1] = "línea 2 cambiada"
    lines[27] = "línea 28 cambiada"
    try write(sandbox.mine, "base.txt", lines.joined(separator: "\n") + "\n")
    try write(sandbox.mine, "nuevo.txt", "nuevo\n")
    await repository.refresh()
    #expect(Set(repository.files.map(\.path)) == ["base.txt", "nuevo.txt"])
    repository.selectedFile = "base.txt"
    await diffLoaded(repository)
    #expect(repository.hunkHeader(1) != nil)
    repository.stageHunk(0)
    await repository.chain?.value
    #expect(repository.files.first { $0.path == "base.txt" }?.inclusion == .partial)

    // Include the new file too, then confirm: summary and description.
    repository.include(["nuevo.txt"], true)
    await repository.chain?.value
    #expect(await repository.commit(summary: "feat: primer bloque", description: "Con un archivo nuevo.", amend: false))
    #expect(repository.snapshot.headCommit?.subject == "feat: primer bloque")
    #expect(repository.files.map(\.path) == ["base.txt"])
    #expect(repository.syncState == .push(count: 1))

    // Correct it with the rest, undo it, confirm it again.
    repository.include(["base.txt"], true)
    await repository.chain?.value
    #expect(await repository.commit(summary: "feat: dos bloques", description: "", amend: true))
    #expect(repository.files.isEmpty && repository.snapshot.ahead == 1)
    #expect(repository.canUndoCommit)
    #expect(await repository.perform(.undoCommit))
    #expect(repository.stagedFiles.count == 2 && repository.snapshot.ahead == 0)
    #expect(await repository.commit(summary: "feat: dos bloques", description: "", amend: false))

    // Push with the primary button.
    await repository.sync()
    #expect(repository.snapshot.ahead == 0 && repository.failure == nil)
    #expect(try git(sandbox.remote, "log", "-1", "--format=%s", "develop").contains("feat: dos bloques"))
    #expect(try git(sandbox.remote, "log", "-1", "--format=%B", "develop").contains("feat: dos bloques"))

    // Someone else's commit: «Actualizar» sees it, «Bajar cambios (1)» brings it.
    let theirLines = (1...10).map { "ajeno \($0)" }
    try sandbox.theirCommit("ajeno.txt", theirLines.joined(separator: "\n") + "\n", "feat: commit ajeno")
    await repository.sync()
    #expect(repository.syncState == .pull(count: 1, thenPush: 0))
    await repository.sync()
    #expect(FileManager.default.fileExists(atPath: sandbox.mine.appendingPathComponent("ajeno.txt").path))
    #expect(repository.snapshot.behind == 0)

    // Both sides moved: the pull is not direct, the assistant combines, then my commit goes up.
    try sandbox.theirCommit("otro.txt", "otro\n", "feat: otro commit ajeno")
    try write(sandbox.mine, "mio.txt", "mío\n")
    await repository.refresh()
    repository.include(["mio.txt"], true)
    await repository.chain?.value
    #expect(await repository.commit(summary: "feat: commit mío", description: "", amend: false))
    await repository.perform(.fetch)
    #expect(repository.syncState == .pull(count: 1, thenPush: 1))
    await repository.sync()
    #expect(repository.pullProblem?.code == "pull_diverged")
    #expect(repository.lastSyncFailure?.code == "pull_diverged")
    await repository.resolvePull(.pullMerge)
    #expect(repository.pullProblem == nil && repository.failure == nil)
    #expect(repository.snapshot.ahead == 0 && repository.snapshot.behind == 0 && repository.lastSyncFailure == nil)
    let remoteLog = try git(sandbox.remote, "log", "--format=%s", "develop")
    #expect(remoteLog.contains("feat: commit mío") && remoteLog.contains("feat: otro commit ajeno"))

    // Local changes in the way: «Guardar mis cambios temporalmente» brings and puts them back.
    var theirs = theirLines, mine = theirLines
    theirs[0] = "ajeno 1 corregido"
    mine[8] = "ajeno 9 cambiado aquí"
    try sandbox.theirCommit("ajeno.txt", theirs.joined(separator: "\n") + "\n", "fix: ajeno")
    try write(sandbox.mine, "ajeno.txt", mine.joined(separator: "\n") + "\n")
    await repository.perform(.fetch)
    await repository.sync()
    #expect(repository.pullProblem?.code == "pull_local_changes")
    await repository.resolvePull(.pullAutostash)
    #expect(repository.snapshot.behind == 0 && repository.failure == nil)
    let merged = try String(contentsOf: sandbox.mine.appendingPathComponent("ajeno.txt"), encoding: .utf8)
    #expect(merged.contains("ajeno 1 corregido") && merged.contains("ajeno 9 cambiado aquí"))
    #expect(repository.files.map(\.path) == ["ajeno.txt"])
}

@MainActor @Test func branchesAreCreatedSwitchedRenamedMergedAndDeleted() async throws {
    let sandbox = try Sandbox()
    defer { try? FileManager.default.removeItem(at: sandbox.root) }
    let store = StackStore(engine: StackEngine())
    let repository = try await openRepository(store, sandbox.mine)
    defer { repository.stopWatching() }

    #expect(await repository.createBranch("feature/carrito"))
    #expect(repository.snapshot.branch == "feature/carrito")
    // A branch only here: the primary button publishes it.
    #expect(repository.syncState == .publishBranch)
    try write(sandbox.mine, "carrito.txt", "carrito\n")
    await repository.refresh()
    repository.include(["carrito.txt"], true)
    await repository.chain?.value
    #expect(await repository.commit(summary: "feat: carrito", description: "", amend: false))
    await repository.sync()
    #expect(repository.snapshot.tracked && repository.syncState == .fetch(last: repository.lastFetch))
    #expect(try git(sandbox.remote, "branch", "--list").contains("feature/carrito"))

    #expect(await repository.renameBranch("feature/carrito", to: "feature/compra"))
    #expect(repository.snapshot.branch == "feature/compra")
    await repository.switchTo("develop")
    #expect(repository.snapshot.branch == "develop")
    await repository.merge("feature/compra")
    #expect(FileManager.default.fileExists(atPath: sandbox.mine.appendingPathComponent("carrito.txt").path))
    #expect(await repository.deleteBranch("feature/compra", force: false) == .deleted)
    #expect(!repository.snapshot.branches.contains { $0.name == "feature/compra" })

    // A branch whose commits are nowhere else asks again before forcing.
    #expect(await repository.createBranch("experimento"))
    try write(sandbox.mine, "exp.txt", "x\n")
    await repository.refresh()
    repository.include(["exp.txt"], true)
    await repository.chain?.value
    #expect(await repository.commit(summary: "feat: experimento", description: "", amend: false))
    await repository.switchTo("develop")
    #expect(await repository.deleteBranch("experimento", force: false) == .notMerged)
    #expect(await repository.deleteBranch("experimento", force: true) == .deleted)

    // A remote branch: switching to it creates its local copy.
    try git(sandbox.theirs, "switch", "-q", "-c", "feature/remota")
    try git(sandbox.theirs, "push", "-q", "origin", "feature/remota")
    await repository.perform(.fetch)
    #expect(repository.remoteOnlyBranches.contains { $0.name == "origin/feature/remota" })
    await repository.switchTo("origin/feature/remota")
    #expect(repository.snapshot.branch == "feature/remota" && repository.snapshot.tracked)
}

@MainActor @Test func discardAndAProtectedMainAreGuarded() async throws {
    let sandbox = try Sandbox()
    defer { try? FileManager.default.removeItem(at: sandbox.root) }
    let store = StackStore(engine: StackEngine())
    try git(sandbox.mine, "branch", "main")
    try git(sandbox.mine, "config", "butake.protectMain", "true")
    let repository = try await openRepository(store, sandbox.mine)
    defer { repository.stopWatching() }

    try write(sandbox.mine, "base.txt", "otro contenido\n")
    try write(sandbox.mine, "suelto.txt", "suelto\n")
    await repository.refresh()
    await repository.discard(repository.files)
    #expect(repository.files.isEmpty)
    #expect(try String(contentsOf: sandbox.mine.appendingPathComponent("base.txt"), encoding: .utf8).hasPrefix("línea 1"))

    // On the protected main nothing is committed: the engine refuses and the box says why.
    await repository.switchTo("main")
    #expect(repository.snapshot.onProtectedMain)
    try write(sandbox.mine, "main.txt", "x\n")
    await repository.refresh()
    repository.include(["main.txt"], true)
    await repository.chain?.value
    #expect(await repository.commit(summary: "feat: directo", description: "", amend: false) == false)
    #expect(repository.failure?.code == "protected_branch")
    #expect(!repository.canUndoCommit)
}
