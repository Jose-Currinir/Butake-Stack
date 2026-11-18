import Foundation
import Testing
@testable import ButakeStack

// The project's summary, processes and Entornos, and Inicio's folders (UI barrido B). Everything
// runs on temporary folders and in-memory values: never the owner's projects, Keychain or files.

private func scratch(_ name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func project(_ id: String) -> Project {
    Project(id: id, name: id, path: "/tmp/\(id)", domains: ["\(id).test"], https: false, kind: "static", runtime: [:], docroot: ".",
            services: [], databases: [], processes: [], enabled: false)
}

// MARK: .gitignore

@Test func theGitignoreLineIsAddedAtTheEndWithItsOwnNewline() {
    #expect(GitignoreFix.adding(to: nil) == ".env\n")
    #expect(GitignoreFix.adding(to: "") == ".env\n")
    #expect(GitignoreFix.adding(to: "vendor/\n") == "vendor/\n.env\n")
    #expect(GitignoreFix.adding(to: "vendor/") == "vendor/\n.env\n")
    #expect(GitignoreFix.adding(to: "vendor/\n.env\n") == nil)
    #expect(GitignoreFix.adding(to: "/.env  \n") == nil)
}

@Test func theGitignoreIsCreatedChangedAndPutBack() throws {
    let folder = try scratch("gitignore")
    defer { try? FileManager.default.removeItem(at: folder) }
    // Missing: created, and undone by removing it.
    let created = try #require(try GitignoreFix.add(inProject: folder.path))
    #expect(created.before == nil)
    #expect(try String(contentsOf: created.url, encoding: .utf8) == ".env\n")
    #expect(GitignoreFix.undo(created))
    #expect(!FileManager.default.fileExists(atPath: created.url.path))
    #expect(GitignoreFix.redo(created))
    #expect(try String(contentsOf: created.url, encoding: .utf8) == ".env\n")
    try FileManager.default.removeItem(at: created.url)

    // Existing: the user's lines stay, and undo restores them byte for byte.
    let url = GitignoreFix.url(in: folder.path)
    try "node_modules/\n# mío\n".write(to: url, atomically: true, encoding: .utf8)
    let changed = try #require(try GitignoreFix.add(inProject: folder.path))
    #expect(try String(contentsOf: url, encoding: .utf8) == "node_modules/\n# mío\n.env\n")
    #expect(try GitignoreFix.add(inProject: folder.path) == nil)
    // The user edited it after: undo leaves the file alone.
    try "otro\n".write(to: url, atomically: true, encoding: .utf8)
    #expect(!GitignoreFix.undo(changed))
    #expect(try String(contentsOf: url, encoding: .utf8) == "otro\n")
}

@Test func aLinkedGitignoreIsNeverWritten() throws {
    let folder = try scratch("gitignore-link")
    defer { try? FileManager.default.removeItem(at: folder) }
    let target = folder.appendingPathComponent("elsewhere")
    try "x\n".write(to: target, atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(at: GitignoreFix.url(in: folder.path), withDestinationURL: target)
    #expect(throws: GitignoreFix.Failure.symlink) { try GitignoreFix.add(inProject: folder.path) }
    #expect(try String(contentsOf: target, encoding: .utf8) == "x\n")
}

// MARK: .env dropped

@Test func onlyEnvFilesOfReasonableSizeAreAcceptedWhenDropped() throws {
    let folder = try scratch("drop")
    defer { try? FileManager.default.removeItem(at: folder) }
    func file(_ name: String, bytes: Int = 8) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data(repeating: 97, count: bytes).write(to: url)
        return url
    }
    #expect(EnvImportFile.accepts(try file(".env")))
    #expect(EnvImportFile.accepts(try file(".env.local")))
    #expect(EnvImportFile.accepts(try file("production.env")))
    #expect(!EnvImportFile.accepts(try file("notas.txt")))
    #expect(!EnvImportFile.accepts(try file("grande.env", bytes: EnvImportFile.maxBytes + 1)))
    #expect(!EnvImportFile.accepts(folder.appendingPathComponent("no-existe.env")))
    let link = folder.appendingPathComponent("enlace.env")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder.appendingPathComponent(".env"))
    #expect(!EnvImportFile.accepts(link))
    let directory = folder.appendingPathComponent("carpeta.env")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    #expect(!EnvImportFile.accepts(directory))
}

// MARK: Versions and processes

@MainActor @Test func versionChoicesAreInstalledOnesPlusTheCurrentInNumericOrder() {
    #expect(ProjectVersionRow.choices(key: "php", installed: ["8.4", "8.10", "8.2"], current: "8.3") == ["8.2", "8.3", "8.4", "8.10"])
    #expect(ProjectVersionRow.choices(key: "node", installed: ["22", "22", "20"], current: "22") == ["20", "22"])
    #expect(ProjectVersionRow.choices(key: "jdk", installed: [], current: nil).isEmpty)
    #expect(ProjectVersionRow.language(of: "jdk") == "java")
    #expect(ProjectVersionRow.language(of: "php") == "php")
}

@MainActor @Test func batchActionsTouchOnlyWhatTheyChange() {
    let ids = ["p.web", "p.queue", "p.vite"]
    let live: Set<String> = ["p.web", "p.vite"]
    #expect(ProcessBatchMenu.targets("start", ids: ids, live: live) == ["p.queue"])
    #expect(ProcessBatchMenu.targets("stop", ids: ids, live: live) == ["p.web", "p.vite"])
    #expect(ProcessBatchMenu.targets("restart", ids: ids, live: live) == ["p.web", "p.vite"])
    #expect(ProcessBatchMenu.targets("restart", ids: ids, live: []).isEmpty)
}

// MARK: Folders

@MainActor @Test func aFolderCountsEveryProjectInsideIt() {
    let store = StackStore(engine: StackEngine())
    store.projects = ["a", "b", "c", "d"].map(project)
    store.groups = [
        ProjectGroup(id: "apps", name: "Apps", sites: ["a", "b"]),
        ProjectGroup(id: "salud", name: "Salud", sites: ["c"], parent: "apps"),
        ProjectGroup(id: "gestion", name: "Gestión", sites: ["d", "a"], parent: "apps"),
        ProjectGroup(id: "otra", name: "Otra", sites: []),
    ]
    #expect(store.projects(in: store.groups[0]).map(\.id) == ["a", "b"])
    #expect(store.projects(inside: store.groups[0]).map(\.id) == ["a", "b", "c", "d"])
    #expect(store.projects(inside: store.groups[1]).map(\.id) == ["c"])
    #expect(store.projects(inside: store.groups[3]).isEmpty)
    // A folder inside a folder inside a folder.
    store.groups.append(ProjectGroup(id: "hondo", name: "Hondo", sites: ["b"], parent: "salud"))
    #expect(Set(store.projects(inside: store.groups[1]).map(\.id)) == ["c", "b"])
    #expect(store.projects(inside: store.groups[0]).count == 4)
}
