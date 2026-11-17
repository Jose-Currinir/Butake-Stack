import Foundation
import Testing
@testable import ButakeStack

/// A stand-in for `git` that answers each subcommand with a given status and message.
private func fakeGit(_ root: URL, revParse: (Int32, String), checkIgnore: Int32 = 0, name: String = "git") throws -> URL {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let script = root.appendingPathComponent(name)
    let text = """
    #!/bin/sh
    case "$3" in
      rev-parse) echo "\(revParse.1)" >&2; exit \(revParse.0) ;;
      check-ignore) exit \(checkIgnore) ;;
    esac
    exit 99
    """
    try Data(text.utf8).write(to: script)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    return script
}

/// Writing an environment's secrets next to a repository needs Git's yes: any doubt refuses.
@Test func downloadingSecretsFailsClosedWhenGitCannotAnswer() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("env-guard-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = root.appendingPathComponent("project").path
    try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)

    // Git is missing, or the command-line-tools shortcut exits with an error.
    #expect(EnvDownloadGuard.verdict(folder: folder, name: ".env.local", git: root.appendingPathComponent("missing")) == .unverifiable)
    let shim = try fakeGit(root.appendingPathComponent("a"), revParse: (1, "xcode-select: note: no developer tools were found"))
    #expect(EnvDownloadGuard.verdict(folder: folder, name: ".env.local", git: shim) == .unverifiable)
    // A fatal error that is not «not a repository» (dubious ownership, damaged repository).
    let broken = try fakeGit(root.appendingPathComponent("b"), revParse: (128, "fatal: detected dubious ownership"))
    #expect(EnvDownloadGuard.verdict(folder: folder, name: ".env.local", git: broken) == .unverifiable)

    // Git answered that there is no repository: the file is allowed.
    let plain = try fakeGit(root.appendingPathComponent("c"), revParse: (128, "fatal: not a git repository (or any of the parent directories): .git"))
    #expect(EnvDownloadGuard.verdict(folder: folder, name: ".env.local", git: plain) == .allowed)

    // Inside a repository: ignored is allowed, tracked is refused, and any other answer is unknown.
    let ignored = try fakeGit(root.appendingPathComponent("d"), revParse: (0, ""), checkIgnore: 0)
    let tracked = try fakeGit(root.appendingPathComponent("e"), revParse: (0, ""), checkIgnore: 1)
    let failing = try fakeGit(root.appendingPathComponent("f"), revParse: (0, ""), checkIgnore: 128)
    #expect(EnvDownloadGuard.verdict(folder: folder, name: ".env.local", git: ignored) == .allowed)
    #expect(EnvDownloadGuard.verdict(folder: folder, name: ".env.local", git: tracked) == .notIgnored)
    #expect(EnvDownloadGuard.verdict(folder: folder, name: ".env.local", git: failing) == .unverifiable)
}
