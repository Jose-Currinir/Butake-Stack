import AppKit
import Foundation
import Testing
@testable import ButakeStack

// What the diff view draws for the engine's answer: an image only from inside the repository.

private func untracked(_ path: String) -> GitFile {
    GitFile(path: path, originalPath: nil, index: "?", worktree: "?")
}

@MainActor @Test func anImageOutsideTheRepositoryIsNotRead() throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("diff-content-\(UUID().uuidString)")
    let root = base.appendingPathComponent("repo")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    // A real image beside the repository, reached through `..` and through a link inside it.
    let image = NSImage(size: NSSize(width: 4, height: 4))
    image.lockFocus(); NSColor.red.setFill(); NSRect(x: 0, y: 0, width: 4, height: 4).fill(); image.unlockFocus()
    let tiff = try #require(image.tiffRepresentation)
    let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
    try png.write(to: base.appendingPathComponent("outside.png"))
    try png.write(to: root.appendingPathComponent("inside.png"))
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link.png"), withDestinationURL: base.appendingPathComponent("outside.png"))

    let inside = GitRepository.content("[Archivo binario]", file: untracked("inside.png"), root: root.path)
    if case .image = inside {} else { Issue.record("an image inside the repository is shown") }
    #expect(GitRepository.content("[Archivo binario]", file: untracked("../outside.png"), root: root.path) == .binary)
    #expect(GitRepository.content("[Archivo binario]", file: untracked("link.png"), root: root.path) == .binary)
}
