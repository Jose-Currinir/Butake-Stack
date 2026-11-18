import AppKit
import SwiftUI

extension StackStore {
    // MARK: Daemon and processes
    func startDaemon() async {
        await run(L("busy.starting"), refresh: true) { let _: StackStatus = try await self.call(["method": "startDaemon"]) }
    }
    func reloadStack() async {
        await run(L("busy.reloading")) { let _: Bool = try await self.call(["method": "reloadStack"]) }
        try? await Task.sleep(for: .milliseconds(800))
        await refreshStatus()
    }
    func processAction(_ id: String, _ action: String, from surface: StopSurface = .window) async {
        var done = false
        await run(L("busy.\(action)"), from: surface,
                  failureTitle: String(format: L(action == "stop" ? "error.stopFailed" : "error.startFailed"), processTitle(id))) {
            let _: Bool = try await self.call(["method": "processAction", "id": id, "action": action])
            done = true
        }
        // Starting and stopping can be taken back; a restart leaves nothing to undo.
        if done, action == "start" || action == "stop" {
            let opposite = action == "start" ? "stop" : "start"
            undoable(String(format: L(action == "start" ? "menu.undo.start" : "menu.undo.stop"), processTitle(id)),
                     undo: { [weak self] in await self?.processAction(id, opposite, from: surface) },
                     redo: { [weak self] in await self?.processAction(id, action, from: surface) })
        }
        try? await Task.sleep(for: .milliseconds(600))
        await refreshStatus()
    }
    func watchLogs(_ id: String) async {
        while daemonRunning && !Task.isCancelled {
            do {
                for try await lines in engine.logStream(id) {
                    guard !Task.isCancelled else { return }
                    if logs[id] != lines { logs[id] = lines }
                }
            } catch { /* Retry if the process is still available. */ }
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
        }
    }
    // MARK: Session agent (ports 53/80/443)
    func installAgent() async {
        await run(L("busy.agent")) { let _: [String: Bool] = try await self.call(["method": "installAgent", "confirmed": true]) }
        try? await Task.sleep(for: .seconds(2))
        await refresh(); await refreshPorts()
    }
    func uninstallAgent() async {
        await run(L("busy.agent")) { let _: [String: Bool] = try await self.call(["method": "uninstallAgent", "confirmed": true]) }
        await refresh(); await refreshPorts()
    }
}
