import AppKit
import SwiftUI

extension StackStore {
    /// A service type has something installed (or, for broadcasting, a site that runs Reverb).
    func categoryInstalled(_ category: String) -> Bool {
        switch category {
        case "web": true
        case "broadcasting": projects.contains { $0.processes.contains { $0.args.contains("reverb:start") } }
        default: Route.engines(in: category).contains { engineVersion($0) != nil }
        }
    }
    // MARK: Engines (MySQL, Redis) run directly by the stack
    func engineEnabled(_ name: String) -> Bool { config?.engines?[name]?.enabled == true }
    func engineVersion(_ name: String) -> String? { installedTools[name]?.first?.version }
    /// Turns a service on or off. Turning off one that projects that are on use asks first, naming
    /// them (`serviceStop`), on the surface it was asked from; `confirmed` is that answer.
    func setEngine(_ name: String, enabled: Bool, confirmed: Bool = false, from surface: StopSurface = .window) async {
        await run(enabled ? L("busy.start") : L("busy.stop")) {
            do {
                self.config = try await self.call(["method": "setEngine", "engine": name, "enabled": enabled,
                                                   "confirmed": confirmed, "actor": "app"])
            } catch let failure as EngineFailure where failure.code == "service_in_use" {
                self.serviceStop = ServiceStopRequest(service: name, users: failure.detail ?? "", surface: surface)
            }
        }
        try? await Task.sleep(for: .milliseconds(900))
        await refreshStatus()
        await loadAttention()
    }
}
