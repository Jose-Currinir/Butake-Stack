import AppKit
import SwiftUI

/// The same actions wherever a project appears (cards, sidebar, panel): one menu, one order.
struct ProjectMenuItems: View {
    let store: StackStore
    let project: Project
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        if project.isMissing {
            Button { openWindow(id: "main"); store.findFolder(project) } label: { Label(L("missing.find"), systemImage: Symbols.findFolder) }
        } else if project.isServed {
            Button { Task { await store.setSite(project, enabled: !project.enabled) } } label: {
                Label(project.enabled ? L("palette.stop") : L("palette.start"), systemImage: project.enabled ? Symbols.stop : Symbols.start)
            }
        }
        Button { store.toggleFavorite(project.id) } label: {
            Label(store.isFavorite(project.id) ? L("favorites.remove") : L("favorites.add"), systemImage: store.isFavorite(project.id) ? "star.slash" : "star")
        }
        Divider()
        let environments = store.envs[project.id]?.site.environments.filter { $0.kind != .production } ?? []
        if !environments.isEmpty {
            Menu {
                ForEach(environments) { env in
                    Button { Task { await store.activateEnvironment(project, env) } } label: {
                        Label(env.title, systemImage: store.envs[project.id]?.site.active == env.id ? "checkmark" : env.kind.symbol)
                    }
                }
            } label: { Label(L("env.switch"), systemImage: Symbols.switchEnvironment) }
        }
        Menu {
            let current = store.group(of: project.id)?.id
            ForEach(store.groups) { group in
                Button { store.move(project.id, to: group.id) } label: {
                    Label(group.name, systemImage: current == group.id ? "checkmark" : Symbols.folder)
                }
                .disabled(current == group.id)
            }
            if !store.groups.isEmpty { Divider() }
            Button { store.groupNaming = .new(sites: [project.id]) } label: { Label(L("groups.newWithSite"), systemImage: Symbols.newFolder) }
                .accessibilityIdentifier("project.menu.newFolder")
            if current != nil {
                Button { store.move(project.id, to: nil) } label: { Label(L("groups.removeFrom"), systemImage: Symbols.removeFromFolder) }
            }
        } label: { Label(L("groups.moveTo"), systemImage: Symbols.folder) }
        Divider()
        // Without its folder there is nothing to open.
        Group {
            if project.isServed {
                Button { if let url = project.url { NSWorkspace.shared.open(url) } } label: { Label(L("menu.openInBrowser"), systemImage: Symbols.openInBrowser) }
            }
            Button { Editor.open(project.path) } label: { Label(L("project.openEditor"), systemImage: Symbols.editor) }
            if store.pluginEnabled("ssh-terminal") {
                Menu { ProjectConsoleItems(project: project) } label: { Label(L("ssh.local.openHere"), systemImage: Symbols.terminal) }
            }
            Button { Editor.terminal(project.path) } label: { Label(L("project.openTerminal"), systemImage: Symbols.terminal) }
            // Only with the Git tool on: off, the project offers nothing of Git beyond its page's rows.
            if store.pluginEnabled("git") && store.git[project.id] != nil {
                Button { openWindow(id: "main"); GitTool.shared.show(project.path) } label: { Label(L("git.openHere"), systemImage: Symbols.git) }
            }
            Button { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: project.path) } label: { Label(L("menu.showInFinder"), systemImage: Symbols.folder) }
        }
        .disabled(project.isMissing)
        Divider()
        // Both open in the main window, also when the menu bar panel asks (P-41).
        Button { openWindow(id: "main"); store.renaming = RenameRequest(project: project) } label: {
            Label(L("menu.renameProject"), systemImage: Symbols.renameProject)
        }
        .accessibilityIdentifier("project.menu.rename")
        Button { openWindow(id: "main"); store.changeFolder(project) } label: {
            Label(L("menu.changeFolder"), systemImage: Symbols.changeFolder)
        }
        .accessibilityIdentifier("project.menu.changeFolder")
        Divider()
        // The confirmation lives in the main window (RootView), also when the menu bar panel asks.
        Button(role: .destructive) {
            openWindow(id: "main")
            store.removing = project
        } label: { Label(L("menu.removeProject"), systemImage: Symbols.remove) }
    }
}
