import SwiftUI

/// One action of a folder's menu: what the context menu draws and what QA lists as text.
struct GroupAction: Identifiable {
    let id: String
    let title: String
    let symbol: String
    var destructive = false
    var enabled = true
    let run: @MainActor () -> Void
}

extension StackStore {
    /// The actions of a folder or a project of several parts, in sections: start and stop, what it
    /// is (folder or project, its repositories), and its name or its removal.
    func groupActions(_ group: ProjectGroup) -> [[GroupAction]] {
        let members = projects(in: group)
        var kind: [GroupAction] = []
        if group.isProject {
            kind.append(GroupAction(id: "open", title: L("composite.open"), symbol: Symbols.compositeProject) { self.openComposite(group.id) })
            if pluginEnabled("git") {
                kind.append(GroupAction(id: "addRepository", title: L("composite.git.add"), symbol: Symbols.add) { self.chooseRepository(for: group.id) })
            }
            kind.append(GroupAction(id: "toFolder", title: L("composite.toFolder"), symbol: Symbols.folder) { self.setKind(group.id, .folder) })
        } else {
            kind.append(GroupAction(id: "toProject", title: L("composite.toProject"), symbol: Symbols.compositeProject) { self.setKind(group.id, .project) })
        }
        return [
            [GroupAction(id: "startAll", title: L(group.isProject ? "composite.startAll" : "groups.startAll"), symbol: Symbols.start,
                         enabled: !members.allSatisfy(\.enabled) && compositeWorking == nil) { Task { await self.startAll(group) } },
             GroupAction(id: "stopAll", title: L(group.isProject ? "composite.stopAll" : "groups.stopAll"), symbol: Symbols.stop,
                         enabled: members.contains(where: \.enabled) && compositeWorking == nil) { Task { await self.stopAll(group) } }],
            kind,
            [GroupAction(id: "rename", title: L("groups.rename"), symbol: Symbols.edit) { self.groupNaming = .rename(group.id) },
             GroupAction(id: "delete", title: L(group.isProject ? "composite.delete" : "groups.delete"), symbol: Symbols.delete,
                         destructive: true) { self.deleteGroup(group.id) }],
        ]
    }
}

/// The context menu of a folder in the sidebar (and Inicio).
struct GroupMenuItems: View {
    let store: StackStore
    let group: ProjectGroup
    var body: some View {
        let sections = store.groupActions(group)
        ForEach(Array(sections.enumerated()), id: \.offset) { index, actions in
            if index > 0 { Divider() }
            ForEach(actions) { action in
                Button(role: action.destructive ? .destructive : nil) { action.run() } label: { Label(action.title, systemImage: action.symbol) }
                    .disabled(!action.enabled)
                    .help(action.id == "delete" && group.isProject ? L("composite.deleteHelp") : "")
                    .accessibilityIdentifier("sidebar.group.\(action.id).\(group.id)")
            }
        }
    }
}
