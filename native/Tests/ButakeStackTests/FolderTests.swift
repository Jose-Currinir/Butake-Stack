import Foundation
import Testing
@testable import ButakeStack

/// New projects go to ~/Stack/Projects unless the user chose another folder; choosing the default
/// again forgets the choice, and nothing is created until an action needs the folder.
@Test func projectsFolderDefaultsToStackProjects() throws {
    let suite = "stack.tests.folders.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    #expect(Folder.projects(home: home, defaults: defaults) == home + "/Stack/Projects")
    #expect(!FileManager.default.fileExists(atPath: home + "/Stack"))
    Folder.setProjects(home + "/Trabajo/", home: home, defaults: defaults)
    #expect(Folder.projects(home: home, defaults: defaults) == home + "/Trabajo")
    Folder.setProjects(home + "/Stack/Projects", home: home, defaults: defaults)
    #expect(defaults.string(forKey: Folder.projectsKey) == nil)
    defaults.set("relativa/no", forKey: Folder.projectsKey)
    #expect(Folder.projects(home: home, defaults: defaults) == home + "/Stack/Projects")
    let made = Folder.ensureProjects(home + "/Stack/Projects")
    #expect(FileManager.default.fileExists(atPath: made.path))
    try FileManager.default.removeItem(atPath: home)
}

/// The app finds the data where the engine does (`Store::resolve`): an isolated store first, the
/// new folder once it holds data, the old one until it is moved, the new one on a new Mac.
@Test func dataFolderResolvesLikeTheEngine() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    defer { try? FileManager.default.removeItem(atPath: home) }
    let support = home + "/Library/Application Support/"
    #expect(Folder.resolveData(home: home, environment: ["BUTAKE_STACK_HOME": "/tmp/qa"]) == ("/tmp/qa", false))
    #expect(Folder.resolveData(home: home, environment: [:]) == (support + "Stack", false))
    try FileManager.default.createDirectory(atPath: support + "Butake Stack/projects", withIntermediateDirectories: true)
    #expect(Folder.resolveData(home: home, environment: [:]) == (support + "Butake Stack", true))
    try FileManager.default.createDirectory(atPath: support + "Stack", withIntermediateDirectories: true)
    #expect(Folder.resolveData(home: home, environment: [:]) == (support + "Butake Stack", true))
    try FileManager.default.createDirectory(atPath: support + "Stack/projects", withIntermediateDirectories: true)
    #expect(Folder.resolveData(home: home, environment: [:]) == (support + "Stack", false))
}
