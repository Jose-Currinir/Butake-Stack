import AppKit
import SwiftUI

/// Local trust, Xdebug, mail catcher, dumps, sharing and watched folders.
extension StackStore {
    // MARK: What macOS needs for .test sites (macOS asks for authorization in its own dialog)
    func refreshTrust() async {
        localTrust = try? await call(["method": "localTrust"])
    }
    func installResolver() async {
        await run(L("trust.busy.resolver")) {
            let _: JSONValue = try await self.call(["method": "installResolver", "confirmed": true])
            self.notify(L("trust.resolver.done"))
        }
        await refreshTrust()
    }
    func trustLocalCa() async {
        await run(L("trust.busy.ca")) {
            let _: JSONValue = try await self.call(["method": "trustLocalCa", "confirmed": true])
            self.notify(L("trust.ca.done"))
        }
        await refreshTrust()
    }

    // MARK: Xdebug per PHP line
    func setXdebug(_ series: String, mode: String?) async {
        await run(L("busy.saving")) {
            self.phpRuntimes = try await self.call(["method": "setXdebug", "series": series, "mode": mode ?? ""])
            self.notify(mode == nil ? String(format: L("xdebug.off"), series) : String(format: L("xdebug.on"), series))
        }
        try? await Task.sleep(for: .milliseconds(800))
        await refreshStatus()
    }

    // MARK: Mail catcher
    var mailStatus: ExtrasStatus.Mail? { status?.extras?.mail }
    func loadMail() async {
        struct Changes: Decodable, Sendable {
            let ids: [String]
            let messages: [MailSummary]
        }
        let known = mailMessages
        guard let changes: Changes = try? await call(["method": "mailChanges", "known": known.map(\.id)]),
              !Task.isCancelled, mailMessages == known else { return }
        let summaries = Dictionary((known + changes.messages).map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        let list = changes.ids.compactMap { summaries[$0] }
        if list != mailMessages { mailMessages = list }
    }
    func mailMessage(_ id: String) async -> MailMessage? {
        try? await call(["method": "mailGet", "id": id])
    }
    func deleteMail(_ id: String?) async {
        await run(L("busy.saving")) {
            let _: Bool = try await self.call(id.map { ["method": "mailDelete", "id": $0] } ?? ["method": "mailDelete", "all": true])
        }
        await loadMail(); await refreshStatus()
    }
    func saveAttachment(_ message: MailMessage, _ attachment: MailAttachment) async {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = attachment.name
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        await run(L("busy.saving")) {
            let _: Bool = try await self.call(["method": "mailAttachment", "id": message.id, "index": attachment.index, "path": url.path])
            self.notify(String(format: L("mail.saved"), url.lastPathComponent))
        }
    }

    /// Changes a receiver's port and, for mail, how long and how many messages it keeps
    /// (`setMail`, `setDumps`); the daemon reloads it. Returns false when the engine refused it.
    @discardableResult
    func setReceiver(_ tool: String, port: Int, retentionDays: Int? = nil, maxMessages: Int? = nil) async -> Bool {
        var request: [String: Any] = ["method": tool == "mail" ? "setMail" : "setDumps", "port": port]
        if let retentionDays { request["retentionDays"] = retentionDays }
        if let maxMessages { request["maxMessages"] = maxMessages }
        var saved = false
        await run(L("busy.saving")) {
            self.config = try await self.call(request)
            saved = true
        }
        guard saved else { return false }
        notify(L("receiver.saved"))
        await refreshStatus()
        return true
    }

    // MARK: dump() receiver
    var dumpsStatus: ExtrasStatus.Dumps? { status?.extras?.dumps }
    func watchDumps() async {
        guard daemonRunning else { dumps = []; return }
        while daemonRunning && !Task.isCancelled {
            do {
                for try await items in engine.dumpStream() {
                    guard !Task.isCancelled else { return }
                    let newestFirst = Array(items.reversed())
                    if dumps != newestFirst { dumps = newestFirst }
                }
            } catch { /* Retry when the daemon is available. */ }
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
        }
    }
    func clearDumps() async {
        await run(L("busy.saving")) {
            let _: Bool = try await self.call(["method": "dumpsClear"])
            self.dumps = []
        }
    }

    // MARK: Sharing a site through a public tunnel
    func share(_ project: Project) -> ShareStatus? { status?.shares?.first { $0.id == project.id } }
    func setShared(_ project: Project, _ on: Bool) async {
        await run(on ? L("share.busy.start") : L("share.busy.stop")) {
            let _: Bool = try await self.call(["method": "shareSite", "id": project.id, "on": on, "confirmed": on])
        }
        await refreshStatus()
    }

    // MARK: Watched folders
    func isWatched(_ path: String) -> Bool { watchedFolders.contains { $0.path == URL(fileURLWithPath: path).standardizedFileURL.path || $0.path == path } }
    func refreshWatched() async {
        watchedFolders = (try? await call(["method": "watchedFolders"])) ?? watchedFolders
        guard !watchedFolders.isEmpty else { watchedPending = []; return }
        let scans: [WatchedScan] = (try? await call(["method": "watchedScan"])) ?? []
        watchedPending = scans.compactMap { $0.scan }.filter { !$0.projects.isEmpty }
    }
    func setWatched(_ path: String, _ watched: Bool) async {
        await run(L("busy.saving")) {
            self.watchedFolders = try await self.call(["method": "setWatchedFolder", "path": path, "watched": watched])
        }
        await refreshWatched()
    }
    /// The projects stop being offered (they can still be added by hand).
    func ignoreWatched(_ root: String, paths: [String]) async {
        guard !paths.isEmpty else { return }
        let _: Bool? = try? await call(["method": "ignoreWatched", "folder": root, "paths": paths])
        await refreshWatched()
    }
    /// Opens the import with only the new projects of a watched folder.
    func reviewWatched(_ scan: FolderScan) {
        importScan = scan
    }
}
