import AppKit
import CryptoKit
import Foundation

/// Checks GitHub Releases for a newer Butake Stack and installs it in place.
///
/// Installing never trusts the download blindly: the DMG must match the published SHA-256, and the app inside must
/// carry a valid Developer ID signature from Butake SpA (team 9MJ82YJXM2) accepted by Gatekeeper.
@MainActor @Observable final class UpdateService {
    static let shared = UpdateService()
    static let repository = "Jose-Currinir/Butake-Stack"
    static let teamIdentifier = "9MJ82YJXM2"
    static let bundleIdentifier = "cl.butake.stack.native"
    nonisolated static let signingRequirement = "anchor apple generic and identifier \"cl.butake.stack.native\" and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"9MJ82YJXM2\""

    struct Release: Equatable {
        var version: String
        var notes: String
        var page: URL
        var dmg: URL
        var checksum: URL?
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
        #if DEBUG || BUTAKE_QA
        if let fake = ProcessInfo.processInfo.environment["BUTAKE_FAKE_VERSION"] { return fake }
        #endif
        return Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }()
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
            if updateAvailable && !userInitiated { NSLog("Butake Stack: versión %@ disponible", latest?.version ?? "") }
        } catch {
            phase = .failed((error as? UpdateError)?.text ?? L("updateCheckFailed"))
        }
    }

    /// Downloads, verifies and replaces the running app, then relaunches it.
    func install() async {
        // One installation at a time: a second click must not download and swap the bundle twice.
        guard let release = latest, updateAvailable, !installInFlight else { return }
        installInFlight = true; defer { installInFlight = false }
        let target = Bundle.main.bundleURL
        do {
            phase = .downloading
            let work = FileManager.default.temporaryDirectory.appendingPathComponent("butake-update-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let dmg = work.appendingPathComponent("Butake-Stack.dmg")
            let (downloaded, _) = try await URLSession.shared.download(from: release.dmg)
            try FileManager.default.moveItem(at: downloaded, to: dmg)

            phase = .verifying
            if let checksumURL = release.checksum {
                let (data, response) = try await URLSession.shared.data(from: checksumURL)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.message(L("updateChecksumMismatch")) }
                let expected = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isWhitespace).first.map(String.init)?.lowercased() ?? ""
                let actual = try await Task.detached { try Self.sha256(of: dmg) }.value
                guard !expected.isEmpty, expected == actual else { throw UpdateError.message(L("updateChecksumMismatch")) }
            }
            let staged = try await Task.detached { try Self.stageApp(from: dmg, into: work) }.value
            try await Task.detached { try Self.verifySignature(of: staged) }.value

            phase = .installing
            let parent = target.deletingLastPathComponent().path
            guard FileManager.default.isWritableFile(atPath: parent) else {
                // Without write access to the install folder, hand the verified DMG to Finder instead.
                NSWorkspace.shared.open(dmg)
                throw UpdateError.message(L("updateNoPermission"))
            }
            try Self.launchReplacement(staged: staged, target: target, work: work)
            // An attached sheet makes the window refuse to close, which cancels the quit; dismiss it first.
            showingSheet = false
            try? await Task.sleep(for: .milliseconds(400))
            NSApp.terminate(nil)
            // If anything still cancels the quit, leave anyway: the verified replacement is waiting for this exit.
            try? await Task.sleep(for: .seconds(3))
            // A sheet still open (an editor with unsaved changes) cancelled the quit: do not throw that work away.
            // The replacement keeps waiting and is applied as soon as the user quits.
            if NSApp.windows.contains(where: { $0.attachedSheet != nil }) { phase = .failed(L("updatePendingQuit")); return }
            UserDefaults.standard.synchronize()
            exit(0)
        } catch {
            phase = .failed((error as? UpdateError)?.text ?? error.localizedDescription)
        }
    }

    // MARK: - Helpers

    private var installInFlight = false

    enum UpdateError: Error { case message(String); var text: String { if case .message(let value) = self { value } else { "" } } }

    nonisolated static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ value: String) -> [Int] {
            value.trimmingCharacters(in: CharacterSet(charactersIn: "vV ")).split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        }
        let a = parts(candidate), b = parts(current)
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0, y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }

    nonisolated static func parse(_ data: Data) throws -> Release {
        struct Asset: Decodable { var name: String; var browser_download_url: URL }
        struct Payload: Decodable { var tag_name: String; var body: String?; var html_url: URL; var published_at: String?; var assets: [Asset] }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        guard let dmg = payload.assets.first(where: { $0.name.hasSuffix(".dmg") }) else { throw UpdateError.message(L("updateNoInstaller")) }
        let checksum = payload.assets.first { $0.name == dmg.name + ".sha256" }
        let published = payload.published_at.flatMap { ISO8601DateFormatter().date(from: $0) }
        return Release(version: payload.tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "vV")), notes: payload.body ?? "",
                       page: payload.html_url, dmg: dmg.browser_download_url, checksum: checksum?.browser_download_url, published: published)
    }

    nonisolated private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    @discardableResult nonisolated private static func run(_ tool: String, _ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process(); process.executableURL = URL(fileURLWithPath: tool); process.arguments = arguments
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// Mounts the DMG read-only, copies the app out and detaches.
    nonisolated private static func stageApp(from dmg: URL, into work: URL) throws -> URL {
        let mount = work.appendingPathComponent("mount")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        guard try run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path, dmg.path]).status == 0 else { throw UpdateError.message(L("updateMountFailed")) }
        defer { _ = try? run("/usr/bin/hdiutil", ["detach", mount.path, "-force"]) }
        guard let app = try FileManager.default.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil).first(where: { $0.pathExtension == "app" }) else { throw UpdateError.message(L("updateNoInstaller")) }
        let staged = work.appendingPathComponent(app.lastPathComponent)
        guard try run("/usr/bin/ditto", [app.path, staged.path]).status == 0 else { throw UpdateError.message(L("updateMountFailed")) }
        return staged
    }

    /// Valid signature, Butake SpA's team, the expected bundle and Gatekeeper acceptance (notarized).
    nonisolated private static func verifySignature(of app: URL) throws {
        // A code requirement checked by the system against the certificate chain, instead of reading codesign's
        // printed fields: Apple-issued Developer ID Application certificate, this team, this bundle identifier.
        guard try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", "-R=\(signingRequirement)", app.path]).status == 0 else { throw UpdateError.message(L("updateSignatureInvalid")) }
        guard try run("/usr/sbin/spctl", ["--assess", "--type", "execute", app.path]).status == 0 else { throw UpdateError.message(L("updateSignatureInvalid")) }
    }

    /// A detached shell waits for this process to quit, swaps the bundle (restoring it on failure) and relaunches.
    private static func launchReplacement(staged: URL, target: URL, work: URL) throws {
        let script = work.appendingPathComponent("install.sh")
        let backup = target.path + ".anterior"
        let text = """
        #!/bin/sh
        while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done
        rm -rf \(shellQuote(backup))
        mv \(shellQuote(target.path)) \(shellQuote(backup)) || { /usr/bin/open \(shellQuote(target.path)); exit 1; }
        if /usr/bin/ditto \(shellQuote(staged.path)) \(shellQuote(target.path)); then rm -rf \(shellQuote(backup)); else rm -rf \(shellQuote(target.path)); mv \(shellQuote(backup)) \(shellQuote(target.path)); fi
        # The session agent runs the engine from inside the bundle: restart it on the new copy. SIGTERM
        # lets it stop MySQL, PostgreSQL and the rest cleanly; launchd (KeepAlive) starts the new one.
        /bin/launchctl kill TERM gui/$(id -u)/cl.butake.stack.daemon >/dev/null 2>&1 || /bin/launchctl kickstart gui/$(id -u)/cl.butake.stack.daemon >/dev/null 2>&1 || true
        /usr/bin/open \(shellQuote(target.path))
        rm -rf \(shellQuote(work.path))
        """
        try text.write(to: script, atomically: true, encoding: .utf8)
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/sh"); process.arguments = [script.path]
        try process.run()
    }
}

/// Single-quoted for /bin/sh.
func shellQuote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
