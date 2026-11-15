import Foundation
import Testing
@testable import ButakeStack

/// A release as GitHub's API returns it, with the assets given (made-up URLs, nothing is downloaded).
private func release(_ assets: [String]) -> Data {
    let list = assets.map { #"{"name": "\#($0)", "browser_download_url": "https://ejemplo.invalid/\#($0)"}"# }
    return Data(#"{"tag_name": "v0.1.2", "body": "Notas", "html_url": "https://ejemplo.invalid/v0.1.2", "published_at": null, "assets": [\#(list.joined(separator: ","))]}"#.utf8)
}

/// With a zip of the app the updater installs from it (no disk image to mount); without one, from the DMG.
@Test func aReleaseOffersTheZipWhenItHasOneAndTheDMGOtherwise() throws {
    let both = try UpdateService.parse(release(["Butake-Stack.dmg", "Butake-Stack.dmg.sha256", "Butake-Stack.zip", "Butake-Stack.zip.sha256"]))
    #expect(both.version == "0.1.2")
    #expect(both.archive?.lastPathComponent == "Butake-Stack.zip")
    #expect(both.archiveChecksum?.lastPathComponent == "Butake-Stack.zip.sha256")
    #expect(both.checksum?.lastPathComponent == "Butake-Stack.dmg.sha256")

    let dmgOnly = try UpdateService.parse(release(["Butake-Stack.dmg", "Butake-Stack.dmg.sha256"]))
    #expect(dmgOnly.archive == nil && dmgOnly.archiveChecksum == nil)
    #expect(dmgOnly.dmg.lastPathComponent == "Butake-Stack.dmg")

    // A zip without its checksum is not used (the install falls back to the DMG).
    #expect(try UpdateService.parse(release(["Butake-Stack.dmg", "Butake-Stack.zip"])).archiveChecksum == nil)
}

/// The zip is unpacked with ditto and its only app is taken; a zip without exactly one app is refused.
@Test func theZipIsUnpackedToItsOnlyApp() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("update-tests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    func zip(_ apps: [String], named name: String) throws -> URL {
        let source = root.appendingPathComponent("source-\(name)")
        for app in apps {
            let macOS = source.appendingPathComponent("\(app).app/Contents/MacOS")
            try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
            try Data("#!/bin/sh\n".utf8).write(to: macOS.appendingPathComponent(app))
        }
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("léeme\n".utf8).write(to: source.appendingPathComponent("LEEME.txt"))
        let archive = root.appendingPathComponent("\(name).zip")
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", "--sequesterRsrc", source.path, archive.path]
        try ditto.run(); ditto.waitUntilExit()
        #expect(ditto.terminationStatus == 0)
        return archive
    }

    let work = root.appendingPathComponent("work-one")
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    let staged = try UpdateService.stageArchive(from: try zip(["Stack"], named: "one"), into: work)
    #expect(staged.lastPathComponent == "Replacement.app")
    #expect(FileManager.default.fileExists(atPath: staged.appendingPathComponent("Contents/MacOS/Stack").path))

    for (apps, name) in [([String](), "none"), (["Stack", "Otra"], "two")] {
        let other = root.appendingPathComponent("work-\(name)")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        #expect(throws: UpdateService.UpdateError.self) { try UpdateService.stageArchive(from: try zip(apps, named: name), into: other) }
    }
}
