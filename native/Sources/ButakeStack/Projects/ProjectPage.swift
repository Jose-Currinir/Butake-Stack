import AppKit
import SwiftUI

/// What the Proyecto menu opens on the project shown: its settings sheet.
struct ProjectSettingsRequest {
    let open: @MainActor () -> Void
}

extension FocusedValues {
    /// «Ajustes del proyecto…» of the project on screen (Proyecto menu, ⌘I).
    @Entry var projectSettings: ProjectSettingsRequest?
    /// The tabs of the project on screen (Proyecto menu, ⌃⌥1…4).
    @Entry var projectTabs: ProjectTabRequest?
}

/// What the Proyecto menu does with the tabs of the project on screen (⌃⌥1…4).
struct ProjectTabRequest {
    /// The tabs the page has now (Procesos only when the project runs processes).
    let available: [ProjectPage.Tab]
    let select: @MainActor (ProjectPage.Tab) -> Void
}

extension ProjectPage.Tab {
    /// The key of each tab in Proyecto: ⌃⌥ + 1…4. ⌘⌥ + number is Git's, ⌃⌘ + number goes to the tools.
    var shortcutKey: Character { switch self { case .summary: "1"; case .envs: "2"; case .processes: "3"; case .logs: "4" } }
}

/// A project as its own page: its head (`ProjectHeader`: logo, name, kind and address, state and
/// actions with their words), the tabs under it (Resumen, Entornos, Procesos when it has them,
/// Registros) and editing in «Ajustes del proyecto…». The window's toolbar keeps only its «+».
struct ProjectPage: View {
    @Bindable var store: StackStore
    let project: Project
    enum Tab: String, CaseIterable, Identifiable { case summary, envs, processes, logs; var id: String { rawValue } }
    /// The tab on screen, kept with the window like the page.
    @SceneStorage("project.tab") private var tab: Tab = .summary
    /// The tab a link from elsewhere asked for (the vault's «Entornos»), taken once on appear.
    @MainActor static var requestedTab: Tab?
    @State private var editing = false
    @State private var logProcess: String?

    /// Procesos only exists for a served project that runs processes (a project without a server
    /// has its commands in Resumen); Registros always (Caddy, PHP-FPM, its commands…).
    var tabs: [Tab] { Tab.allCases.filter { $0 != .processes || (project.isServed && !project.processes.isEmpty) } }

    var body: some View {
        VStack(spacing: 0) {
            if project.isMissing {
                MissingProjectPanel(store: store, project: project)
            } else {
                ProjectHeader(store: store, project: project) { editing = true }
                DetailTabs(tabs: tabs, selection: $tab, title: { L("site.tab.\($0.rawValue)") }, label: L("site.tabs"))
                notices
                switch tab {
                case .summary: ProjectSummary(store: store, project: project) { id in logProcess = id; tab = .logs }
                case .envs: EnvironmentsView(store: store, project: project)
                case .processes: processes
                case .logs: logs
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .sheet(isPresented: $editing) { ProjectSettingsSheet(store: store, project: project, notes: [], isNew: false).themedSheet() }
        .focusedSceneValue(\.projectSettings, project.isMissing ? nil : ProjectSettingsRequest { editing = true })
        .focusedSceneValue(\.projectTabs, project.isMissing ? nil : ProjectTabRequest(available: tabs) { tab = $0 })
        .onAppear {
            // The saved tab may belong to a project with processes.
            if let requested = Self.requestedTab { tab = requested; Self.requestedTab = nil }
            if !tabs.contains(tab) { tab = .summary }
            logProcess = logProcess ?? project.processes.first(where: \.autostart).map { "\(project.id).\($0.name)" } ?? logSources.first?.id
            #if DEBUG
            if let qa = QAHooks.projectTab.flatMap(Tab.init(rawValue:)) { tab = qa }
            if QAHooks.projectSheet == "settings" { Task { try? await Task.sleep(for: .seconds(1)); editing = true } }
            #endif
        }
        .task(id: project.id) { await store.loadWorktrees(project.id) }
    }

    // MARK: Notices

    /// What the project needs right now, above every tab: a branch that changed, production active.
    @ViewBuilder private var notices: some View {
        let branch = store.branchNotices[project.id]
        let production = store.activeEnvironment(project.id)?.kind == .production && tab != .envs
        let attention = store.attention[project.id] ?? []
        if branch != nil || production || !attention.isEmpty {
            VStack(spacing: 10) {
                if let branch { BranchNotice(store: store, project: project, changes: branch) }
                if production { Notice(.error, L("env.productionActive"), symbol: EnvKind.production.symbol) }
                ForEach(attention) { AttentionNotice(store: store, project: project, item: $0) }
            }
            .padding(.horizontal, 20).padding(.top, 14)
        }
    }

    // MARK: Procesos

    private var processes: some View {
        Form {
            Section {
                ForEach(project.processes) { process in
                    ProcessRow(store: store, id: "\(project.id).\(process.name)", process: process) { id in logProcess = id; tab = .logs }
                }
            } header: {
                HStack {
                    Text(L("site.processes"))
                    Spacer()
                    ProcessBatchMenu(store: store, project: project)
                }
            } footer: {
                Text(String(format: L("site.processesRunning"), store.runningProcesses(project), project.processes.count))
                    .font(.uiCaption).foregroundStyle(.secondary).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped).themedScroll()
    }

    // MARK: Registros

    /// Logs that concern this project: its processes, then the web server, its PHP-FPM, its services
    /// and its public tunnel, when they run.
    private var logSources: [LogTarget] {
        let running = Set(store.status?.processes.map(\.id) ?? [])
        var ids = project.processes.map { "\(project.id).\($0.name)" }
        var stack = ["stack.caddy"]
        if let php = project.php { stack.append("stack.php-" + php.replacingOccurrences(of: ".", with: "-")) }
        stack += project.services.map { "stack.\($0)" }
        stack += ["share.\(project.id)", "public.\(project.id)"]
        ids += stack.filter(running.contains)
        return ids.map { LogTarget(id: $0) }
    }

    private var logs: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                if !logSources.isEmpty {
                    Picker(L("process.logs"), selection: Binding(get: { logProcess ?? "" }, set: { logProcess = $0 })) {
                        ForEach(logSources) { Text(store.processTitle($0.id)).tag($0.id) }
                    }
                    .pickerStyle(.menu).fixedSize().accessibilityIdentifier("project.logSource")
                }
                Spacer()
                Button { if let id = logProcess { store.showLogs(id) } else { store.route = .tool("logs") } } label: { Label(L("logs.all"), systemImage: Symbols.logs) }
                    .buttonStyle(.bordered).accessibilityIdentifier("project.allLogs")
            }
            if let id = logProcess { LiveLog(store: store, id: id).id(id) }
            else { ContentUnavailableView(L("logs.none"), systemImage: Symbols.logs).frame(maxHeight: .infinity) }
        }
        .padding(20)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

/// Something the project needs (P-42), with the fix Stack applies in one click when there is one.
private struct AttentionNotice: View {
    let store: StackStore
    let project: Project
    let item: ProjectAttention
    var body: some View {
        Notice(.warning, store.attentionText(item)) {
            if let fix = item.fix {
                Button { Task { await store.applyFix(item, of: project) } } label: { Label(store.fixTitle(fix), systemImage: Symbols.start) }
                    .buttonStyle(.bordered).controlSize(.small).disabled(store.busy != nil)
                    .accessibilityIdentifier("project.attention.fix.\(item.id)")
            }
        }
        .accessibilityIdentifier("project.attention.\(item.id)")
    }
}

/// After a branch switch: what the project needs to catch up (dependencies, migrations), one click each.
private struct BranchNotice: View {
    let store: StackStore
    let project: Project
    let changes: BranchChanges
    var body: some View {
        Notice(.info, String(format: L("branch.changed"), store.git[project.id]?.branch ?? ""),
               detail: [changes.composer ? L("branch.composer") : nil, changes.npm ? L("branch.npm") : nil,
                        changes.migrations > 0 ? String(format: L("branch.migrations"), changes.migrations) : nil].compactMap { $0 }.joined(separator: " · "),
               symbol: Symbols.git) {
            HStack(spacing: 8) {
                if changes.composer { task("composer", "shippingbox") }
                if changes.npm { task("npm", "cube") }
                if changes.migrations > 0 { task("migrate", Symbols.database) }
                Button { Motion.run(.snappy) { store.branchNotices[project.id] = nil } } label: { Label(L("common.close"), systemImage: Symbols.close).labelStyle(.iconOnly) }
                    .buttonStyle(.borderless).help(L("common.close")).accessibilityIdentifier("branch.dismiss")
            }
        }
        .transitioned(.move(edge: .top).combined(with: .opacity))
    }
    private func task(_ name: String, _ symbol: String) -> some View {
        Button {
            Task { await store.runSiteTask(project, name) }
        } label: {
            if store.runningTask == "\(project.id).\(name)" { ProgressView().controlSize(.mini) }
            Label(L("task.\(name)"), systemImage: symbol)
        }
        .buttonStyle(.bordered).controlSize(.small).disabled(store.runningTask != nil)
        .accessibilityIdentifier("branch.task.\(name)")
    }
}
