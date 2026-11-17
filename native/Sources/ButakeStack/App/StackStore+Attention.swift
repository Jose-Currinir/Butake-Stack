import SwiftUI

/// A switched-off service that projects that are on use: the confirmation names them.
struct ServiceStopRequest: Identifiable, Hashable {
    let service: String
    /// Their names, as the engine said them.
    let users: String
    var id: String { service }
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
    func body(content: Content) -> some View {
        content.confirmationDialog(
            String(format: L("attention.stopTitle"), Tech.of(store.serviceStop?.service ?? "").title),
            isPresented: Binding(get: { store.serviceStop != nil }, set: { if !$0 { store.serviceStop = nil } }),
            presenting: store.serviceStop
        ) { request in
            Button(L("engine.stop"), role: .destructive) { Task { await store.setEngine(request.service, enabled: false, confirmed: true) } }
                .accessibilityIdentifier("service.stop.confirm")
            Button(L("common.cancel"), role: .cancel) {}
        } message: { request in
            Text(String(format: L("attention.stopDetail"), request.users))
        }
    }
}

extension View {
    func serviceStopConfirmation(_ store: StackStore) -> some View { modifier(ServiceStopConfirmation(store: store)) }
}
