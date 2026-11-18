import Foundation
import Testing
@testable import ButakeStack

// Dumps and the terminal: a path from a dump is data, and a closed tab starts nothing.

@Test func aDumpOpensOnlyATextFileInsideAProject() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("stack-dump-\(UUID().uuidString)").resolvingSymlinksInPath()
    defer { try? FileManager.default.removeItem(at: root) }
    let project = root.appendingPathComponent("tienda"), outside = root.appendingPathComponent("otro")
    for folder in [project, outside] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
    let code = project.appendingPathComponent("index.php"), image = project.appendingPathComponent("icono.png")
    let elsewhere = outside.appendingPathComponent("secreto.php"), link = project.appendingPathComponent("enlace.php")
    for file in [code, image, elsewhere] { try "x".write(to: file, atomically: true, encoding: .utf8) }
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: elsewhere)
    let folders = [project.path]
    #expect(DumpFile.target(code.path, projectFolders: folders) == code)
    #expect(DumpFile.target(image.path, projectFolders: folders) == nil)
    #expect(DumpFile.target(elsewhere.path, projectFolders: folders) == nil)
    #expect(DumpFile.target(link.path, projectFolders: folders) == nil)
    #expect(DumpFile.target(project.path, projectFolders: folders) == nil)
    #expect(DumpFile.target("relativo/index.php", projectFolders: folders) == nil)
    #expect(DumpFile.target(code.path, projectFolders: []) == nil)
}

@MainActor @Test func aTerminalClosedBeforeItStartsNeverStartsAProcess() async {
    let session = TerminalSession(kind: .ssh("no-existe"), title: "prueba")
    session.terminate()
    #expect(session.closed)
    await session.start()
    #expect(!session.running && session.exitCode == nil)
}
