import Foundation
import Testing
@testable import ButakeStack

/// `butakestack://open` and `git/open` act only on a real folder, written as a normalized absolute path.
@Test func aLinkedFolderMustExistAndBeAFolder() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("link-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root.appendingPathComponent("a"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("x".utf8).write(to: root.appendingPathComponent("file.txt"))
    let folder = root.appendingPathComponent("a").standardizedFileURL.path
    #expect(StackStore.linkedFolder(folder) == folder)
    #expect(StackStore.linkedFolder(folder + "/../a/") == folder)
    #expect(StackStore.linkedFolder(root.appendingPathComponent("file.txt").path) == nil)
    #expect(StackStore.linkedFolder(root.appendingPathComponent("missing").path) == nil)
    #expect(StackStore.linkedFolder("relative/folder") == nil)
    #expect(StackStore.linkedFolder(nil) == nil)
}
