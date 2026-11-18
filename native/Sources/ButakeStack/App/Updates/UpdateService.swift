import AppKit
import CryptoKit
import Foundation
import os

/// Checks GitHub Releases for a newer Stack and installs it in place.
///
/// Installing never trusts the download blindly. The published SHA-256 only catches a corrupt or truncated download
/// (it comes from the same release as the package); what authenticates it is the Developer ID signature from Butake SpA
/// (team 9MJ82YJXM2) accepted by Gatekeeper. The app inside must also be the announced version and newer than the
/// running one, so a validly signed older build cannot be offered as an update.
///
/// The package is the release's zip of the app when there is one: macOS treats a mounted disk image like a removable
/// volume, and an app reading it needs a privacy permission it is never asked for (so it fails with «no permission»).
/// Releases without a zip (0.1.1 and earlier) still install from their DMG.
@MainActor @Observable final class UpdateService {
    static let shared = UpdateService()
    private static let log = Logger(subsystem: "cl.butake.stack.native", category: "update")
    static let repository = "Jose-Currinir/Butake-Stack"
    nonisolated static let signingRequirement = "anchor apple generic and identifier \"cl.butake.stack.native\" and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"9MJ82YJXM2\""

    struct Release: Equatable {
        var version: String
        var notes: String
        var page: URL
        var dmg: URL
        var checksum: URL?
        /// `Butake-Stack.zip` and its SHA-256: the app zipped with ditto, installed without mounting anything.
        var archive: URL? = nil
        var archiveChecksum: URL? = nil
        var published: Date?
    }
    enum Phase: Equatable {
        case idle, checking, upToDate, available, downloading, verifying, installing
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var latest: Release?
    private(set) var lastCheck: Date?
    var showingSheet = false
    @ObservationIgnored private var timer: Task<Void, Never>?

    /// Version of the running app (`CFBundleShortVersionString`).
    let current: String = {
        #if DEBUG
        if let fake = ProcessInfo.processInfo.environment["BUTAKE_FAKE_VERSION"] { return fake }
        #endif
        return Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }()
    /// Build number of the running app (`CFBundleVersion`), shown next to the version.
    let build: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
    /// "1.3.1 (136)", like macOS shows versions.
    var versionLabel: String { build.isEmpty ? current : "\(current) (\(build))" }
    var updateAvailable: Bool { latest.map { Self.isNewer($0.version, than: current) } ?? false }
    var automatic: Bool { UserDefaults.standard.object(forKey: "autoUpdateCheck") as? Bool ?? true }

    /// First check a few seconds after launch, then every 6 hours while the app runs.
    func startAutomaticChecks() {
        guard timer == nil else { return }
        timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            while !Task.isCancelled {
                if let self, self.automatic { await self.check(userInitiated: false) }
                try? await Task.sleep(for: .seconds(6 * 3600))
            }
        }
    }

    /// `userInitiated` opens the sheet with the outcome (up to date, available or error).
    func check(userInitiated: Bool) async {
        guard phase != .checking, phase != .downloading, phase != .verifying, phase != .installing else { return }
        if userInitiated { showingSheet = true }
        phase = .checking
        do {
            var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repository)/releases/latest")!)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("ButakeStack/\(current)", forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 20
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.message(L("updateCheckFailed")) }
            latest = try Self.parse(data)
            lastCheck = Date()
            phase = updateAvailable ? .available : .upToDate
            if updateAvailable && !userInitiated { Self.log.info("version \(self.latest?.version ?? "", privacy: .public) available") }
        } catch {
            phase = .failed((error as? UpdateError)?.text ?? L("updateCheckFailed"))
        }
    }

    /// Downloads, verifies and replaces the running app, then relaunches it.
    func install() async {
        // One installation at a time: a second click must not download and swap the bundle twice.
        guard let release = latest, updateAvailable, !installInFlight, !replacementPending else { return }
        installInFlight = true; defer { installInFlight = false }
        let target = Bundle.main.bundleURL
        do {
            guard FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path) else {
                NSWorkspace.shared.open(release.page)
                throw UpdateError.message(L("updateNoPermission"))
            }
            let zipped = release.archive.flatMap { archive in release.archiveChecksum.map { (archive, $0) } }
            guard let source = zipped ?? release.checksum.map({ (release.dmg, $0) }) else {
                throw UpdateError.message(L("updateChecksumMismatch"))
            }
            let (packageURL, checksumURL) = source
            let work = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                   appropriateFor: target, create: true)
            var handedOff = false
            defer { if !handedOff { try? FileManager.default.removeItem(at: work) } }

            phase = .downloading
            let package = work.appendingPathComponent(zipped == nil ? "Butake-Stack.dmg" : "Butake-Stack.zip")
            let (downloaded, downloadResponse) = try await URLSession.shared.download(from: packageURL)
            guard (downloadResponse as? HTTPURLResponse)?.statusCode == 200 else {
                throw UpdateError.message(L("updateCheckFailed"))
            }
            try FileManager.default.moveItem(at: downloaded, to: package)
            try Self.requireSize(of: package, atMost: Self.maximumPackageBytes)

            phase = .verifying
            let (checksumFile, response) = try await URLSession.shared.download(from: checksumURL)
            defer { try? FileManager.default.removeItem(at: checksumFile) }
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.message(L("updateChecksumMismatch")) }
            try Self.requireSize(of: checksumFile, atMost: Self.maximumChecksumBytes)
            let published = try Data(contentsOf: checksumFile)
            try await Self.offMain { try Self.verifyChecksum(of: package, published: published) }
            let staged = try await Self.offMain {
                zipped == nil ? try Self.stageApp(from: package, into: work) : try Self.stageArchive(from: package, into: work)
            }
            try await Self.offMain { try Self.verifySignature(of: staged) }
            try Self.verifyVersion(of: staged, announced: release.version, current: current)

            phase = .installing
            try Self.launchReplacement(target: target, work: work)
            handedOff = true
            replacementPending = true
            Task {
                try? await Task.sleep(for: .seconds(590))
                replacementPending = false
            }
            // The sheet stays open: if something prevents the quit, the user reads why here.
            try? await Task.sleep(for: .milliseconds(400))
            NSApp.terminate(nil)
            // The helper waits for a normal quit, including when another sheet prevents it.
            try? await Task.sleep(for: .seconds(3))
            phase = .failed(L("updatePendingQuit"))
        } catch {
            phase = .failed((error as? UpdateError)?.text ?? error.localizedDescription)
        }
    }

    // MARK: - Helpers

    private var installInFlight = false
    private var replacementPending = false

    enum UpdateError: Error { case message(String); var text: String { if case .message(let value) = self { value } else { "" } } }

    /// Compares dotted versions numerically; a pre-release («1.0.0-rc1») is older than its release («1.0.0»).
    nonisolated static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = components(candidate), b = components(current)
        for index in 0..<max(a.numbers.count, b.numbers.count) {
            let x = index < a.numbers.count ? a.numbers[index] : 0, y = index < b.numbers.count ? b.numbers[index] : 0
            if x != y { return x > y }
        }
        switch (a.pre, b.pre) {
        case (nil, nil): return false
        case (nil, _): return true
        case (_, nil): return false
        case let (x?, y?): return x.compare(y, options: .numeric) == .orderedDescending
        }
    }
    /// True when both strings name the same version («v0.1.3» and «0.1.3» do).
    nonisolated static func sameVersion(_ first: String, _ second: String) -> Bool {
        let a = components(first), b = components(second)
        return !isNewer(first, than: second) && !isNewer(second, than: first) && a.pre == b.pre
    }
    nonisolated private static func components(_ value: String) -> (numbers: [Int], pre: String?) {
        var text = value.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
        if let plus = text.firstIndex(of: "+") { text = String(text[..<plus]) }
        var pre: String?
        if let dash = text.firstIndex(of: "-") { pre = String(text[text.index(after: dash)...]); text = String(text[..<dash]) }
        return (text.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }, pre)
    }

    /// Release assets are GitHub's: https and github.com (or the hosts it serves downloads from).
    nonisolated static func isTrustedDownload(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host?.lowercased() else { return false }
        return host == "github.com" || host == "githubusercontent.com" || host.hasSuffix(".githubusercontent.com")
    }
    nonisolated static let maximumPackageBytes: Int64 = 1 << 30
    nonisolated static let maximumChecksumBytes: Int64 = 4096

    nonisolated static func parse(_ data: Data) throws -> Release {
        struct Asset: Decodable { var name: String; var browser_download_url: URL; var size: Int64? }
        struct Payload: Decodable { var tag_name: String; var body: String?; var html_url: URL; var published_at: String?; var assets: [Asset] }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        guard isTrustedDownload(payload.html_url) else { throw UpdateError.message(L("updateNoInstaller")) }
        // Only assets by their exact names, from GitHub, of a sane size: the order of the list decides nothing.
        func asset(_ name: String, limit: Int64) -> URL? {
            payload.assets.first { $0.name == name && isTrustedDownload($0.browser_download_url) && ($0.size ?? 0) <= limit }?.browser_download_url
        }
        guard let dmg = asset("Butake-Stack.dmg", limit: maximumPackageBytes) else { throw UpdateError.message(L("updateNoInstaller")) }
        let checksum = asset("Butake-Stack.dmg.sha256", limit: maximumChecksumBytes)
        let archive = asset("Butake-Stack.zip", limit: maximumPackageBytes)
        let archiveChecksum = archive == nil ? nil : asset("Butake-Stack.zip.sha256", limit: maximumChecksumBytes)
        let published = payload.published_at.flatMap { ISO8601DateFormatter().date(from: $0) }
        return Release(version: payload.tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "vV")), notes: payload.body ?? "",
                       page: payload.html_url, dmg: dmg, checksum: checksum,
                       archive: archive, archiveChecksum: archiveChecksum, published: published)
    }

    nonisolated static func requireSize(of url: URL, atMost limit: Int64) throws {
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? Int64.max
        guard size <= limit else { throw UpdateError.message(L("updateChecksumMismatch")) }
    }

    /// The package must hash to the first word of the published checksum file.
    nonisolated static func verifyChecksum(of package: URL, published: Data) throws {
        let expected = String(decoding: published, as: UTF8.self).split(whereSeparator: \.isWhitespace).first?.lowercased()
        guard expected == (try sha256(of: package)) else { throw UpdateError.message(L("updateChecksumMismatch")) }
    }

    /// The staged app must be the version the release announces and newer than the running one (no downgrade).
    nonisolated static func verifyVersion(of app: URL, announced: String, current: String) throws {
        let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        guard let version = info?["CFBundleShortVersionString"] as? String, sameVersion(version, announced), isNewer(version, than: current) else {
            throw UpdateError.message(L("updateVersionMismatch"))
        }
    }

    /// Runs blocking work off the main actor; cancelling the caller cancels it too.
    nonisolated static func offMain<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        let task = Task.detached { try work() }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    nonisolated static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            try Task.checkCancellation()
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Runs a tool and waits for it; one that does not finish within `timeout` seconds is stopped.
    @discardableResult nonisolated private static func run(_ tool: String, _ arguments: [String], timeout: TimeInterval = 300) throws -> (status: Int32, output: String) {
        try Task.checkCancellation()
        let process = Process(); process.executableURL = URL(fileURLWithPath: tool); process.arguments = arguments
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
        try process.run()
        let limit = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: limit)
        defer { limit.cancel() }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// Unzips the release's zip (ditto, as it was made) and takes the only app at its top level.
    nonisolated static func stageArchive(from zip: URL, into work: URL) throws -> URL {
        let unpacked = work.appendingPathComponent("unpacked")
        try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: true)
        guard try run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path]).status == 0 else { throw UpdateError.message(L("updateNoInstaller")) }
        let apps = try FileManager.default.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: nil).filter { $0.pathExtension == "app" }
        guard apps.count == 1 else { throw UpdateError.message(L("updateNoInstaller")) }
        let staged = work.appendingPathComponent("Replacement.app")
        try FileManager.default.moveItem(at: apps[0], to: staged)
        return staged
    }

    /// Mounts the DMG read-only, copies the app out and detaches.
    nonisolated private static func stageApp(from dmg: URL, into work: URL) throws -> URL {
        let mount = work.appendingPathComponent("mount")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        guard try run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path, dmg.path]).status == 0 else { throw UpdateError.message(L("updateMountFailed")) }
        defer { _ = try? run("/usr/bin/hdiutil", ["detach", mount.path, "-force"]) }
        guard let app = try FileManager.default.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil).first(where: { $0.pathExtension == "app" }) else { throw UpdateError.message(L("updateNoInstaller")) }
        let staged = work.appendingPathComponent("Replacement.app")
        guard try run("/usr/bin/ditto", [app.path, staged.path]).status == 0 else { throw UpdateError.message(L("updateMountFailed")) }
        return staged
    }

    /// Valid signature, Butake SpA's team, the expected bundle and Gatekeeper acceptance (notarized).
    nonisolated static func verifySignature(of app: URL,
        run runner: (String, [String]) throws -> (status: Int32, output: String) = { try run($0, $1) }) throws {
        // A code requirement checked by the system against the certificate chain, instead of reading codesign's
        // printed fields: Apple-issued Developer ID Application certificate, this team, this bundle identifier.
        guard try runner("/usr/bin/codesign", ["--verify", "--deep", "--strict", "-R=\(signingRequirement)", app.path]).status == 0 else { throw UpdateError.message(L("updateSignatureInvalid")) }
        guard try runner("/usr/sbin/spctl", ["--assess", "--type", "execute", app.path]).status == 0 else { throw UpdateError.message(L("updateSignatureInvalid")) }
    }

    private static func launchReplacement(target: URL, work: URL) throws {
        let process = Process()
        process.executableURL = StackEngine.executable
        process.arguments = ["replace-app", String(ProcessInfo.processInfo.processIdentifier), target.path, work.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        try process.run()
    }
}
