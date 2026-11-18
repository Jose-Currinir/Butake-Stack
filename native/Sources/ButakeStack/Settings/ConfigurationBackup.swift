import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension StackStore {
    /// Archivo › Exportar configuración…: everything needed to set up another Mac the same way
    /// (never secrets), saved where the user chooses. With «Incluir bases de datos» it becomes a
    /// folder: the configuration file and a dump of each database of Stack's engines (`bases/`).
    func exportConfiguration() async {
        let profiles = (UserDefaults.standard.string(forKey: "setup.profiles") ?? "").split(separator: ",").map(String.init)
        let data: JSONValue
        do { data = try await call(["method": "exportEnvironment", "profiles": profiles]) } catch { report(error); return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        let date = Format.fileStamp()
        panel.nameFieldStringValue = String(format: L("backup.defaultName"), date)
        panel.message = L("backup.saveMessage")
        var checkbox: NSButton?
        if !(await backupConnections()).isEmpty {
            let box = NSButton(checkboxWithTitle: L("backup.includeDatabases"), target: nil, action: nil)
            box.setAccessibilityIdentifier("backup.includeDatabases")
            box.state = .on
            let stack = NSStackView(views: [box])
            stack.edgeInsets = NSEdgeInsets(top: 10, left: 16, bottom: 10, right: 16)
            panel.accessoryView = stack
            checkbox = box
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var output = data
        var destination = url
        var saved: [DatabaseBackupEntry] = []
        if checkbox?.state == .on {
            let folder = url.deletingPathExtension()
            guard !FileManager.default.fileExists(atPath: folder.path) else { errorMessage = L("backup.folderExists"); return }
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                saved = try await backupDatabases(into: folder)
                output = try data.setting("databases", to: saved)
                destination = folder.appendingPathComponent(url.lastPathComponent)
            } catch {
                // Only what this export wrote: the folder did not exist before.
                try? FileManager.default.removeItem(at: folder)
                errorMessage = (error as? LocalizedError)?.errorDescription ?? L("backup.saveFailed")
                return
            }
        }
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(output).write(to: destination, options: .atomic)
            // Paths and project names are personal: readable only by the user.
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            notify(saved.isEmpty ? L("backup.saved") : String(format: L("backup.savedWithDatabases"), saved.count))
            // Left out on purpose, but the user has to know (a view whose tables are gone).
            let skipped = saved.flatMap { $0.skippedViews ?? [] }
            if !skipped.isEmpty { errorMessage = String(format: L("backup.skippedViews"), skipped.count, skipped.joined(separator: ", ")) }
        } catch { errorMessage = L("backup.saveFailed") }
    }

    /// Archivo › Restaurar configuración…: asks for an exported file and reads its plan, to review
    /// before anything changes. Nil when the user cancels or the file is not a configuration.
    func planRestore() async -> RestoreRequest? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.message = L("backup.openMessage")
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        // The size is checked before reading: a huge file is never loaded.
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? .max
        guard size < 20_000_000, let bytes = try? Data(contentsOf: url),
              let data = try? JSONDecoder().decode(JSONValue.self, from: bytes) else {
            errorMessage = L("error.invalid_backup")
            return nil
        }
        guard let plan: RestorePlan = try? await call(["method": "planRestore", "data": data.any]) else {
            errorMessage = L("error.invalid_backup")
            return nil
        }
        return RestoreRequest(data: data, plan: plan, folder: url.deletingLastPathComponent())
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
    /// Catalog extensions installed there and not here, per PostgreSQL version (P-43).
    struct Extension: Decodable, Sendable, Hashable { let component: String; let version: String; let id: String }
    let extensions: [Extension]?
}
struct RestoreRequest: Identifiable, Sendable {
    let id = UUID()
    let data: JSONValue
    let plan: RestorePlan
    /// Where the configuration file is: the saved databases are next to it.
    var folder: URL?
    /// The databases the file lists (exported with «Incluir bases de datos»).
    var databases: [DatabaseBackupEntry] { (try? data.decoded("databases", as: [DatabaseBackupEntry].self)) ?? [] }
    /// Those whose dump is not next to the file (copied without its folder).
    var missingDatabases: [DatabaseBackupEntry] {
        databases.filter { entry in folder.map { !FileManager.default.fileExists(atPath: $0.appendingPathComponent(entry.file).path) } ?? true }
    }
}

/// The restore plan, part by part, then each step with its result.
struct RestoreSheet: View {
    @Bindable var store: StackStore
    let request: RestoreRequest
    @Environment(\.dismiss) private var dismiss
    @State private var downloads = true
    @State private var devtools = true
    @State private var extensions = true
    @State private var clones: Set<String> = []
    @State private var settings = true
    @State private var organize = true
    @State private var restoreDatabases = true
    @State private var steps: [Step] = []
    @State private var running = false
    @State private var finished = false
    /// The install under way, followed step by step (`InstallMonitor`).
    @State private var current: InstallMonitor?
    /// «Cancelar» while it runs: the install under way stops and what remains is skipped.
    @State private var stopping = false

    struct Step: Identifiable { let id = UUID(); var title: String; var state: State; enum State { case waiting, working, done, failed, skipped } }
    var plan: RestorePlan { request.plan }
    var cloneable: [RestorePlan.Site] { plan.sites.filter { $0.state == "clone" } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                IconTile(symbol: "externaldrive.badge.icloud", size: 46)
                VStack(alignment: .leading, spacing: 3) {
                    Text(L("backup.restoreTitle")).font(.uiTitle.weight(.bold)).fontDesign(.rounded)
                    Text(L("backup.restoreDetail")).font(.uiCaption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
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
                    Button(L("common.done")) { dismiss() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("backup.done")
                } else {
                    Button(L("common.cancel")) {
                        guard running else { dismiss(); return }
                        stopping = true
                        current?.cancel()
                    }
                    .keyboardShortcut(.cancelAction)
                    .disabled(stopping || current.map { !$0.canCancel } == true)
                    .help(current?.cancelHelp ?? "")
                    .accessibilityIdentifier("backup.cancel")
                    Button(L("backup.apply")) { Task { await apply() } }
                        .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).disabled(running)
                        .accessibilityIdentifier("backup.apply")
                }
            }
            .padding(14)
        }
        // Flexible: the content scrolls, so the sheet fits the minimum window (960×600) and still opens roomy.
        .frame(minWidth: 520, idealWidth: 680, maxWidth: 760, minHeight: 360, idealHeight: 520, maxHeight: 640)
        .interactiveDismissDisabled(running)
        .onAppear { clones = Set(cloneable.map(\.id)) }
    }

    @ViewBuilder private var options: some View {
        let downloadsList = plan.php.map { "PHP \($0)" } + plan.tools.map { "\(Tech.of($0.tool).title) \($0.version)" }
        PlanPart(isOn: $downloads, symbol: "arrow.down.circle", title: L("backup.part.downloads"),
                 detail: downloadsList.isEmpty ? L("backup.nothing") : downloadsList.joined(separator: " · "), enabled: !downloadsList.isEmpty, part: "downloads")
        let devList = plan.devtools.map { L("tool.\($0)") } + plan.python.map { "Python \($0)" }
        PlanPart(isOn: $devtools, symbol: "hammer", title: L("backup.part.devtools"),
                 detail: devList.isEmpty ? L("backup.nothing") : devList.joined(separator: " · "), enabled: !devList.isEmpty, part: "devtools")
        let extensionList = (plan.extensions ?? []).map { String(format: L("backup.extensionItem"), $0.id, $0.version) }
        PlanPart(isOn: $extensions, symbol: Symbols.package, title: L("backup.part.extensions"),
                 detail: extensionList.isEmpty ? L("backup.nothing") : extensionList.joined(separator: " · "), enabled: !extensionList.isEmpty, part: "extensions")
        VStack(alignment: .leading, spacing: 8) {
            Label(L("backup.part.sites"), systemImage: Symbols.project).font(.uiHeadline)
            VStack(spacing: 0) {
                ForEach(Array(plan.sites.enumerated()), id: \.element.id) { index, site in
                    if index > 0 { Divider().padding(.leading, 40) }
                    HStack(spacing: 10) {
                        if site.state == "clone" {
                            Toggle(site.name ?? site.id, isOn: Binding(get: { clones.contains(site.id) }, set: { if $0 { clones.insert(site.id) } else { clones.remove(site.id) } }))
                                .toggleStyle(.checkbox).labelsHidden()
                                .accessibilityLabel(String(format: L("backup.cloning"), site.name ?? site.id))
                                .accessibilityIdentifier("backup.clone.\(site.id)")
                        } else {
                            Image(systemName: site.state == "unavailable" ? Symbols.remove : Symbols.success).foregroundStyle(site.state == "unavailable" ? Color.secondary : Brand.success).frame(width: 16)
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
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.035)))  // radius 10: outside the Radius scale, kept as it was
        }
        PlanPart(isOn: $organize, symbol: Symbols.folder, title: L("backup.part.organize"),
                 detail: String(format: L("backup.organizeDetail"), plan.groups, plan.environments), enabled: plan.groups + plan.environments > 0, part: "organize")
        PlanPart(isOn: $settings, symbol: Symbols.settings, title: L("backup.part.settings"), detail: L("backup.settingsDetail"), enabled: true, part: "settings")
        if !request.databases.isEmpty {
            let list = request.databases.map { String(format: L("backup.databaseItem"), $0.database, Tech.of($0.engine).title) }
            let total = request.databases.compactMap(\.size).reduce(0, +)
            let missing = request.missingDatabases.count
            let detail = list.joined(separator: " · ") + " (\(Format.fileSizeText(total)))"
                + (missing > 0 ? "\n" + String(format: L("backup.databasesMissing"), missing) : "")
            PlanPart(isOn: $restoreDatabases, symbol: Symbols.database, title: L("backup.part.databases"), detail: detail,
                     enabled: missing < request.databases.count, part: "databases")
        }
    }

    private var progress: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(steps) { step in
                HStack(spacing: 10) {
                    Group {
                        switch step.state {
                        case .waiting: Image(systemName: Symbols.pending).foregroundStyle(.tertiary)
                        case .working: ProgressView().controlSize(.small)
                        case .done: Image(systemName: Symbols.success).foregroundStyle(Brand.success)
                        case .failed: Image(systemName: Symbols.warning).foregroundStyle(Brand.warning)
                        case .skipped: Image(systemName: Symbols.pending).foregroundStyle(.tertiary)
                        }
                    }
                    .frame(width: 18)
                    Text(step.title).foregroundStyle(step.state == .waiting || step.state == .skipped ? .secondary : .primary)
                }
                .transitioned(.opacity)
                if step.state == .working, let current { InstallStepLine(monitor: current, scope: "backup.progress").padding(.leading, 28) }
            }
        }
        .animated(.snappy, value: steps.map(\.state.hashValue))
    }

    /// Runs the chosen parts in order: downloads, tools, extensions, clones, then sites, folders,
    /// environments and settings.
    func apply() async {
        // Each step: true done, false failed, nil left as it was (a database already here).
        var work: [(String, InstallMonitor?, () async -> Bool?)] = []
        if downloads {
            if store.phpCatalog.isEmpty { await store.loadPhpCatalog() }
            for series in plan.php {
                if let entry = store.phpCatalog.filter({ $0.series == series }).max(by: { $0.version.compare($1.version, options: .numeric) == .orderedAscending }) {
                    let monitor = InstallMonitor(log: "install-php", tool: "php")
                    work.append(("PHP \(entry.version)", monitor, { await monitor.run(store) { try await store.downloadPhpFollowed(entry.version) } }))
                }
            }
            for tool in plan.tools {
                let monitor = InstallMonitor(log: "install-\(tool.tool)", tool: tool.tool)
                work.append(("\(Tech.of(tool.tool).title) \(tool.version)", monitor, {
                    await monitor.run(store) { try await store.installToolFollowed(tool.tool, tool.version) }
                }))
            }
        }
        if devtools {
            for tool in plan.devtools {
                let monitor = InstallMonitor(log: "devtool-\(tool)", tool: tool)
                work.append((L("tool.\(tool)"), monitor, {
                    await monitor.run(store) { try await store.installDevToolFollowed(tool, shellPath: true, acceptLicenses: tool == "android-sdk") }
                }))
            }
            for line in plan.python {
                let monitor = InstallMonitor(log: "install-python", tool: "python")
                work.append(("Python \(line)", monitor, { await monitor.run(store) { try await store.installPythonFollowed(line) } }))
            }
        }
        // After the downloads: the PostgreSQL version an extension goes into may be one of them.
        if extensions {
            for item in plan.extensions ?? [] where item.component == "postgres" {
                let monitor = InstallMonitor(log: StackStore.extensionLog, tool: "extension-\(item.id)")
                work.append((String(format: L("backup.extensionItem"), item.id, item.version), monitor, {
                    await monitor.run(store) { try await store.installExtensionFollowed(item.id, version: item.version) }
                }))
            }
        }
        for site in cloneable where clones.contains(site.id) {
            guard let remote = site.remote else { continue }
            work.append((String(format: L("backup.cloning"), site.name ?? site.id), nil, {
                let ok: Bool? = try? await store.call(["method": "cloneSite", "path": site.path, "remote": remote, "branch": site.branch ?? "", "confirmed": true])
                return ok == true
            }))
        }
        let parts: [String: Any] = ["config": settings, "sites": true, "groups": organize, "environments": organize]
        work.append((L("backup.applySites"), nil, {
            let result: JSONValue? = try? await store.call(["method": "restoreEnvironment", "data": request.data.any, "parts": parts, "confirmed": true])
            await store.refresh()
            return result != nil
        }))
        // Last: the engines are installed and turned on by now.
        if restoreDatabases, let folder = request.folder {
            for entry in request.databases {
                work.append((String(format: L("backup.restoringDatabase"), entry.database, Tech.of(entry.engine).title), nil, {
                    switch await store.restoreDatabase(entry, from: folder) {
                    case .done: return true
                    case .kept: return nil
                    case .failed: return false
                    }
                }))
            }
        }
        steps = work.map { Step(title: $0.0, state: .waiting) }
        Motion.run(.smooth) { running = true }
        for (index, item) in work.enumerated() {
            if stopping { steps[index].state = .skipped; continue }
            steps[index].state = .working
            current = item.1
            let ok = await item.2()
            current = nil
            if let ok {
                steps[index].state = ok ? .done : .failed
            } else {
                steps[index].state = .skipped
                steps[index].title += " · " + L("backup.databaseKept")
            }
        }
        running = false
        Motion.run(.smooth) { finished = true }
        store.notify(L(stopping ? "backup.stopped" : "backup.restored"))
    }
}

private struct PlanPart: View {
    @Binding var isOn: Bool
    let symbol: String
    let title: String
    let detail: String
    let enabled: Bool
    /// Stable id of the part (`backup.part.<name>`), for the checkbox.
    let part: String
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle(title, isOn: $isOn).toggleStyle(.checkbox).labelsHidden().disabled(!enabled)
                .accessibilityLabel(title).accessibilityIdentifier("backup.part.\(part)")
            IconTile(symbol: symbol, size: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.uiHeadline)
                Text(detail).font(.uiCaption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer()
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.035)))  // radius 10: outside the Radius scale, kept as it was
        .opacity(enabled ? 1 : 0.6)
    }
}
