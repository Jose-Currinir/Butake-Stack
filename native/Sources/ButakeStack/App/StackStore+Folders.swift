import Foundation

/// Folders of projects as the sidebar and Inicio show them: open or closed (one state for both),
/// and read again when the projects change outside the app.
extension StackStore {
    /// «Sin carpeta» in Inicio: a name no folder can take (folder ids have no colon).
    static let looseFolder = ":loose"

    func folderOpen(_ id: String) -> Bool { !closedFolders.contains(id) }
    /// No animation of its own: the sidebar's outline animates its rows, and a SwiftUI animation on
    /// top left the selected row drawn twice.
    func setFolder(_ id: String, open: Bool) {
        if open { closedFolders.remove(id) } else { closedFolders.insert(id) }
    }
    /// The folders Inicio shows (those with projects) and «Sin carpeta» when it has any.
    var shownFolders: [String] {
        groups.filter { !projects(in: $0).isEmpty }.map(\.id) + (ungroupedProjects.isEmpty ? [] : [Self.looseFolder])
    }
    /// Visualización › Plegar todas las carpetas / Desplegar todas las carpetas, and Inicio's «⋯».
    func setAllFolders(open: Bool) {
        let all = Set(groups.map(\.id) + [Self.looseFolder])
        if open { closedFolders.subtract(all) } else { closedFolders.formUnion(all) }
    }

    /// Projects and folders as the engine has them now. Only what changed is set, so the views
    /// redraw nothing while nothing changed; folders are left alone while a save of them is pending.
    func refreshProjects() async {
        if let value: [Project] = try? await call(["method": "listProjects"]), value != projects { projects = value }
        guard !groupsSaving, !groupsDirty else { return }
        if let value: [ProjectGroup] = try? await call(["method": "siteGroups"]), !groupsSaving, !groupsDirty, value != groups { groups = value }
    }
}
