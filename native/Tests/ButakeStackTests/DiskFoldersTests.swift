import Foundation
import Testing
@testable import ButakeStack

// The sidebar follows the folders of the disk: the tree nests, a project moved in Finder is
// followed, a folder that is gone is «No encontrado», a repository that is new is offered, a drag
// moves the folder on the disk and the first comparison with `groups.json` converts what matches.
// Everything runs on temporary folders and a temporary store: never ~/Stack nor the owner's data.

@MainActor private struct Disk {
    let root: URL
    let store: URL
    let engine: StackEngine
    let model: StackStore

    /// A projects folder with these repositories (an empty `.git` is enough) and a project for each
    /// one named in `projects` (id: relative folder).
    init(repositories: [String], projects: [String: String]) throws {
        guard let (engine, store) = try isolatedEngine() else { throw SkipDisk() }
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("disco-\(UUID().uuidString)", isDirectory: true)
        let projectsFolder = base.appendingPathComponent("Proyectos", isDirectory: true)
        for repository in repositories {
            try FileManager.default.createDirectory(at: projectsFolder.appendingPathComponent(repository + "/.git"), withIntermediateDirectories: true)
        }
        // The engine reads the folder canonical (a temporary folder is a link to /private).
        // (`resolvingSymlinksInPath` drops the «/private» the engine keeps.)
        root = URL(fileURLWithPath: realpath(projectsFolder.path, nil).map { String(cString: $0) } ?? projectsFolder.path, isDirectory: true)
        let folder = store.appendingPathComponent("projects", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (id, relative) in projects {
            let record: [String: Any] = ["id": id, "name": id, "path": root.appendingPathComponent(relative).path, "domains": ["\(id).test"], "https": false,
                                         "kind": "static", "runtime": [:], "docroot": ".", "services": [], "databases": [], "processes": []]
            try JSONSerialization.data(withJSONObject: record).write(to: folder.appendingPathComponent("\(id).json"))
        }
        self.store = store
        self.engine = engine
        model = StackStore(engine: engine)
    }
    func refresh() async { await model.refreshDisk(root: root.path) }
    func project(_ id: String) -> Project? { model.projects.first { $0.id == id } }
    func group(_ path: String) -> ProjectGroup? { model.groups.first { $0.path == path } }
    func remove() { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
}
private struct SkipDisk: Error {}

@Test func aFolderKeepsItsPlaceOnTheDiskAndOlderOnesDoNot() throws {
    let group = ProjectGroup(id: "salud", name: "Salud", sites: ["a"], kind: .project, path: "Apps/Salud", parent: "apps")
    let back = try JSONDecoder().decode(ProjectGroup.self, from: JSONEncoder().encode(group))
    #expect(back == group && back.path == "Apps/Salud" && back.parent == "apps")
    let older = try JSONDecoder().decode(ProjectGroup.self, from: Data(#"{"id":"x","name":"X","sites":[]}"#.utf8))
    #expect(older.path == nil && older.parent == nil)
    let saved = try JSONSerialization.jsonObject(with: JSONEncoder().encode(older)) as? [String: Any]
    #expect(Set(saved?.keys.map { $0 } ?? []) == ["id", "name", "sites"])
}

@MainActor @Test func theSidebarNestsFoldersAsDeepAsTheDiskGoes() {
    let store = StackStore()
    store.groups = [
        ProjectGroup(id: "apps", name: "Apps", sites: [], path: "Apps"),
        ProjectGroup(id: "salud", name: "Salud", sites: [], kind: .project, path: "Apps/Salud", parent: "apps"),
        ProjectGroup(id: "mas", name: "Mas", sites: [], path: "Apps/Salud/Mas", parent: "salud"),
        ProjectGroup(id: "sitios", name: "Sitios", sites: [], path: "Sitios"),
    ]
    #expect(store.folderTree.map(\.depth) == [0, 1, 2, 0])
    #expect(store.ancestors(of: store.groups[2]).map(\.id) == ["salud", "apps"])
    #expect(store.ancestors(of: store.groups[3]).isEmpty)
    store.disk = DiskState(enabled: true, root: "/tmp/qa", newRepos: [NewRepository(path: "/tmp/qa/Apps/Nuevo", name: "Nuevo", folder: "apps")],
                           suggestions: [MultipartSuggestion(path: "Sitios", folder: "sitios", name: "Sitios", parts: ["Web", "Web-Api"])])
    #expect(store.newRepositories(in: "apps").map(\.title) == ["Nuevo"])
    #expect(store.newRepositories(in: nil).isEmpty)
    #expect(store.suggestion(for: store.groups[3])?.parts == ["Web", "Web-Api"])
    // A folder that is already a project is not suggested again.
    #expect(store.suggestion(for: store.groups[1]) == nil)
}

@MainActor @Test func theTreeComesFromTheFolderAndNewRepositoriesAreOffered() async throws {
    let disk: Disk
    do { disk = try Disk(repositories: ["Apps/Uno", "Apps/Salud/Salud", "Apps/Salud/Salud-Web", "Apps/Nuevo"],
                         projects: ["uno": "Apps/Uno", "salud": "Apps/Salud/Salud", "salud-web": "Apps/Salud/Salud-Web"]) } catch is SkipDisk { return }
    defer { disk.remove() }
    await disk.refresh()
    #expect(disk.model.followsDisk)
    let apps = try #require(disk.group("Apps"))
    let salud = try #require(disk.group("Apps/Salud"))
    #expect(apps.sites == ["uno"] && salud.sites == ["salud", "salud-web"] && salud.parent == apps.id)
    // Offered with «Agregar», never added alone.
    #expect(disk.model.disk?.newRepos.map(\.title) == ["Nuevo"])
    #expect(disk.model.newRepositories(in: apps.id).count == 1)
    #expect(disk.model.projects.count == 3)
    // Two repositories of a prefix are suggested as a project of several parts.
    #expect(disk.model.suggestion(for: salud)?.parts.sorted() == ["Salud", "Salud-Web"])
    disk.model.setKind(salud.id, .project)
    try await Task.sleep(for: .milliseconds(800))
    #expect(disk.model.groups.first { $0.path == "Apps/Salud" }?.isProject == true)
}

@MainActor @Test func aProjectMovedInFinderIsFollowedAndAFolderThatIsGoneIsMissing() async throws {
    let disk: Disk
    do { disk = try Disk(repositories: ["Apps/Tienda", "Apps/Viejo", "Sitios/x"], projects: ["tienda": "Apps/Tienda", "viejo": "Apps/Viejo"]) } catch is SkipDisk { return }
    defer { disk.remove() }
    await disk.refresh()
    let domains = disk.project("tienda")?.domains
    // Moved in Finder.
    try FileManager.default.moveItem(at: disk.root.appendingPathComponent("Apps/Tienda"), to: disk.root.appendingPathComponent("Sitios/Tienda"))
    // Deleted in Finder.
    try FileManager.default.removeItem(at: disk.root.appendingPathComponent("Apps/Viejo"))
    await disk.refresh()
    #expect(disk.project("tienda")?.path == disk.root.appendingPathComponent("Sitios/Tienda").path)
    #expect(disk.project("tienda")?.domains == domains && disk.project("tienda")?.isMissing == false)
    #expect(disk.model.disk?.moves.map(\.id) == ["tienda"])
    #expect(disk.group("Sitios")?.sites.contains("tienda") == true)
    // «No encontrado»: listed, off, with its record as it was, outside every folder.
    let missing = try #require(disk.project("viejo"))
    #expect(missing.isMissing && !missing.enabled && missing.path == disk.root.appendingPathComponent("Apps/Viejo").path)
    #expect(disk.model.ungroupedProjects.contains { $0.id == "viejo" })
}

@MainActor @Test func draggingMovesTheFolderOnTheDiskAfterAskingAndItCanBeUndone() async throws {
    let disk: Disk
    do { disk = try Disk(repositories: ["Apps/Uno", "Sitios/Web"], projects: ["uno": "Apps/Uno", "web": "Sitios/Web"]) } catch is SkipDisk { return }
    defer { disk.remove() }
    await disk.refresh()
    let sitios = try #require(disk.group("Sitios"))
    // Into the folder it already is in: nothing to ask.
    disk.model.requestDiskMove("web", into: sitios.id)
    #expect(disk.model.pendingDiskMove == nil)
    disk.model.requestDiskMove("uno", into: sitios.id)
    let request = try #require(disk.model.pendingDiskMove)
    #expect(request.title == "uno" && request.intoName == "Sitios" && request.from == disk.root.appendingPathComponent("Apps/Uno").path)
    #expect(FileManager.default.fileExists(atPath: disk.root.appendingPathComponent("Apps/Uno").path), "nothing moves before the yes")
    disk.model.pendingDiskMove = nil
    await disk.model.performDiskMove(request)
    #expect(!FileManager.default.fileExists(atPath: disk.root.appendingPathComponent("Apps/Uno").path))
    #expect(disk.project("uno")?.path == disk.root.appendingPathComponent("Sitios/Uno").path)
    #expect(disk.group("Sitios")?.sites.sorted() == ["uno", "web"])
    // A folder moves too, with the projects in it; one into itself is never asked.
    let apps = try #require(disk.group("Apps"))
    disk.model.requestDiskMove(StackStore.folderDragPrefix + sitios.id, into: sitios.id)
    #expect(disk.model.pendingDiskMove == nil)
    disk.model.requestDiskMove(StackStore.folderDragPrefix + apps.id, into: sitios.id)
    let folderMove = try #require(disk.model.pendingDiskMove)
    disk.model.pendingDiskMove = nil
    await disk.model.performDiskMove(folderMove)
    #expect(disk.group("Sitios/Apps") != nil)
    // Undo: the same move the other way.
    let back: DiskMoved = try await disk.model.call(["method": "diskMove", "path": disk.root.appendingPathComponent("Sitios/Apps").path, "into": disk.root.path])
    #expect(back.to == disk.root.appendingPathComponent("Apps").path)
}

@MainActor @Test func theFirstComparisonConvertsWhatMatchesAndProposesTheRest() async throws {
    let disk: Disk
    do { disk = try Disk(repositories: ["Apps/Uno", "Apps/Dos", "A/suelto", "B/otro"],
                         projects: ["uno": "Apps/Uno", "dos": "Apps/Dos", "suelto": "A/suelto", "otro": "B/otro"]) } catch is SkipDisk { return }
    defer { disk.remove() }
    let older = [["id": "apps", "name": "Apps", "sites": ["uno", "dos"]], ["id": "mezcla", "name": "Mezcla", "sites": ["suelto", "otro"]]]
    let _: [ProjectGroup] = try await disk.engine.call(["method": "saveSiteGroups", "groups": older])
    await disk.refresh()
    // The sidebar stays on the groups until the user decides about what does not match.
    #expect(!disk.model.followsDisk)
    let plan = try #require(disk.model.disk?.migration)
    #expect(plan.matches.map(\.name) == ["Apps"] && plan.proposals.map(\.name) == ["Mezcla"] && plan.proposals[0].moves.count == 2)
    #expect(FileManager.default.fileExists(atPath: disk.root.appendingPathComponent("A/suelto").path), "the preview moves nothing")
    await disk.model.migrateToDisk(accept: true)
    #expect(disk.model.followsDisk && disk.model.disk?.migration == nil)
    #expect(disk.group("Mezcla")?.sites.sorted() == ["otro", "suelto"])
    #expect(disk.group("Apps")?.sites.sorted() == ["dos", "uno"])
    // groups.json is still there, readable, with the groups of before.
    let kept = try Data(contentsOf: disk.store.appendingPathComponent("groups.json"))
    #expect(String(decoding: kept, as: UTF8.self).contains("mezcla"))
    #expect(FileManager.default.fileExists(atPath: disk.store.appendingPathComponent("groups.pre-disk.json").path))
}
