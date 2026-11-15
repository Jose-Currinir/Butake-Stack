import Foundation
import Testing
@testable import ButakeStack

/// Every kind of project has a suggested place: the ones «Nuevo proyecto» creates and the ones the
/// engine detects (read from its `ProjectKind`, so a kind added there without a place fails here).
@Test func everyKindOfProjectHasAPlace() throws {
    let expected: [String: ProjectPlace] = [
        "laravel": .web, "php": .web, "astro": .web, "emdash": .web, "next": .web, "vite": .web,
        "static": .web, "django": .web, "proxy": .web,
        "swift": .app, "react-native": .app, "kmp": .app,
        "rust": .service, "node": .service, "fastapi": .service, "unserved": .service,
    ]
    let model = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../../engine/src/core/model.rs").standardizedFileURL
    let source = try String(contentsOf: model, encoding: .utf8)
    let block = try #require(source.components(separatedBy: "pub enum ProjectKind {").dropFirst().first?.components(separatedBy: "\n}").first)
    let engineKinds = block.split(separator: "\n").compactMap { line -> String? in
        let text = line.trimmingCharacters(in: .whitespaces)
        guard text.hasSuffix(","), text.first?.isUppercase == true else { return nil }
        return text.dropLast().lowercased()
    }
    #expect(engineKinds.count >= 12)
    let kinds = Set(engineKinds).union(ProjectKindInfo.all.map(\.id))
    for kind in kinds {
        #expect(ProjectPlace.suggested(kind: kind) != nil, "Sin carpeta sugerida: \(kind)")
        #expect(ProjectPlace.suggested(kind: kind) == expected[kind], "\(kind)")
    }
    // A Swift command or library is not an app.
    #expect(ProjectPlace.suggested(kind: "swift", template: "executable") == .app)
    #expect(ProjectPlace.suggested(kind: "swift", template: "tool") == .service)
    #expect(ProjectPlace.suggested(kind: "swift", template: "library") == .service)
    #expect(ProjectPlace.suggested(kind: "otro") == nil)
    #expect(ProjectPlace.allCases.map(\.folder) == ["App", "Service", "Web"])
}

/// New projects go to App, Service or Web inside the projects folder unless sorting is off in
/// Ajustes › Avanzado; nothing is created until a project is.
@Test func newProjectsGoToTheirPlace() throws {
    let suite = "stack.tests.places.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    #expect(Folder.sortsByPlace(defaults: defaults))
    #expect(Folder.newProjects(in: .web, home: home, defaults: defaults) == home + "/Stack/Projects/Web")
    #expect(Folder.newProjects(in: .app, home: home, defaults: defaults) == home + "/Stack/Projects/App")
    Folder.setProjects(home + "/Trabajo", home: home, defaults: defaults)
    #expect(Folder.newProjects(in: .service, home: home, defaults: defaults) == home + "/Trabajo/Service")
    defaults.set(false, forKey: Folder.sortsKey)
    #expect(Folder.newProjects(in: .service, home: home, defaults: defaults) == home + "/Trabajo")
    #expect(!FileManager.default.fileExists(atPath: home))
}

/// The engine lists a project whose folder is gone marked `missing`; the mark never goes back in
/// what the app saves.
@Test func aProjectWithoutItsFolderIsMarked() throws {
    let record = #"{"id":"tienda","name":"Tienda","path":"/no/existe","domains":["tienda.test"],"https":false,"kind":"static","runtime":{},"docroot":".","services":[],"databases":[],"processes":[],"enabled":false"#
    let missing = try JSONDecoder().decode(Project.self, from: Data((record + #","missing":true}"#).utf8))
    let present = try JSONDecoder().decode(Project.self, from: Data((record + "}").utf8))
    #expect(missing.isMissing)
    #expect(!present.isMissing)
    let saved = try JSONSerialization.jsonObject(with: JSONEncoder().encode(present)) as? [String: Any]
    #expect(saved?["missing"] == nil)
}
