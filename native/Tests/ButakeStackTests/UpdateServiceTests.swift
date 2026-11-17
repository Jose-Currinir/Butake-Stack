import Foundation
import Testing
@testable import ButakeStack

/// A release as GitHub's API returns it, with the assets given (made-up URLs, nothing is downloaded).
private func release(_ assets: [String], base: String = "https://github.com/ejemplo/stack/releases/download/v0.1.2") -> Data {
    let list = assets.map { #"{"name": "\#($0)", "browser_download_url": "\#(base)/\#($0)", "size": 1000}"# }
    return Data(#"{"tag_name": "v0.1.2", "body": "Notas", "html_url": "https://github.com/ejemplo/stack/releases/tag/v0.1.2", "published_at": null, "assets": [\#(list.joined(separator: ","))]}"#.utf8)
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

/// Only the assets named exactly `Butake-Stack.zip` / `.dmg` count, whatever order GitHub lists them in.
@Test func theUpdaterPicksAssetsByExactNameNotByOrder() throws {
    let found = try UpdateService.parse(release(["Symbols.zip", "Symbols.zip.sha256", "Butake-Stack.dmg", "Butake-Stack.dmg.sha256", "Butake-Stack.zip", "Butake-Stack.zip.sha256"]))
    #expect(found.archive?.lastPathComponent == "Butake-Stack.zip")
    #expect(found.archiveChecksum?.lastPathComponent == "Butake-Stack.zip.sha256")
    // Another zip alone is not the app: no archive, the DMG is used.
    let other = try UpdateService.parse(release(["Butake-Stack.dmg", "Butake-Stack.dmg.sha256", "Symbols.zip", "Symbols.zip.sha256"]))
    #expect(other.archive == nil)
    #expect(throws: UpdateService.UpdateError.self) { try UpdateService.parse(release(["Symbols.zip"])) }
}

/// Downloads come from GitHub over https; any other scheme or host is ignored, and absurd sizes too.
@Test func theUpdaterOnlyAcceptsGitHubHttpsAssets() throws {
    for base in ["http://github.com/x", "https://evil.example/x", "https://github.com.evil.example/x", "file:///tmp"] {
        #expect(throws: UpdateService.UpdateError.self) { try UpdateService.parse(release(["Butake-Stack.dmg"], base: base)) }
    }
    #expect(throws: Never.self) { try UpdateService.parse(release(["Butake-Stack.dmg"], base: "https://objects.githubusercontent.com/x")) }
    let huge = Data(#"{"tag_name": "v1", "html_url": "https://github.com/a/b", "assets": [{"name": "Butake-Stack.dmg", "browser_download_url": "https://github.com/a/b/c", "size": 9999999999999}]}"#.utf8)
    #expect(throws: UpdateService.UpdateError.self) { try UpdateService.parse(huge) }
}

@Test(arguments: [
    ("0.1.3", "0.1.2", true), ("0.1.2", "0.1.3", false), ("0.1.3", "0.1.3", false),
    ("v0.2", "0.1.9", true), ("1.0", "1.0.0", false), ("1.0.0.1", "1.0.0", true), ("0.10.0", "0.9.0", true),
    ("1.0.0-rc1", "1.0.0", false), ("1.0.0", "1.0.0-rc1", true), ("1.0.0-rc2", "1.0.0-rc1", true),
    ("1.0.0-rc10", "1.0.0-rc9", true), ("1.0.0+5", "1.0.0", false), ("1.0.1-rc1", "1.0.0", true),
])
func versionsAreComparedNumericallyWithPreReleasesBelowTheirRelease(candidate: String, current: String, newer: Bool) {
    #expect(UpdateService.isNewer(candidate, than: current) == newer)
}

@Test func sameVersionIgnoresOnlyTheLeadingV() {
    #expect(UpdateService.sameVersion("v0.1.3", "0.1.3"))
    #expect(UpdateService.sameVersion("0.1", "0.1.0"))
    #expect(!UpdateService.sameVersion("0.1.3", "0.1.2"))
    #expect(!UpdateService.sameVersion("1.0.0-rc1", "1.0.0"))
}

/// A corrupt or swapped package does not match the published checksum.
@Test func theChecksumMustMatchThePackage() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("update-sum-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let package = root.appendingPathComponent("Butake-Stack.zip")
    try Data("abc".utf8).write(to: package)
    // SHA-256 of "abc" (FIPS 180-2 test vector).
    let digest = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    #expect(try UpdateService.sha256(of: package) == digest)
    #expect(throws: Never.self) { try UpdateService.verifyChecksum(of: package, published: Data("\(digest.uppercased())  Butake-Stack.zip\n".utf8)) }
    #expect(throws: UpdateService.UpdateError.self) { try UpdateService.verifyChecksum(of: package, published: Data("\(String(repeating: "0", count: 64))  x\n".utf8)) }
    #expect(throws: UpdateService.UpdateError.self) { try UpdateService.verifyChecksum(of: package, published: Data()) }
    // A file that does not exist is an error, not a pass.
    #expect(throws: (any Error).self) { try UpdateService.sha256(of: root.appendingPathComponent("missing")) }
    #expect(throws: UpdateService.UpdateError.self) { try UpdateService.requireSize(of: package, atMost: 2) }
    #expect(throws: Never.self) { try UpdateService.requireSize(of: package, atMost: 3) }
}

/// The signature check needs both the code requirement and Gatekeeper; either one failing refuses the app.
@Test func theSignatureNeedsTheRequirementAndGatekeeper() throws {
    let app = URL(fileURLWithPath: "/nonexistent/Replacement.app")
    nonisolated(unsafe) var calls: [String] = []
    func runner(failing tool: String?) -> (String, [String]) throws -> (status: Int32, output: String) {
        { tool0, arguments in
            calls.append(tool0)
            #expect(arguments.contains(app.path))
            return (tool0 == tool ? 1 : 0, "")
        }
    }
    try UpdateService.verifySignature(of: app, run: runner(failing: nil))
    #expect(calls == ["/usr/bin/codesign", "/usr/sbin/spctl"])
    calls = []
    #expect(throws: UpdateService.UpdateError.self) { try UpdateService.verifySignature(of: app, run: runner(failing: "/usr/bin/codesign")) }
    #expect(calls == ["/usr/bin/codesign"])
    calls = []
    #expect(throws: UpdateService.UpdateError.self) { try UpdateService.verifySignature(of: app, run: runner(failing: "/usr/sbin/spctl")) }
}

/// A signed app that is older than the running one, or not the announced version, is not installed.
@Test func theStagedAppMustBeTheAnnouncedAndNewerVersion() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("update-version-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    func app(_ version: String?) throws -> URL {
        let bundle = root.appendingPathComponent("\(UUID().uuidString).app")
        try FileManager.default.createDirectory(at: bundle.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let plist: [String: Any] = version.map { ["CFBundleShortVersionString": $0] } ?? [:]
        try (plist as NSDictionary).write(to: bundle.appendingPathComponent("Contents/Info.plist"))
        return bundle
    }
    #expect(throws: Never.self) { try UpdateService.verifyVersion(of: try app("0.1.3"), announced: "0.1.3", current: "0.1.2") }
    #expect(throws: UpdateService.UpdateError.self) { try UpdateService.verifyVersion(of: try app("0.1.1"), announced: "0.1.3", current: "0.1.2") }
    #expect(throws: UpdateService.UpdateError.self) { try UpdateService.verifyVersion(of: try app("0.1.1"), announced: "0.1.1", current: "0.1.2") }
    #expect(throws: UpdateService.UpdateError.self) { try UpdateService.verifyVersion(of: try app("0.1.3"), announced: "0.1.4", current: "0.1.2") }
    #expect(throws: UpdateService.UpdateError.self) { try UpdateService.verifyVersion(of: try app(nil), announced: "0.1.3", current: "0.1.2") }
    #expect(throws: UpdateService.UpdateError.self) { try UpdateService.verifyVersion(of: root.appendingPathComponent("none.app"), announced: "0.1.3", current: "0.1.2") }
}

/// Release notes keep their emphasis but their links are not live.
@Test func releaseNotesHaveNoLiveLinks() {
    let text = UpdateSheet.withoutLinks("Mira [la guía](https://evil.example) y **esto**")
    #expect(text.runs.allSatisfy { $0.link == nil })
    #expect(String(text.characters) == "Mira la guía y esto")
}
