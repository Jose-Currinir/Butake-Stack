import Foundation
import Testing
@testable import ButakeStack

// Projects of several parts (P-39): a folder marked as a project. An older `groups.json` opens and
// saves the same, a folder writes no new key, turning a project back into a folder keeps
// everything, and the engine keeps the parts, repositories and Google Cloud link its parts inherit.
// Everything runs against temporary stores and folders: never the owner's data.

private func temporaryFolder(_ name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test func anOlderGroupReadsAsAFolderAndSavesTheSame() throws {
    let older = #"[{"id":"apps","name":"Apps","sites":["uno","dos"]},{"id":"web","name":"Web","sites":[]}]"#
    let groups = try JSONDecoder().decode([ProjectGroup].self, from: Data(older.utf8))
    #expect(groups.allSatisfy { !$0.isProject && $0.repositories.isEmpty && !$0.ordered && $0.gcp == nil })
    let saved = try JSONSerialization.jsonObject(with: JSONEncoder().encode(groups)) as? [[String: Any]]
    #expect(saved?.map { Set($0.keys) } == [["id", "name", "sites"], ["id", "name", "sites"]])
    // A kind this version does not know is a folder, not an error.
    let unknown = try JSONDecoder().decode(ProjectGroup.self, from: Data(#"{"id":"x","name":"X","sites":[],"kind":"otro"}"#.utf8))
    #expect(unknown.kind == .folder)
}

@Test func aProjectOfSeveralPartsRoundTrips() throws {
    let group = ProjectGroup(id: "salud", name: "Salud", sites: ["salud-app", "salud-web"], kind: .project,
                             repositories: ["/tmp/qa/infra"], ordered: true, gcp: GCPLink(account: "qa@ejemplo.test", project: "salud-ficticia"))
    let data = try JSONEncoder().encode(group)
    #expect(try JSONDecoder().decode(ProjectGroup.self, from: data) == group)
    let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    #expect(object?["kind"] as? String == "project")
    var folder = group
    folder.kind = .folder
    let back = try JSONSerialization.jsonObject(with: JSONEncoder().encode(folder)) as? [String: Any]
    #expect(back?["kind"] == nil)
    #expect((back?["repositories"] as? [String]) == ["/tmp/qa/infra"])
    #expect(back?["gcp"] != nil)
}

/// Through the engine: convert, add a repository, link Google Cloud, back to a folder and again,
/// and nothing is lost on the way.
@Test func theEngineKeepsAProjectWhenItGoesBackToAFolder() async throws {
    guard let (engine, store) = try isolatedEngine() else { return }
    let older = #"[{"id":"salud","name":"Salud","sites":["web","app"]}]"#
    try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
    try Data(older.utf8).write(to: store.appendingPathComponent("groups.json"))
    var groups: [ProjectGroup] = try await engine.call(["method": "siteGroups"])
    try #require(groups.count == 1)
    #expect(!groups[0].isProject)
    groups[0].kind = .project
    groups[0].repositories = ["/tmp/qa/infraestructura"]
    groups[0].ordered = true
    let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(groups))
    let _: [ProjectGroup] = try await engine.call(["method": "saveSiteGroups", "groups": object])
    let _: [ToolInfo] = try await engine.call(["method": "pluginSetEnabled", "id": "gcp", "enabled": true])
    let linked: ProjectGroup = try await engine.call(["method": "gcpLinkGroup", "id": "salud", "account": "qa@ejemplo.test", "project": "salud-ficticia"])
    #expect(linked.gcp?.project == "salud-ficticia")
    groups = try await engine.call(["method": "siteGroups"])
    groups[0].kind = .folder
    let folder = try JSONSerialization.jsonObject(with: JSONEncoder().encode(groups))
    let back: [ProjectGroup] = try await engine.call(["method": "saveSiteGroups", "groups": folder])
    try #require(back.count == 1)
    #expect(!back[0].isProject)
    #expect(back[0].sites == ["web", "app"] && back[0].repositories == ["/tmp/qa/infraestructura"] && back[0].ordered)
    #expect(back[0].gcp == GCPLink(account: "qa@ejemplo.test", project: "salud-ficticia"))
    let written = try String(contentsOf: store.appendingPathComponent("groups.json"), encoding: .utf8)
    #expect(!written.contains("\"kind\""))
    do {
        let _: [ProjectGroup] = try await engine.call(["method": "saveSiteGroups", "groups": [["id": "x", "name": "X", "sites": [], "repositories": ["relativa"]]]])
        Issue.record("A relative repository must be refused")
    } catch is EngineFailure {}
    try? FileManager.default.removeItem(at: store.deletingLastPathComponent())
}

@Test func dependenciesBetweenPartsAreFound() {
    func part(_ id: String, env: [String: String] = [:], args: [String] = []) -> Project {
        Project(id: id, name: id, path: "/tmp/\(id)", domains: ["\(id).test"], https: false, kind: "static", runtime: [:], docroot: ".",
                services: [], databases: [], processes: [ProjectProcess(name: "dev", program: "npm", args: args, autostart: true)],
                enabled: false, env: env)
    }
    let parts = [part("app"), part("web", env: ["API_URL": "http://127.0.0.1:{port:app}", "OTRO": "{port:ajeno}"], args: ["--public", "{public:app}", "{port:web}"])]
    let found = PartDependency.among(parts)
    #expect(found.map(\.id) == ["web>port>app", "web>public>app"])
}

@Test func aRepositoryIsFoundFromAnyFolderInside() throws {
    let root = try temporaryFolder("repositorio")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
    let inside = root.appendingPathComponent("src/lib", isDirectory: true)
    try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
    #expect(StackStore.repositoryRoot(of: inside.path) == root.path)
    let outside = try temporaryFolder("sin-repositorio")
    defer { try? FileManager.default.removeItem(at: outside) }
    #expect(StackStore.repositoryRoot(of: outside.path) == nil)
}

@Test func routeAndRowOfAProjectOfSeveralParts() {
    #expect(Route(storageValue: "composite:salud") == .composite("salud"))
    #expect(Route.composite("salud").storageValue == "composite:salud")
    #expect(Route(storageValue: "composite:") == nil)
    #expect(SidebarRow.of(.composite("salud")) == .composite("salud"))
}

/// An app linked to a project of several parts reaches each of its parts; one linked to a part
/// only reaches that part.
@MainActor @Test func partsInheritTheVaultLinkOfTheirProject() {
    let index = VaultIndex(containers: [
        VaultContainer(kind: .app, name: "Salud", project: VaultProjects.link(composite: "salud")),
        VaultContainer(kind: .app, name: "Panel web", project: "web"),
        VaultContainer(kind: .app, name: "Otra", project: "otra"),
    ])
    #expect(VaultProjects.composite(of: "group:salud") == "salud")
    #expect(VaultProjects.composite(of: "salud") == nil)
    #expect(VaultProjects.apps(of: "web", composite: "salud", in: index).map(\.name) == ["Panel web", "Salud"])
    #expect(VaultProjects.apps(of: "app", composite: "salud", in: index).map(\.name) == ["Salud"])
    #expect(VaultProjects.apps(of: "web", in: index).map(\.name) == ["Panel web"])
    #expect(VaultProjects.apps(of: VaultProjects.link(composite: "salud"), in: index).map(\.name) == ["Salud"])
}
