import AppKit
import SwiftUI

/// Resumen of a project: where it answers and lives, what it runs on and uses, sharing and Git.
/// Read-only; what can be changed is in «Ajustes del proyecto…».
struct ProjectSummary: View {
    @Bindable var store: StackStore
    let project: Project
    /// Opens Registros on a command's log (a project without a server).
    var showLog: (String) -> Void = { _ in }

    var runtimes: [(key: String, version: String)] {
        ["php", "node", "jdk", "python"].compactMap { key in project.runtime[key].map { (key, $0) } }
    }

    var body: some View {
        Form {
            Section {
                if project.isServed {
                    LabeledContent(L("project.state")) {
                        let phase = store.sitePhase(project)
                        HStack(spacing: 6) {
                            StatusRing(phase: phase, size: 10).accessibilityHidden(true)
                            Text(project.enabled ? L("state.\(phase.rawValue)") : L("site.off"))
                        }
                    }
                } else {
                    // What it is: built with what, and that Stack does not serve it.
                    LabeledContent(L("common.type")) {
                        Text(project.technology.map { "\(Tech.of($0).title) · \(L("kind.unserved"))" } ?? L("kind.unserved"))
                    }
                    Text(L("unserved.detail")).font(.uiCaption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let url = project.url {
                    InfoRow(title: L("common.address"), value: url.absoluteString, copyID: "project.copyAddress", link: url, linkID: "project.address")
                }
                FolderRow(path: project.path)
                if project.isServed {
                    LabeledContent(L("site.docroot")) { Text(project.docroot).textSelection(.enabled) }
                }
                if let upstream = project.upstream {
                    LabeledContent(L("site.upstream")) { Text(verbatim: "127.0.0.1:\(upstream)").monospacedDigit().textSelection(.enabled) }
                }
                if let env = store.activeEnvironment(project.id) {
                    LabeledContent(L("env.activeLabel")) { Chip(env: env) }
                }
            }
            if !project.isServed {
                ProjectCommandsSection(store: store, project: project, showLog: showLog)
            }
            if !runtimes.isEmpty {
                Section(L("site.environment")) {
                    ForEach(runtimes, id: \.key) { item in
                        TechRow(tech: .of(item.key), value: item.version) { store.route = .language(item.key == "jdk" ? "java" : item.key) }
                            .accessibilityIdentifier("project.language.\(item.key)")
                    }
                }
            }
            if !project.services.isEmpty {
                Section(L("site.services")) {
                    ForEach(project.services, id: \.self) { service in
                        TechRow(tech: .of(service), value: store.engineVersion(service) ?? L("panel.notInstalled")) {
                            store.route = .service(Route.category(of: service))
                        }
                        .accessibilityIdentifier("project.service.\(service)")
                    }
                }
            }
            ProjectExtensionsSection(store: store, project: project)
            ProjectCredentialsSection(store: store, project: project)
            if store.pluginEnabled("gcp") { GCPProjectSection(project: project) }
            if project.isServed { ShareSection(store: store, project: project) }
            if let info = store.git[project.id] {
                GitSection(store: store, project: project, info: info)
            } else if store.pluginEnabled("git") && !project.isMissing {
                GitCreateHereSection(project: project)
            }
        }
        .formStyle(.grouped).themedScroll()
    }
}

/// The project's folder, cut in the middle when it is long, with «Mostrar en Finder» in the row.
private struct FolderRow: View {
    let path: String
    var body: some View {
        LabeledContent(L("common.folder")) {
            HStack(spacing: 8) {
                Text(path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    .help(path)
                Button { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path) } label: {
                    Label(L("menu.showInFinder"), systemImage: Symbols.folder).labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless).help(L("menu.showInFinder")).accessibilityIdentifier("project.showInFinder")
            }
        }
    }
}

/// Repository of the project: branch, pending work, and its worktrees, each servable as its own project.
private struct GitSection: View {
    @Bindable var store: StackStore
    let project: Project
    let info: GitInfo
    var body: some View {
        Section {
            LabeledContent(L("git.branch"), value: info.branch.isEmpty ? L("git.detached") : info.branch)
            LabeledContent(L("git.changes"), value: info.changes == 0 ? L("git.clean") : String(format: L("git.changesCount"), info.changes))
            if info.ahead > 0 || info.behind > 0 {
                LabeledContent(L("git.remote"), value: String(format: L("git.aheadBehind"), info.ahead, info.behind))
            }
            if store.pluginEnabled("git") { GitProjectProblemsRow(path: project.path) }
            ForEach(store.worktrees[project.id] ?? []) { worktree in
                LabeledContent {
                    if let site = worktree.site {
                        Button { store.openSite(site) } label: { Label(L("worktree.openSite"), systemImage: Symbols.forward) }
                            .buttonStyle(.bordered).accessibilityIdentifier("project.worktree.open.\(site)")
                    } else {
                        Button { Task { await store.serveWorktree(project, worktree) } } label: { Label(L("worktree.serve"), systemImage: Symbols.address) }
                            .buttonStyle(.bordered).disabled(store.busy != nil)
                            .help(String(format: L("worktree.serveHelp"), worktree.branch))
                            .accessibilityIdentifier("project.worktree.serve.\(worktree.branch)")
                    }
                } label: {
                    Text(worktree.branch)
                    Text(worktree.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).lineLimit(1).truncationMode(.middle).help(worktree.path)
                }
            }
        } header: {
            HStack {
                Text(verbatim: "Git")
                Spacer()
                // The Git tool, only while it is on; the rows above are the base's and always show.
                if store.pluginEnabled("git") {
                    Button { GitTool.shared.show(project.path) } label: { Label(L("git.openHere"), systemImage: Symbols.forward) }
                        .buttonStyle(.bordered).controlSize(.small).accessibilityIdentifier("project.openGitTool")
                }
            }
        }
    }
}
