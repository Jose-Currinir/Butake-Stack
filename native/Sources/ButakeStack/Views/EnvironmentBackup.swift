import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// "Mi entorno" in General: export everything needed to set up another Mac the same way (never
/// secrets), or restore it from a file with a plan reviewed first.
struct EnvironmentBackupCard: View {
    @Bindable var store: StackStore
    @State private var restore: RestoreRequest?
    var body: some View {
        CardBlock(title: L("backup.title"), symbol: "externaldrive.badge.icloud", footer: L("backup.footer")) {
            VStack(alignment: .leading, spacing: 10) {
                Text(L("backup.detail")).font(.uiCallout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button { Task { await export() } } label: { Label(L("backup.export"), systemImage: "square.and.arrow.up") }
                        .accessibilityIdentifier("backup.export")
                    Button { open() } label: { Label(L("backup.restore"), systemImage: "square.and.arrow.down") }
                        .accessibilityIdentifier("backup.restore")
                }
                .disabled(store.busy != nil)
            }
        }
        .sheet(item: $restore) { request in RestoreSheet(store: store, request: request).themedSheet() }
    }

    func export() async {
        let profiles = (UserDefaults.standard.string(forKey: "setup.profiles") ?? "").split(separator: ",").map(String.init)
        guard let data: JSONValue = try? await store.call(["method": "exportEnvironment", "profiles": profiles]) else {
            store.errorMessage = L("engine.requestFailed"); return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        let date = Date().formatted(.iso8601.year().month().day())
        panel.nameFieldStringValue = "mi-entorno-butake-stack-\(date).json"
        panel.message = L("backup.saveMessage")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(data).write(to: url, options: .atomic)
            // Paths and project names are personal: readable only by the user.
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            store.notify(L("backup.saved"))
        } catch { store.errorMessage = L("backup.saveFailed") }
    }

    func open() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.message = L("backup.openMessage")
        guard panel.runModal() == .OK, let url = panel.url,
              let bytes = try? Data(contentsOf: url), bytes.count < 20_000_000,
              let data = try? JSONDecoder().decode(JSONValue.self, from: bytes) else { return }
        Task {
            if let plan: RestorePlan = try? await store.call(["method": "planRestore", "data": data.any]) {
                restore = RestoreRequest(data: data, plan: plan)
            } else {
                store.errorMessage = L("error.invalid_backup")
            }
        }
    }
}

/// Arbitrary JSON kept as-is (the backup travels from the engine to a file and back).
enum JSONValue: Codable, Sendable, Hashable {
    case null, bool(Bool), number(Double), string(String), array([JSONValue]), object([String: JSONValue])
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): if n == n.rounded(), abs(n) < 1e15 { try c.encode(Int64(n)) } else { try c.encode(n) }
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
    /// As JSONSerialization objects, to send back to the engine.
    var any: Any {
        switch self {
        case .null: NSNull()
        case .bool(let b): b
        case .number(let n): n == n.rounded() && abs(n) < 1e15 ? Int64(n) as Any : n as Any
        case .string(let s): s
        case .array(let a): a.map(\.any)
        case .object(let o): o.mapValues(\.any)
        }
    }
}

struct RestorePlan: Decodable, Sendable {
    struct Tool: Decodable, Sendable, Hashable { let tool: String; let version: String }
    struct Site: Decodable, Sendable, Hashable, Identifiable {
        let id: String; let name: String?; let kind: String?; let path: String; let remote: String?; let branch: String?; let state: String
    }
    let profiles: [String]?
    let php: [String]
    let tools: [Tool]
    let devtools: [String]
    let python: [String]
    let sites: [Site]
    let groups: Int
    let environments: Int
}
struct RestoreRequest: Identifiable, Sendable {
    let id = UUID()
    let data: JSONValue
    let plan: RestorePlan
}

/// The restore plan, part by part, then each step with its result.
struct RestoreSheet: View {
    @Bindable var store: StackStore
    let request: RestoreRequest
    @Environment(\.dismiss) private var dismiss
    @State private var downloads = true
    @State private var devtools = true
    @State private var clones: Set<String> = []
    @State private var settings = true
    @State private var organize = true
    @State private var steps: [Step] = []
    @State private var running = false
    @State private var finished = false

    struct Step: Identifiable { let id = UUID(); let title: String; var state: State; enum State { case waiting, working, done, failed } }
    var plan: RestorePlan { request.plan }
    var cloneable: [RestorePlan.Site] { plan.sites.filter { $0.state == "clone" } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                IconTile(symbol: "externaldrive.badge.icloud", size: 46)
                VStack(alignment: .leading, spacing: 3) {
                    Text(L("backup.restoreTitle")).font(.system(size: 20, weight: .bold, design: .rounded))
                    Text(L("backup.restoreDetail")).font(.uiCaption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            .padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if running || finished { progress } else { options }
                }
                .padding(20)
            }
            .themedScroll()
            Divider()
            HStack {
                Text(L("backup.noSecrets")).font(.uiCaption).foregroundStyle(.secondary)
                Spacer()
                if finished {
                    Button(L("setup.done")) { dismiss() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                } else {
                    Button(L("action.cancel")) { dismiss() }.keyboardShortcut(.cancelAction).disabled(running)
                    Button(L("backup.apply")) { Task { await apply() } }
                        .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).disabled(running)
                        .accessibilityIdentifier("backup.apply")
                }
            }
            .padding(14)
        }
        .frame(width: 680, height: 640)
        .interactiveDismissDisabled(running)
        .onAppear { clones = Set(cloneable.map(\.id)) }
    }

    @ViewBuilder private var options: some View {
        let downloadsList = plan.php.map { "PHP \($0)" } + plan.tools.map { "\(Tech.of($0.tool).title) \($0.version)" }
        PlanPart(isOn: $downloads, symbol: "arrow.down.circle", title: L("backup.part.downloads"),
                 detail: downloadsList.isEmpty ? L("backup.nothing") : downloadsList.joined(separator: " · "), enabled: !downloadsList.isEmpty)
        let devList = plan.devtools.map { L("tool.\($0)") } + plan.python.map { "Python \($0)" }
        PlanPart(isOn: $devtools, symbol: "hammer", title: L("backup.part.devtools"),
                 detail: devList.isEmpty ? L("backup.nothing") : devList.joined(separator: " · "), enabled: !devList.isEmpty)
        VStack(alignment: .leading, spacing: 8) {
            Label(L("backup.part.sites"), systemImage: "globe").font(.ui(size: 13, weight: .semibold))
            VStack(spacing: 0) {
                ForEach(Array(plan.sites.enumerated()), id: \.element.id) { index, site in
                    if index > 0 { Divider().padding(.leading, 40) }
                    HStack(spacing: 10) {
                        if site.state == "clone" {
                            Toggle("", isOn: Binding(get: { clones.contains(site.id) }, set: { if $0 { clones.insert(site.id) } else { clones.remove(site.id) } }))
                                .toggleStyle(.checkbox).labelsHidden()
                        } else {
                            Image(systemName: site.state == "unavailable" ? "minus.circle" : "checkmark.circle").foregroundStyle(site.state == "unavailable" ? Color.secondary : Brand.success).frame(width: 16)
                        }
                        TechLogo(tech: .of(site.kind ?? "static"), size: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(site.name ?? site.id).font(.uiCallout.weight(.medium))
                            Text(site.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).font(.uiCaption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Chip(text: L("backup.site.\(site.state)"), tint: site.state == "clone" ? Brand.accent : .secondary)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 7)
                }
            }
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.035)))
        }
        PlanPart(isOn: $organize, symbol: "folder", title: L("backup.part.organize"),
                 detail: String(format: L("backup.organizeDetail"), plan.groups, plan.environments), enabled: plan.groups + plan.environments > 0)
        PlanPart(isOn: $settings, symbol: "gearshape", title: L("backup.part.settings"), detail: L("backup.settingsDetail"), enabled: true)
    }

    private var progress: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(steps) { step in
                HStack(spacing: 10) {
                    Group {
                        switch step.state {
                        case .waiting: Image(systemName: "circle").foregroundStyle(.tertiary)
                        case .working: ProgressView().controlSize(.small)
                        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(Brand.success)
                        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Brand.warning)
                        }
                    }
                    .frame(width: 18)
                    Text(step.title).foregroundStyle(step.state == .waiting ? .secondary : .primary)
                }
                .transition(.opacity)
            }
        }
        .animation(.snappy, value: steps.map(\.state.hashValue))
    }

    /// Runs the chosen parts in order: downloads, tools, clones, then sites, folders, environments and settings.
    func apply() async {
        var work: [(String, () async -> Bool)] = []
        if downloads {
            if store.phpCatalog.isEmpty { await store.loadPhpCatalog() }
            for series in plan.php {
                if let entry = store.phpCatalog.filter({ $0.series == series }).max(by: { $0.version.compare($1.version, options: .numeric) == .orderedAscending }) {
                    work.append(("PHP \(entry.version)", { await store.downloadPhp(entry.version); return store.phpRuntimes.contains { $0.series == series && $0.installed } }))
                }
            }
            for tool in plan.tools {
                work.append(("\(Tech.of(tool.tool).title) \(tool.version)", {
                    await store.installTool(tool.tool, tool.version)
                    return (store.installedTools[tool.tool] ?? []).contains { $0.version == tool.version }
                }))
            }
        }
        if devtools {
            for tool in plan.devtools {
                work.append((L("tool.\(tool)"), { await store.installDevTool(tool, acceptLicenses: tool == "android-sdk"); return store.devTools[tool]?.installed == true }))
            }
            for line in plan.python {
                work.append(("Python \(line)", { await store.installDevTool("python", version: line); return true }))
            }
        }
        for site in cloneable where clones.contains(site.id) {
            guard let remote = site.remote else { continue }
            work.append((String(format: L("backup.cloning"), site.name ?? site.id), {
                let ok: Bool? = try? await store.call(["method": "cloneSite", "path": site.path, "remote": remote, "branch": site.branch ?? "", "confirmed": true])
                return ok == true
            }))
        }
        let parts: [String: Any] = ["config": settings, "sites": true, "groups": organize, "environments": organize]
        work.append((L("backup.applySites"), {
            let result: JSONValue? = try? await store.call(["method": "restoreEnvironment", "data": request.data.any, "parts": parts, "confirmed": true])
            await store.refresh()
            return result != nil
        }))
        steps = work.map { Step(title: $0.0, state: .waiting) }
        withAnimation(.smooth) { running = true }
        for (index, item) in work.enumerated() {
            steps[index].state = .working
            let ok = await item.1()
            steps[index].state = ok ? .done : .failed
        }
        running = false
        withAnimation(.smooth) { finished = true }
        store.notify(L("backup.restored"))
    }
}

private struct PlanPart: View {
    @Binding var isOn: Bool
    let symbol: String
    let title: String
    let detail: String
    let enabled: Bool
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: $isOn).toggleStyle(.checkbox).labelsHidden().disabled(!enabled)
            Image(systemName: symbol).foregroundStyle(Brand.accent).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.ui(size: 13, weight: .semibold))
                Text(detail).font(.uiCaption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.035)))
        .opacity(enabled ? 1 : 0.6)
    }
}
