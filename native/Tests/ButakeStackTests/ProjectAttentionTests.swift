import Foundation
import Testing
@testable import ButakeStack

/// P-42: projects without a server, what a project needs now and services in use.

private func unserved(processes: [ProjectProcess] = []) -> Project {
    Project(id: "lib", name: "Biblioteca", path: "/tmp/lib", domains: [], https: false, kind: Project.unserved,
            runtime: [:], docroot: ".", services: [], databases: [], processes: processes, enabled: false, technology: "swift")
}

/// A project without a server has no address nor switch, keeps its commands in Resumen (no
/// Procesos tab) and shows what it is built with.
@MainActor @Test func aProjectWithoutAServerHasNoAddressNorSwitch() {
    let check = ProjectProcess(name: "check", program: "swift", args: ["test"], autostart: false)
    let library = unserved(processes: [check])
    #expect(!library.isServed && library.url == nil)
    #expect(library.tech.id == "swift")
    #expect(ProjectPage(store: .shared, project: library).tabs == [.summary, .envs, .logs])
    #expect(ProjectCommandsSection.title("check") == L("commands.check"))
    #expect(ProjectCommandsSection.title("lint") == "lint")
    // Saved, the list's own fields stay out of the record.
    let saved = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(library)) as? [String: Any]
    #expect(saved?["kind"] as? String == "unserved")
}

/// The engine's items read as the app shows them, each with its words and its fix.
@MainActor @Test func attentionItemsReadAndSayWhatTheyAre() throws {
    let json = #"[{"code":"service_off","service":"postgres","fix":{"id":"startService","value":"postgres"}},"#
        + #"{"code":"port_conflict","port":4176,"other":"Butake Template"},"#
        + #"{"code":"node_mismatch","current":"22.23.5","wanted":">=24.13.0 <25","source":".nvmrc","fix":{"id":"setNode","value":"24"}}]"#
    let items = try JSONDecoder().decode([ProjectAttention].self, from: Data(json.utf8))
    let store = StackStore.shared
    #expect(store.attentionText(items[0]).contains("PostgreSQL"))
    #expect(store.fixTitle(items[0].fix!).contains("PostgreSQL"))
    #expect(store.attentionText(items[1]).contains("4176") && store.attentionText(items[1]).contains("Butake Template"))
    #expect(store.attentionText(items[2]).contains(".nvmrc"))
    #expect(store.fixTitle(items[2].fix!).contains("24"))
    for code in ["service_missing", "serves_repository", "serves_project_root", "unsafe_web_path", "program_missing", "script_missing", "script_forwards", "node_missing"] {
        #expect(store.attentionText(ProjectAttention(code: code)) != L("attention.other"), "\(code)")
    }
}

/// Against a temporary store: a repository without a server is proposed as such and never turns
/// on; a static site that serves its repository is said and becomes a project without a server.
@MainActor @Test func unservedProjectsAndTheirFixesThroughTheEngine() async throws {
    guard let (engine, _) = try isolatedEngine() else { return }
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("p42-\(UUID().uuidString)")
    let library = base.appendingPathComponent("Biblioteca")
    try FileManager.default.createDirectory(at: library.appendingPathComponent(".git"), withIntermediateDirectories: true)
    try "// swift-tools-version:6.0".write(to: library.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: base) }
    let detection: Detection = try await engine.call(["method": "detect", "path": library.path])
    #expect(detection.project.kind == Project.unserved && detection.project.domains.isEmpty)
    #expect(detection.project.processes.map(\.name) == ["check", "build"])
    let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(detection.project))
    let _: SavedProject = try await engine.call(["method": "saveProject", "project": object, "actor": "qa"])
    let listed: [Project] = try await engine.call(["method": "listProjects"])
    let saved = try #require(listed.first { $0.id == "biblioteca" })
    #expect(saved.technology == "swift" && !saved.isServed)
    // Saving what the list gave back works: `technology` never reaches the record.
    let again = try JSONSerialization.jsonObject(with: JSONEncoder().encode(saved))
    let _: SavedProject = try await engine.call(["method": "saveProject", "project": again, "actor": "qa"])
    await #expect(throws: EngineFailure.self) {
        let _: Project = try await engine.call(["method": "setSiteEnabled", "id": "biblioteca", "enabled": true])
    }

    // The same repository as a static site: it would publish its history.
    var site = saved
    site.kind = "static"
    site.domains = ["biblioteca.test"]
    let staticObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(site))
    let _: SavedProject = try await engine.call(["method": "saveProject", "project": staticObject, "actor": "qa"])
    let attention: [String: [ProjectAttention]] = try await engine.call(["method": "projectAttention"])
    #expect(attention["biblioteca"]?.map(\.code) == ["serves_repository"])
    let fixed: Project = try await engine.call(["method": "applyProjectFix", "id": "biblioteca", "fix": "makeUnserved", "process": ""])
    #expect(fixed.kind == Project.unserved && fixed.domains == ["biblioteca.test"])
}

/// Turning off a service that a project that is on uses asks first, naming it; the answer turns
/// it off. Turning the project on brings its services back and says so.
@MainActor @Test func aServiceInUseAsksBeforeStopping() async throws {
    guard let (engine, storeURL) = try isolatedEngine() else { return }
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("p42-api-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let projects = storeURL.appendingPathComponent("projects", isDirectory: true)
    try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
    let record: [String: Any] = ["id": "api", "name": "Salud API", "path": folder.path, "domains": ["api.test"], "https": false,
                                 "kind": "static", "runtime": [:], "docroot": ".", "services": ["postgres"], "databases": [],
                                 "processes": [], "enabled": true]
    try JSONSerialization.data(withJSONObject: record).write(to: projects.appendingPathComponent("api.json"))
    let model = StackStore(engine: engine)
    await model.setEngine("postgres", enabled: true)
    #expect(model.config?.engines?["postgres"]?.enabled == true)
    await model.setEngine("postgres", enabled: false)
    #expect(model.serviceStop?.users == "Salud API")
    #expect(model.config?.engines?["postgres"]?.enabled == true)
    await model.setEngine("postgres", enabled: false, confirmed: true)
    #expect(model.config?.engines?["postgres"]?.enabled == false)
    let log = try String(contentsOf: storeURL.appendingPathComponent("logs/services.log"), encoding: .utf8)
    #expect(log.split(separator: "\n").count == 2 && log.contains("\"actor\":\"app\""))
}
