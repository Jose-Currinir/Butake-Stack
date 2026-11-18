import SwiftUI

/// A switched-off service that projects that are on use: the confirmation names them.
struct ServiceStopRequest: Identifiable, Hashable {
    let service: String
    /// Their names, as the engine said them.
    let users: String
    /// Where the stop was asked: only that surface asks, so the panel and the window never both do.
    var surface: StopSurface = .window
    var id: String { service }
}

/// The two places a service is turned off from: the main window (Inicio, the service pages, the palette) and the
/// menu bar panel.
enum StopSurface: Hashable, Sendable { case window, panel }

/// An error ready to show on the surface that asked: what happened, the cause when the engine
/// says it, and the button that helps («Reintentar» when the action can run again, «Abrir Registros»
/// when the cause is not known). The window shows it as an alert and the panel as a banner.
struct ActionFailure: Identifiable {
    let id = UUID()
    var title: String
    var message: String
    /// Runs the same action again; nil when it cannot be repeated.
    var retry: (@MainActor () async -> Void)?
    /// The engine gave no cause of its own: the logs may have it.
    var offersLogs = false

    init(title: String, message: String, retry: (@MainActor () async -> Void)? = nil, offersLogs: Bool = false) {
        self.title = title; self.message = message; self.retry = retry; self.offersLogs = offersLogs
    }

    init(error: Error, title: String? = nil, retry: (@MainActor () async -> Void)? = nil) {
        let known = (error as? EngineFailure).map {
            $0.messageKey != "engine.requestFailed" && (localized($0.messageKey) != nil || $0.detail != nil)
        } ?? false
        self.init(title: title ?? L("error.title"), message: EngineFailure.message(error), retry: retry, offersLogs: !known)
    }
}

/// What `setSiteEnabled` answers beyond the project: the services Stack turned on with it.
struct SiteSwitch: Decodable { let servicesStarted: [String]? }

/// What each project needs now (P-42): read from the engine with the projects, shown on the
/// project's page with its one-click fix and, for projects that are on, in Inicio.
extension StackStore {
    func loadAttention() async {
        guard let value: [String: [ProjectAttention]] = try? await call(["method": "projectAttention"]) else { return }
        if attention != value { attention = value }
    }

    /// Items of projects that are on: Inicio says them as «necesita atención».
    var attentionOn: [(project: Project, items: [ProjectAttention])] {
        projects.filter { $0.enabled && !$0.isMissing }.compactMap { project in
            attention[project.id].flatMap { $0.isEmpty ? nil : (project, $0) }
        }
    }

    /// Applies the fix the engine offers for `item` (recomputed there, never sent from here).
    func applyFix(_ item: ProjectAttention, of project: Project) async {
        guard let fix = item.fix else { return }
        var done = false
        await run(L("busy.saving"), refresh: true) {
            let _: Project = try await self.call(["method": "applyProjectFix", "id": project.id, "fix": fix.id,
                                                   "process": fix.process ?? ""])
            done = true
        }
        if done { notify(L("attention.fixed")) }
        try? await Task.sleep(for: .milliseconds(900))
        await refreshStatus()
    }

    /// One line that says what `item` is, in the project's words.
    func attentionText(_ item: ProjectAttention) -> String {
        let service = item.service.map { Tech.of($0).title } ?? ""
        switch item.code {
        case "service_off": return String(format: L("attention.service_off"), service)
        case "service_missing": return String(format: L("attention.service_missing"), service)
        case "port_conflict": return String(format: L("attention.port_conflict"), item.port ?? 0, item.other ?? "")
        case "serves_repository": return L("attention.serves_repository")
        case "unsafe_web_path": return L("attention.unsafe_web_path")
        case "serves_project_root": return L("attention.serves_project_root")
        case "program_missing": return String(format: L("attention.program_missing"), item.process ?? "", item.program ?? "")
        case "script_missing": return String(format: L("attention.script_missing"), item.process ?? "", item.script ?? "")
        case "script_forwards": return String(format: L("attention.script_forwards"), item.script ?? "", item.wanted ?? "")
        case "node_mismatch": return String(format: L("attention.node_mismatch"), item.current ?? "", item.source ?? "", item.wanted ?? "")
        case "node_missing": return String(format: L("attention.node_missing"), item.wanted ?? "", item.current ?? "")
        default: return L("attention.other")
        }
    }

    /// The fix's button: what it does, in a few words.
    func fixTitle(_ fix: ProjectAttention.Fix) -> String {
        switch fix.id {
        case "startService": String(format: L("attention.fix.startService"), Tech.of(fix.value ?? "").title)
        case "useScript": String(format: L("attention.fix.useScript"), fix.value ?? "")
        case "setNode": String(format: L("attention.fix.setNode"), fix.value ?? "")
        case "makeUnserved": L("attention.fix.makeUnserved")
        default: L("attention.fix")
        }
    }

    /// Removes a PHP line, with the guard of every language (a project or the global line uses it).
    func removePhp(_ series: String) async {
        await run(L("busy.removing")) { let _: Bool = try await self.call(["method": "removePhp", "series": series, "confirmed": true]) }
        await refreshRuntimes()
    }
}

/// «¿Detener PostgreSQL?» naming the projects that are on and use it; stopping is never the
/// default. Inicio, the service pages and the menu bar panel all ask this way.
struct ServiceStopConfirmation: ViewModifier {
    @Bindable var store: StackStore
    let surface: StopSurface
    /// Whether this surface asks for that request: only the one it came from.
    static func asks(_ request: ServiceStopRequest?, on surface: StopSurface) -> Bool { request?.surface == surface }
    func body(content: Content) -> some View {
        let mine = Self.asks(store.serviceStop, on: surface) ? store.serviceStop : nil
        content.confirmationDialog(
            String(format: L("attention.stopTitle"), Tech.of(mine?.service ?? "").title),
            isPresented: Binding(get: { mine != nil }, set: { if !$0, Self.asks(store.serviceStop, on: surface) { store.serviceStop = nil } }),
            presenting: mine
        ) { request in
            Button(L("engine.stop"), role: .destructive) {
                Task { await store.setEngine(request.service, enabled: false, confirmed: true, from: request.surface) }
            }
                .accessibilityIdentifier("service.stop.confirm")
            Button(L("common.cancel"), role: .cancel) {}
        } message: { request in
            Text(String(format: L("attention.stopDetail"), request.users))
        }
    }
}

extension View {
    func serviceStopConfirmation(_ store: StackStore, on surface: StopSurface = .window) -> some View {
        modifier(ServiceStopConfirmation(store: store, surface: surface))
    }
}

/// What went wrong, its cause when the engine says it, and the button that helps. Only what was
/// asked in the window: the menu bar panel shows its own (`panelFailure`).
private struct FailureAlert: ViewModifier {
    @Bindable var store: StackStore
    func body(content: Content) -> some View {
        content.alert(store.windowFailure?.title ?? L("error.title"),
                      isPresented: Binding(get: { store.windowFailure != nil }, set: { if !$0 { store.dismissFailure() } }),
                      presenting: store.windowFailure) { failure in
            if let retry = failure.retry {
                Button(L("error.retry")) { Task { await retry() } }.accessibilityIdentifier("error.retry")
            }
            if failure.offersLogs {
                Button(L("error.openLogs")) { store.route = .tool("logs") }.accessibilityIdentifier("error.openLogs")
            }
            Button(L("common.cancel"), role: .cancel) {}
        } message: { Text($0.message) }
    }
}

extension View {
    func failureAlert(_ store: StackStore) -> some View { modifier(FailureAlert(store: store)) }
}
