import AppKit
import Foundation
import Testing
@testable import ButakeStack

private func project(processes: [ProjectProcess] = [], runtime: [String: String] = [:]) -> Project {
    Project(id: "qa", name: "Proyecto de prueba", path: "/tmp/qa", domains: ["qa.test"], https: false, kind: "static",
            runtime: runtime, docroot: ".", services: [], databases: [], processes: processes, enabled: false)
}

/// The project page has four tabs at most: Procesos only with processes, and no «Configuración»
/// (editing lives in «Ajustes del proyecto…»).
@MainActor @Test func projectTabsFollowTheProject() {
    let plain = ProjectPage(store: .shared, project: project())
    #expect(plain.tabs == [.summary, .envs, .logs])
    let worker = ProjectProcess(name: "queue", program: "php", args: ["artisan", "queue:work"], autostart: true)
    let busy = ProjectPage(store: .shared, project: project(processes: [worker]))
    #expect(busy.tabs == [.summary, .envs, .processes, .logs])
    #expect(!ProjectPage.Tab.allCases.map(\.rawValue).contains("environment"))
}

/// Resumen lists the versions in a fixed order, whatever the order of the stored settings.
@MainActor @Test func summaryListsVersionsInOrder() {
    let summary = ProjectSummary(store: .shared, project: project(runtime: ["python": "3.13", "php": "8.4", "node": "22"]))
    #expect(summary.runtimes.map(\.key) == ["php", "node", "python"])
}

/// Every literal text of the project pages and sheets has its Spanish text (`L` only asserts while
/// the view is drawn; this finds a missing key without opening each sheet).
@Test func projectTextsExist() throws {
    let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Sources/ButakeStack/Projects")
    let files = try #require(FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL })
    let pattern = try Regex(#"L\("([A-Za-z0-9_.\-]+)"\)"#)
    var keys: Set<String> = []
    for file in files where file.pathExtension == "swift" {
        let source = try String(contentsOf: file, encoding: .utf8)
        for match in source.matches(of: pattern) { if let key = match.output[1].substring { keys.insert(String(key)) } }
    }
    #expect(keys.count > 100)
    let missing = keys.filter { localized($0) == nil }.sorted()
    #expect(missing.isEmpty, "Missing texts: \(missing.joined(separator: ", "))")
}

/// ⌘⌫ «Quitar proyecto…»: the sidebar's project, else the page's one, never while typing.
@MainActor @Test func removeShortcutSkipsTextEditors() {
    #expect(ProjectRemoval.focus(of: NSTextView()) == .textEditor)
    #expect(ProjectRemoval.focus(of: NSTextField()) == .other)  // its field editor (an NSTextView) holds the keyboard
    #expect(ProjectRemoval.focus(of: NSButton()) == .other)
    #expect(ProjectRemoval.focus(of: nil) == .other)
    #expect(ProjectRemoval.target(focus: .other, listed: "lista", shown: "pagina") == "lista")
    #expect(ProjectRemoval.target(focus: .other, listed: nil, shown: "pagina") == "pagina")
    #expect(ProjectRemoval.target(focus: .textEditor, listed: nil, shown: "pagina") == nil)
    #expect(ProjectRemoval.target(focus: .textEditor, listed: "lista", shown: "pagina") == nil)
    #expect(ProjectRemoval.target(focus: .other, listed: String?.none, shown: nil) == nil)
}

/// Projects removed outside the app (the engine on the command line) leave the window on its next
/// reading, which runs every 15 seconds and whenever the app comes to the front.
@MainActor @Test func projectsChangedOutsideTheAppAreReadAgain() async throws {
    guard let (engine, store) = try isolatedEngine() else { return }
    try makeProject("uno", in: store)
    try makeProject("dos", in: store)
    let model = StackStore(engine: engine)
    await model.refreshProjects()
    #expect(model.projects.map(\.id).sorted() == ["dos", "uno"])
    let removed: RemovedProject = try await engine.call(["method": "deleteProject", "id": "dos"])
    #expect(removed.portDependents.isEmpty)
    await model.refreshProjects()
    #expect(model.projects.map(\.id) == ["uno"])
}
