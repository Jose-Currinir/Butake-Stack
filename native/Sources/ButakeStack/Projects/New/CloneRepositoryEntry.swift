import SwiftUI

/// «Clonar repositorio…» from anywhere (the «+» menu, Inicio, Archivo and ⌘K): the clone sheet of
/// the Git tool, unchanged. With Git off the sheet says so and turns it on with one button, then
/// shows the clone sheet; once the repository is cloned the window goes to it in the Git tool.
struct CloneRepositoryEntry: View {
    @Bindable var store: StackStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if store.pluginEnabled("git") {
                GitCloneSheet(tool: GitTool.shared)
                    .onChange(of: GitTool.shared.repository?.root) { _, root in
                        if root != nil { store.route = .tool("git") }
                    }
            } else {
                gitOff
            }
        }
        .task { if !store.pluginsLoaded { await store.loadPlugins() } }
    }

    private var gitOff: some View {
        SheetFrame(title: L("new.cloneGitOff"), symbol: Symbols.gitClone, detail: L("new.cloneGitOffDetail"), width: 480,
                   actionTitle: L("new.cloneTurnOn"), actionSymbol: Symbols.start, actionID: "new.cloneTurnOn",
                   canAct: store.busy == nil, cancelID: "clone.cancel") {
            if let git = store.plugins.first(where: { $0.id == "git" }) { await store.setPlugin(git, enabled: true) }
            return false
        } content: {
            EmptyView()
        }
    }
}
