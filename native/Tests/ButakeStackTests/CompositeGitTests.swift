import Foundation
import Testing
@testable import ButakeStack

// «Actualizar todo» and «Bajar todo» of a project of several parts (P-39) against the real engine
// and Git: two parts, each with its repository and a local bare remote, on branches of different
// names, plus a repository added by hand. Git's configuration in a temporary file (never the
// user's), no network, and nothing is committed or sent.

private let compositeConfig: URL = {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("stack-git-p39-\(ProcessInfo.processInfo.processIdentifier)")
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let config = folder.appendingPathComponent("gitconfig")
    if !FileManager.default.fileExists(atPath: config.path) {
        try? "[user]\n\tname = Stack QA\n\temail = qa@example.invalid\n[commit]\n\tgpgsign = false\n"
            .write(to: config, atomically: true, encoding: .utf8)
    }
    if ProcessInfo.processInfo.environment["GIT_CONFIG_GLOBAL"] == nil { setenv("GIT_CONFIG_GLOBAL", config.path, 1) }
    setenv("GIT_CONFIG_NOSYSTEM", "1", 1)
    return folder
}()

@discardableResult private func git(_ folder: URL, _ arguments: String...) throws -> String {
    _ = compositeConfig
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
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// A repository with a bare remote and another working copy that pushes to it.
private struct Part {
    let local: URL, remote: URL, other: URL
    init(_ root: URL, _ name: String, branch: String) throws {
        remote = root.appendingPathComponent("\(name).git")
        local = root.appendingPathComponent(name)
        other = root.appendingPathComponent("\(name)-otro")
        for folder in [remote, local] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        try git(remote, "init", "-q", "--bare", "-b", branch)
        try git(local, "init", "-q", "-b", branch)
        try "base\n".write(to: local.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try git(local, "add", "README.md")
        try git(local, "commit", "-q", "-m", "chore: base")
        try git(local, "remote", "add", "origin", remote.path)
        try git(local, "push", "-q", "-u", "origin", branch)
        try git(root, "clone", "-q", remote.path, other.path)
    }
    /// Someone else sends a commit: the local copy has one to bring.
    func remoteCommit(_ text: String) throws {
        try "\(text)\n".write(to: other.appendingPathComponent("\(text).txt"), atomically: true, encoding: .utf8)
        try git(other, "add", ".")
        try git(other, "commit", "-q", "-m", "feat: \(text)")
        try git(other, "push", "-q", "origin", "HEAD")
    }
}

@MainActor @Test func pullAllBringsEveryRepositoryOfTheProject() async throws {
    guard ProcessInfo.processInfo.environment["BUTAKE_STACK_HOME"] != nil else { return }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("stack-p39-\(UUID().uuidString)").resolvingSymlinksInPath()
    defer { try? FileManager.default.removeItem(at: root) }
    let web = try Part(root, "salud-web", branch: "develop")
    let app = try Part(root, "salud-app", branch: "main")
    let infra = try Part(root, "infra", branch: "main")
    try web.remoteCommit("web-nueva")
    try app.remoteCommit("api-nueva")
    try infra.remoteCommit("terraform")
    // A change of the user's own in the web: bringing down never touches it.
    try "mío\n".write(to: web.local.appendingPathComponent("notas.txt"), atomically: true, encoding: .utf8)

    let store = StackStore(engine: StackEngine())
    let _: [ToolInfo] = try await store.call(["method": "pluginSetEnabled", "id": "git", "enabled": true])
    let entries = [GitRepositoryEntry(path: web.local.path, name: "salud-web", project: "salud-web", missing: false),
                   GitRepositoryEntry(path: app.local.path, name: "salud-app", project: "salud-app", missing: false),
                   GitRepositoryEntry(path: infra.local.path, name: "infra", project: nil, missing: false),
                   GitRepositoryEntry(path: root.appendingPathComponent("ya-no-esta").path, name: "ya-no-esta", project: nil, missing: true)]

    // «Actualizar todo» asks and changes nothing in the folders.
    let before = try git(web.local, "rev-parse", "HEAD")
    #expect(await CompositeGit.fetchAll(entries, store: store).isEmpty)
    #expect(try git(web.local, "rev-parse", "HEAD") == before)
    let asked: GitSnapshot = try await store.call(["method": "gitSnapshot", "path": app.local.path, "limit": 1])
    #expect(asked.behind == 1)

    // «Bajar todo» brings each one to its remote, on its own branch, and nothing is sent.
    #expect(await CompositeGit.pullAll(entries, store: store).isEmpty)
    for part in [web, app, infra] {
        #expect(try git(part.local, "rev-parse", "HEAD") == git(part.other, "rev-parse", "HEAD"))
    }
    #expect(try git(web.local, "branch", "--show-current") == "develop")
    #expect(try git(app.local, "branch", "--show-current") == "main")
    #expect(FileManager.default.fileExists(atPath: web.local.appendingPathComponent("notas.txt").path))
    #expect(try git(web.local, "status", "--porcelain").contains("notas.txt"))

    // A remote that is gone is that repository's failure; the others still come down.
    try app.remoteCommit("otra")
    try FileManager.default.removeItem(at: infra.remote)
    let failures = await CompositeGit.pullAll(entries, store: store)
    #expect(Set(failures.keys) == [infra.local.path])
    #expect(try git(app.local, "rev-parse", "HEAD") == git(app.other, "rev-parse", "HEAD"))
}

/// The Git tool lists a repository added by hand to a project, groups the project's
/// repositories, and a part's repository belongs to its project.
@MainActor @Test func theToolGroupsTheRepositoriesOfAProject() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("stack-p39-tool-\(UUID().uuidString)").resolvingSymlinksInPath()
    defer { try? FileManager.default.removeItem(at: root) }
    let infra = root.appendingPathComponent("infra")
    try FileManager.default.createDirectory(at: infra.appendingPathComponent(".git"), withIntermediateDirectories: true)
    let store = StackStore.shared
    let tool = GitTool.shared
    let saved = (store.groups, tool.list)
    defer { store.groups = saved.0; tool.list = saved.1 }
    tool.list = GitRepositoryList(projects: [.init(id: "salud-web", name: "Salud Web", path: "/tmp/salud-web"),
                                             .init(id: "suelto", name: "Suelto", path: "/tmp/suelto")])
    store.groups = [ProjectGroup(id: "salud", name: "Salud", sites: ["salud-web"], kind: .project, repositories: [infra.path, "/tmp/no-existe"])]
    let entries = tool.entries(of: store.groups[0])
    #expect(entries.map(\.name) == ["Salud Web", "infra", "no-existe"])
    #expect(entries.map(\.missing) == [false, false, true])
    #expect(tool.composite(of: entries[1])?.id == "salud")
    #expect(tool.composite(of: tool.entries.first { $0.project == "suelto" }!) == nil)
    // Back to a folder: the repositories are kept, but no longer grouped.
    store.groups[0].kind = .folder
    #expect(tool.composite(of: entries[0]) == nil)
    #expect(store.groups[0].repositories.count == 2)
}
