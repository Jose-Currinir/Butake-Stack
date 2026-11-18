import SwiftUI

extension FocusedValues {
    /// The Git tool on screen with an open repository: the Git menu acts on it.
    @Entry var gitCommands: GitCommands?
}

/// What the Git menu does in the window that shows the tool.
struct GitCommands {
    let tool: GitTool
}

/// The items of the Git menu (only while the tool is on): the tabs and the main actions, each with
/// its shortcut, the assistant in the repository's folder and the dictionary. The tabs use
/// ⌥⌘1…⌥⌘5: ⌘1…⌘6 go to the sections of the window (Ir).
struct GitMenuItems: View {
    @FocusedValue(\.gitCommands) private var commands
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ForEach(GitTab.allCases) { tab in
            Button(tab.title) { commands?.tool.tab = tab }.accessibilityIdentifier("git.menu.tab.\(tab.rawValue)")
                .shortcut(Shortcuts.gitTab(tab.shortcut, title: tab.title))
                .disabled(commands == nil)
        }
        Divider()
        let repository = commands?.tool.repository
        Button(repository?.syncState.title ?? L("git.sync.fetch")) { Task { await repository?.sync() } }.accessibilityIdentifier("git.menu.sync")
            .shortcut(Shortcuts.gitSync)
            .disabled(repository == nil || repository?.busy == true)
        Button(L("git.branch.newEllipsis")) { commands?.tool.creatingBranch = true }.accessibilityIdentifier("git.menu.newBranch")
            .shortcut(Shortcuts.gitNewBranch)
            .disabled(repository == nil || repository?.busy == true)
        GitAssistantMenu(directory: repository?.root)
        Divider()
        Button(L("git.dictionary.titleEllipsis")) { GitDictionaryLink.open(openWindow) }.accessibilityIdentifier("git.menu.dictionary")
            .shortcut(Shortcuts.gitDictionary)
    }
}

/// Opens the dictionary from a menu: the window on the Git tool, with the dictionary over it.
@MainActor enum GitDictionaryLink {
    static func open(_ openWindow: OpenWindowAction) {
        openWindow(id: "main")
        StackStore.shared.openTool("git")
        GitTool.shared.showingDictionary = true
    }
}
