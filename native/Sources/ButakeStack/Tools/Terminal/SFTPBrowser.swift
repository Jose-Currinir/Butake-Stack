import Foundation
import SwiftTerm

// MARK: - SFTP

struct SFTPEntry: Codable, Identifiable, Hashable, Sendable {
    var name: String
    var kind: String
    var size: Int
    var modified: String
    var mode: String
    var id: String { name }
    var isDirectory: Bool { kind == "dir" }
    var isLink: Bool { kind == "link" }
}
private struct SFTPListing: Codable, Sendable { var path: String; var entries: [SFTPEntry] }
private struct SFTPLaunch: Codable, Sendable { var executable: String; var args: [String]; var batch: String }

/// One upload or download: sftp runs in a pseudo-terminal so it prints its progress meter.
@MainActor @Observable final class SFTPTransfer: Identifiable {
    enum State { case running, done, failed }
    let id = UUID()
    let name: String
    let upload: Bool
    var progress: Double = 0
    var state = State.running
    var detail = ""
    @ObservationIgnored fileprivate var runner: TransferRunner?
    @ObservationIgnored fileprivate var batch = ""
    init(name: String, upload: Bool) { self.name = name; self.upload = upload }
}

/// Feeds sftp's output into a transfer: the last "NN%" on screen is the progress.
@MainActor fileprivate final class TransferRunner: NSObject {
    weak var transfer: SFTPTransfer?
    var process: LocalProcess!
    var tail = ""
    let finished: (Int32?) -> Void
    init(transfer: SFTPTransfer, finished: @escaping (Int32?) -> Void) {
        self.transfer = transfer
        self.finished = finished
        super.init()
        process = LocalProcess(delegate: self)
    }
}
extension TransferRunner: @preconcurrency LocalProcessDelegate {
    func processTerminated(_ source: LocalProcess, exitCode: Int32?) { finished(exitCode) }
    func dataReceived(slice: ArraySlice<UInt8>) {
        tail = String((tail + String(decoding: slice, as: UTF8.self)).suffix(400))
        let chunks = tail.components(separatedBy: CharacterSet(charactersIn: "\r\n")).filter { !$0.isEmpty }
        for chunk in chunks.reversed() {
            if let match = chunk.firstMatch(of: /(\d{1,3})%/), let value = Double(match.1) {
                transfer?.progress = min(1, value / 100)
                break
            }
        }
        if let last = chunks.last(where: { !$0.hasPrefix("sftp>") && !$0.contains("%") }) { transfer?.detail = String(last.prefix(160)) }
    }
    func getWindowSize() -> winsize { winsize(ws_row: 24, ws_col: 200, ws_xpixel: 0, ws_ypixel: 0) }
}

/// The remote file browser of a host.
@MainActor @Observable final class SFTPBrowser: Identifiable {
    let id = UUID()
    let host: SSHHost
    var path = ""
    var entries: [SFTPEntry] = []
    var loading = false
    var failure: String?
    var selection: Set<String> = []
    var transfers: [SFTPTransfer] = []
    /// What the toolbar and the context menu asked for and waits for the user: a name (new folder,
    /// rename), the confirmation to delete, or to replace a file already downloaded.
    var naming: Naming?
    var deleting: [SFTPEntry] = []
    var overwrite: Overwrite?
    enum Naming: Identifiable {
        case newFolder, rename(SFTPEntry)
        var id: String { if case .rename(let entry) = self { "rename-" + entry.name } else { "new" } }
    }
    struct Overwrite { let entry: SFTPEntry; let folder: URL }
    var selected: [SFTPEntry] { entries.filter { selection.contains($0.name) } }
    @ObservationIgnored private var generation = 0
    let store = StackStore.shared
    init(host: SSHHost) { self.host = host }

    func full(_ name: String) -> String { path.hasSuffix("/") ? path + name : path + "/" + name }
    var parent: String? {
        guard path != "/", !path.isEmpty else { return nil }
        let up = (path as NSString).deletingLastPathComponent
        return up.isEmpty ? "/" : up
    }

    /// Lists a folder (nil = reload the current one; "" = the home folder).
    func load(_ target: String?) async {
        guard await SSHKeyring.shared.ensureAgent(host.key) else { failure = L("error.ssh_key_passphrase"); return }
        if let jump = SSHTerminal.shared.host(host.jump), !(await SSHKeyring.shared.ensureAgent(jump.key)) { return }
        // Only the latest request counts: an older answer arriving late never replaces a newer one.
        generation += 1
        let mine = generation
        loading = true
        defer { if mine == generation { loading = false } }
        do {
            let listing: SFTPListing = try await store.call(["method": "sshSftpList", "id": host.id, "path": target ?? path])
            guard mine == generation else { return }
            path = listing.path
            entries = listing.entries
            failure = nil
            selection = selection.filter { name in entries.contains { $0.name == name } }
        } catch let failure as EngineFailure {
            guard mine == generation else { return }
            if failure.code == "ssh_host_unknown" || failure.code == "ssh_host_changed" {
                await SSHTerminal.shared.recheckAfterFailure(host.id, then: .sftp)
            }
            self.failure = failure.errorDescription
        } catch { failure = L("engine.requestFailed") }
    }

    func mkdir(_ name: String) async {
        do {
            let _: Bool = try await store.call(["method": "sshSftpMkdir", "id": host.id, "path": full(name)])
            await load(nil)
        } catch { store.report(error) }
    }
    func rename(_ entry: SFTPEntry, to name: String) async {
        do {
            let _: Bool = try await store.call(["method": "sshSftpRename", "id": host.id, "from": full(entry.name), "to": full(name)])
            await load(nil)
        } catch { store.report(error) }
    }
    func delete(_ entries: [SFTPEntry]) async {
        for entry in entries {
            do {
                let _: Bool = try await store.call(["method": "sshSftpDelete", "id": host.id, "path": full(entry.name), "kind": entry.kind,
                                                    "recursive": entry.isDirectory, "confirmed": true])
            } catch { store.report(error); break }
        }
        await load(nil)
    }

    /// Downloads into `folder`; an existing file there is replaced only when `overwrite`.
    func download(_ entry: SFTPEntry, to folder: URL, overwrite: Bool = false) async throws {
        let launch: SFTPLaunch = try await store.call(["method": "sshSftpTransfer", "id": host.id, "direction": "get", "remote": full(entry.name),
                                                       "local": folder.path, "overwrite": overwrite])
        run(launch, name: entry.name, upload: false)
    }
    func upload(_ urls: [URL]) async {
        guard await SSHKeyring.shared.ensureAgent(host.key) else { return }
        for url in urls {
            do {
                let launch: SFTPLaunch = try await store.call(["method": "sshSftpTransfer", "id": host.id, "direction": "put", "remote": path, "local": url.path])
                run(launch, name: url.lastPathComponent, upload: true)
            } catch { store.report(error) }
        }
    }

    private func run(_ launch: SFTPLaunch, name: String, upload: Bool) {
        guard launch.executable == "/usr/bin/sftp" else { return }
        let transfer = SFTPTransfer(name: name, upload: upload)
        transfer.batch = launch.batch
        let runner = TransferRunner(transfer: transfer) { [weak self, weak transfer] code in
            guard let transfer else { return }
            transfer.state = code == 0 ? .done : .failed
            if code == 0 { transfer.progress = 1 }
            transfer.runner = nil
            Task {
                let _: Bool? = try? await StackStore.shared.call(["method": "sshSftpDone", "batch": transfer.batch])
                if upload, let self { await self.load(nil) }
                if code == 0 { StackStore.shared.notify(String(format: L(upload ? "ssh.sftp.uploaded" : "ssh.sftp.downloaded"), name)) }
            }
        }
        transfer.runner = runner
        transfers.insert(transfer, at: 0)
        runner.process.startProcess(executable: launch.executable, args: launch.args, environment: TerminalSession.sshEnvironment())
    }

    func cancel(_ transfer: SFTPTransfer) {
        transfer.runner?.process.terminate()
        transfer.state = .failed
        transfer.detail = L("ssh.sftp.cancelled")
    }
    func cancelAll() { transfers.filter { $0.state == .running }.forEach(cancel) }
    func clearFinished() { transfers.removeAll { $0.state != .running } }
}
