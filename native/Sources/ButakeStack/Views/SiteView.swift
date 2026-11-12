import AppKit
import SwiftUI

/// A site as its own page: hero with live preview, then Resumen, Procesos, Registros and Entorno.
struct SiteView: View {
    @Bindable var store: StackStore
    let project: Project
    enum Tab: String, CaseIterable, Identifiable { case summary, envs, processes, logs, environment; var id: String { rawValue } }
    @State private var tab: Tab = .summary
    @State private var previews = SitePreviews.shared
    @State private var editing = false
    @State private var confirmDelete = false
    @State private var logProcess: String?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                hero
                if let changes = store.branchNotices[project.id] { BranchNotice(store: store, project: project, changes: changes) }
                if store.activeEnvironment(project.id)?.kind == .production, tab != .envs {
                    Label(L("env.productionActive"), systemImage: "exclamationmark.shield.fill")
                        .font(.uiCallout.weight(.medium)).foregroundStyle(Brand.danger)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                        .background(Brand.danger.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Brand.danger.opacity(0.3)))
                }
                switch tab {
                case .summary: summary
                case .envs: EnvironmentsView(store: store, project: project)
                case .processes: processes
                case .logs: logs
                case .environment: environment
                }
            }
            .padding(28)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Brand.background)
        .toolbar {
            ToolbarItem(placement: .principal) {
                // Procesos and Registros only exist for a site that runs processes.
                Picker(L("site.tabs"), selection: $tab) {
                    ForEach(Tab.allCases.filter { project.processes.isEmpty ? ![.processes, .logs].contains($0) : true }) { Text(L("site.tab.\($0.rawValue)")).tag($0) }
                }
                .pickerStyle(.segmented).fixedSize().accessibilityIdentifier("site.tabs")
            }
        }
        .sheet(isPresented: $editing) { SiteEditorSheet(store: store, project: project, notes: [], isNew: false).themedSheet() }
        .confirmationDialog(L("site.deleteConfirm"), isPresented: $confirmDelete) {
            Button(L("site.delete"), role: .destructive) { Task { await store.delete(project) } }
        } message: { Text(L("site.deleteDetail")) }
        .onAppear { logProcess = logProcess ?? project.processes.first(where: \.autostart).map { "\(project.id).\($0.name)" } }
        .task(id: project.id) { await store.loadWorktrees(project.id) }
    }

    private var hero: some View {
        let phase = store.sitePhase(project)
        return ZStack(alignment: .bottomLeading) {
            SitePreview(project: project, previews: previews, height: 300, fit: true)
            LinearGradient(colors: [.clear, .clear, project.tech.brand.opacity(0.45), .black.opacity(0.8)], startPoint: .top, endPoint: .bottom)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            HStack(alignment: .bottom, spacing: 14) {
                TechLogo(tech: project.tech, size: 52).background(.white.opacity(0.9), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text(project.title).font(.system(size: 28, weight: .bold, design: .rounded)).foregroundStyle(.white)
                    HStack(spacing: 8) {
                        Toggle("", isOn: Binding(get: { project.enabled }, set: { on in Task { await store.setSite(project, enabled: on) } }))
                            .toggleStyle(.switch).labelsHidden().accessibilityLabel(L("site.power")).accessibilityIdentifier("site.power")
                        StatusRing(phase: phase, size: 11)
                        Text(project.enabled ? L("state.\(phase.rawValue)") : L("site.off")).font(.uiCallout.weight(.medium)).foregroundStyle(.white.opacity(0.9))
                        if let env = store.activeEnvironment(project.id) {
                            Button { tab = .envs } label: { EnvChip(env: env).background(.black.opacity(0.35), in: Capsule()) }
                                .buttonStyle(.plain).accessibilityIdentifier("site.envChip")
                        }
                    }
                }
                Spacer()
                HStack(spacing: 8) {
                    HeroButton(symbol: "safari", title: L("site.browser")) { if let url = project.url { NSWorkspace.shared.open(url) } }
                    HeroButton(symbol: "chevron.left.forwardslash.chevron.right", title: L("site.editor")) { Editor.open(project.path) }
                    HeroButton(symbol: "terminal", title: L("site.terminal")) { Editor.terminal(project.path) }
                    if ButakeGit.installed && store.git[project.id] != nil {
                        HeroButton(symbol: "arrow.triangle.branch", title: L("git.open")) { ButakeGit.open(project.path) }.accessibilityIdentifier("site.openGit")
                    }
                    HeroButton(symbol: "arrow.clockwise", title: L("site.refreshPreview")) { previews.refresh(project) }
                }
            }
            .padding(20)
        }
        .frame(height: 300)
        .shadow(color: .black.opacity(0.18), radius: 16, y: 6)
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 18) {
            CardSection(title: L("site.general")) {
                InfoRow(symbol: "link", title: L("site.address"), value: project.url?.absoluteString ?? "—")
                Divider()
                InfoRow(symbol: "folder", title: L("site.folder"), value: project.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                Divider()
                InfoRow(symbol: "doc.richtext", title: L("site.docroot"), value: project.docroot)
            }
            if let info = store.git[project.id] { gitCard(info) }
            CardSection(title: L("site.services")) {
                let techs = [project.php.map { ("php", $0) }, project.node.map { ("node", $0) }].compactMap { $0 }
                ForEach(Array(techs.enumerated()), id: \.offset) { index, item in
                    if index > 0 { Divider() }
                    TechRow(tech: .of(item.0), value: item.1) { store.route = .language(item.0) }
                }
                ForEach(project.services, id: \.self) { service in
                    Divider()
                    TechRow(tech: .of(service), value: store.engineVersion(service) ?? L("panel.notInstalled")) { store.route = .service(Route.category(of: service)) }
                }
            }
            HStack {
                Button { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: project.path) } label: { Label(L("site.finder"), systemImage: "folder") }
                Spacer()
                Button(role: .destructive) { confirmDelete = true } label: { Label(L("site.delete"), systemImage: "trash") }.accessibilityIdentifier("site.delete")
            }
        }
    }

    /// Repository of the site: branch, pending work, and its worktrees, each servable as its own site.
    private func gitCard(_ info: GitInfo) -> some View {
        CardBlock(title: "Git", symbol: "arrow.triangle.branch") {
            if ButakeGit.installed {
                Button { ButakeGit.open(project.path) } label: { Label(L("git.open"), systemImage: "arrow.up.forward.app") }.controlSize(.small)
            }
        } content: {
            InfoRow(symbol: "arrow.triangle.branch", title: L("git.branch"), value: info.branch.isEmpty ? L("git.detached") : info.branch)
            Divider()
            InfoRow(symbol: "pencil.line", title: L("git.changes"), value: info.changes == 0 ? L("git.clean") : String(format: L("git.changesCount"), info.changes))
            if info.ahead > 0 || info.behind > 0 {
                Divider()
                InfoRow(symbol: "arrow.up.arrow.down", title: L("git.remote"), value: String(format: L("git.aheadBehind"), info.ahead, info.behind))
            }
            let worktrees = store.worktrees[project.id] ?? []
            ForEach(worktrees) { worktree in
                Divider()
                HStack(spacing: 10) {
                    Image(systemName: "square.split.2x1").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(worktree.branch)
                        Text(worktree.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).font(.uiCaption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    if let site = worktree.site {
                        Button(L("worktree.openSite")) { store.openSite(site) }.controlSize(.small)
                    } else {
                        Button { Task { await store.serveWorktree(project, worktree) } } label: { Label(L("worktree.serve"), systemImage: "globe") }
                            .controlSize(.small).disabled(store.busy != nil)
                            .help(String(format: L("worktree.serveHelp"), worktree.branch))
                    }
                }
            }
        }
    }

    private var processes: some View {
        CardSection(title: L("site.processes"), trailing: String(format: L("site.processesRunning"), store.runningProcesses(project), project.processes.count)) {
            if project.processes.isEmpty { Text(L("site.noProcesses")).foregroundStyle(.secondary) }
            ForEach(Array(project.processes.enumerated()), id: \.element.id) { index, process in
                if index > 0 { Divider() }
                ProcessRow(store: store, id: "\(project.id).\(process.name)", process: process) { id in logProcess = id; tab = .logs }
            }
        }
    }

    private var logs: some View {
        VStack(alignment: .leading, spacing: 12) {
            if project.processes.isEmpty {
                Text(L("site.noProcesses")).foregroundStyle(.secondary)
            } else {
                Picker(L("process.logs"), selection: Binding(get: { logProcess ?? "" }, set: { logProcess = $0 })) {
                    ForEach(project.processes) { Text($0.name).tag("\(project.id).\($0.name)") }
                }
                .pickerStyle(.menu).fixedSize()
                if let id = logProcess { LiveLog(store: store, id: id).id(id) }
            }
        }
    }

    private var environment: some View {
        VStack(alignment: .leading, spacing: 18) {
            CardSection(title: L("site.environment")) {
                SettingRow(title: "PHP") {
                    Picker("", selection: Binding(get: { project.php ?? "" }, set: { value in save { $0.runtime["php"] = value.isEmpty ? nil : value } })) {
                        ForEach(store.phpRuntimes.filter(\.verified).map(\.series), id: \.self) { Text($0).tag($0) }
                    }.labelsHidden().frame(width: 140)
                }
                Divider()
                SettingRow(title: "Node") {
                    Picker("", selection: Binding(get: { project.node ?? "" }, set: { value in save { $0.runtime["node"] = value.isEmpty ? nil : value } })) {
                        Text(L("value.none")).tag("")
                        ForEach(Array(Set((store.installedTools["node"] ?? []).map { String($0.version.split(separator: ".").first ?? "") })).sorted(), id: \.self) { Text($0).tag($0) }
                    }.labelsHidden().frame(width: 140)
                }
                Divider()
                SettingRow(title: "HTTPS") {
                    Toggle("", isOn: Binding(get: { project.https }, set: { on in save { $0.https = on } })).toggleStyle(.switch).labelsHidden()
                }
            }
            Button { editing = true } label: { Label(L("site.editMore"), systemImage: "slider.horizontal.3") }
                .accessibilityIdentifier("site.editMore")
        }
    }

    func save(_ change: (inout Project) -> Void) {
        var copy = project
        change(&copy)
        guard copy != project else { return }
        Task { _ = await store.save(copy) }
    }
}

/// After a branch switch: what the site needs to catch up (dependencies, migrations), one click each.
private struct BranchNotice: View {
    let store: StackStore
    let project: Project
    let changes: BranchChanges
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            IconTile(symbol: "arrow.triangle.branch", tint: Brand.info, size: 32)
            VStack(alignment: .leading, spacing: 8) {
                Text(String(format: L("branch.changed"), store.git[project.id]?.branch ?? "")).font(.ui(size: 13, weight: .semibold))
                Text([changes.composer ? L("branch.composer") : nil, changes.npm ? L("branch.npm") : nil,
                      changes.migrations > 0 ? String(format: L("branch.migrations"), changes.migrations) : nil].compactMap { $0 }.joined(separator: " · "))
                    .font(.uiCaption).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    if changes.composer { task("composer", "shippingbox") }
                    if changes.npm { task("npm", "cube") }
                    if changes.migrations > 0 { task("migrate", "cylinder.split.1x2") }
                }
            }
            Spacer()
            Button { withAnimation(.snappy) { store.branchNotices[project.id] = nil } } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless).help(L("action.close")).accessibilityIdentifier("branch.dismiss")
        }
        .padding(14)
        .background(Brand.info.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Brand.info.opacity(0.3)))
        .transition(.move(edge: .top).combined(with: .opacity))
    }
    private func task(_ name: String, _ symbol: String) -> some View {
        Button {
            Task { await store.runSiteTask(project, name) }
        } label: {
            if store.runningTask == "\(project.id).\(name)" { ProgressView().controlSize(.mini) }
            Label(L("task.\(name)"), systemImage: symbol)
        }
        .controlSize(.small).disabled(store.runningTask != nil)
        .accessibilityIdentifier("branch.task.\(name)")
    }
}

private struct HeroButton: View {
    let symbol: String
    let title: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 15, weight: .semibold)).frame(width: 36, height: 36)
        }
        .buttonStyle(.plain).foregroundStyle(.white)
        .glassCard(radius: 18)
        .help(title).accessibilityLabel(title)
    }
}

/// Live log of one process, following the end.
struct LiveLog: View {
    @Bindable var store: StackStore
    let id: String
    @State private var filter = ""
    var lines: [String] { (store.logs[id] ?? []).filter { filter.isEmpty || $0.localizedCaseInsensitiveContains(filter) } }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(L("logs.filter"), text: $filter).textFieldStyle(.plain)
                Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string) } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless).help(L("logs.copy"))
            }
            .padding(10)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                            Text(line).font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled).id(index)
                        }
                    }
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: lines.count) { _, count in proxy.scrollTo(count - 1, anchor: .bottom) }
            }
            .frame(minHeight: 420)
        }
        .glassCard(radius: 14)
        .task {
            while !Task.isCancelled {
                await store.loadLogs(id)
                try? await Task.sleep(for: .seconds(1.5))
            }
        }
    }
}
