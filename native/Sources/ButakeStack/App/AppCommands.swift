import AppKit
import SwiftUI

/// What the menus act on: the project shown in the focused window.
extension FocusedValues {
    @Entry var selectedProject: Project?
    /// The project selected in the sidebar while the sidebar has the keyboard (not its search field).
    /// ⌘⌫ removes it, or the project whose page is shown (`ProjectRemoval`); in any text it stays
    /// "delete to the start of the line".
    @Entry var sidebarProject: Project?
    @Entry var sidebarSearch: SidebarSearchFocus?
}

/// Who «Quitar proyecto…» (⌘⌫) acts on. A pure rule, so it can be tested without a window.
enum ProjectRemoval {
    enum Focus: Equatable { case textEditor, other }

    /// A field, a code or SQL editor, a terminal: anything that takes typed text.
    @MainActor static func focus(of responder: NSResponder?) -> Focus {
        guard let responder else { return .other }
        return responder is NSText || responder is NSTextInputClient ? .textEditor : .other
    }

    /// The project to remove: none while typing; else the one selected in the sidebar's list (it has
    /// the keyboard) or, failing that, the one whose page is shown.
    static func target<P>(focus: Focus, listed: P?, shown: P?) -> P? {
        focus == .textEditor ? nil : listed ?? shown
    }
}

/// The menu bar, ordered like any Mac app: Archivo, Edición, Visualización, Ir, Proyecto, Ventana
/// and Ayuda. Standard items (Ajustes…, Edición, Ventana, Cerrar) come from the system.
struct AppCommands: Commands {
    let store: StackStore
    let text: TextScale
    /// Read in the app's body, which follows the store; the commands themselves are not redrawn by it.
    let hasProjects: Bool
    /// The first row of Herramientas and of Nube (none while no cloud account is on).
    let toolsRoute: Route
    let cloudRoute: Route?
    /// The tools that are on, in the sidebar's order (each has its own shortcut in Ir › Ir a herramienta).
    let toolRows: [String]
    /// Atrás and Adelante follow the pages visited (RouteHistory).
    let canGoBack: Bool
    let canGoForward: Bool
    /// The Git menu exists only while the tool is on.
    let gitEnabled: Bool
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.selectedProject) private var project
    @FocusedValue(\.sidebarProject) private var listed
    @FocusedValue(\.sidebarSearch) private var search
    @FocusedValue(\.textFinder) private var finder
    @FocusedValue(\.projectSettings) private var projectSettings
    @FocusedValue(\.projectTabs) private var projectTabs

    static let website = URL(string: "https://jose-currinir.github.io/Butake-Stack/")!

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button(L("menu.checkUpdates")) { Task { await UpdateService.shared.check(userInitiated: true) } }
        }
        CommandGroup(replacing: .newItem) {
            Button(L("menu.newProject")) { inWindow { store.showNewProject = true } }.keyboardShortcut("n")
            Button(L("menu.addExisting")) { inWindow { store.chooseFolder() } }.keyboardShortcut("n", modifiers: [.command, .option])
            Button(L("menu.importFolder")) { inWindow { store.chooseFolder(scan: true) } }
            Button(L("menu.cloneRepository")) { inWindow { store.showClone = true } }
            Button(L("menu.newFolder")) { inWindow { store.groupNaming = .new(sites: []) } }.keyboardShortcut("n", modifiers: [.command, .shift])
            Divider()
            Button(L("backup.export")) { Task { await store.exportConfiguration() } }.disabled(store.busy != nil)
            Button(L("backup.restore")) {
                Task {
                    guard let request = await store.planRestore() else { return }
                    inWindow { store.restoreRequest = request }
                }
            }
            .disabled(store.busy != nil)
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            // With no search of its own on the page, ⌘F goes to the sidebar's: the menu says so.
            Button(finder == nil && search != nil ? L("menu.findProject") : L("menu.find")) { find() }
                .keyboardShortcut("f").disabled(search == nil && finder == nil)
        }
        SidebarCommands()
        CommandGroup(after: .toolbar) {
            Button(L("menu.reload")) { Task { await reload() } }.keyboardShortcut("r")
            Divider()
            Button(L("menu.textBigger")) { text.increase() }.keyboardShortcut("+").disabled(!text.canIncrease)
            Button(L("menu.textSmaller")) { text.decrease() }.keyboardShortcut("-").disabled(!text.canDecrease)
            Button(L("menu.textReset")) { text.reset() }.keyboardShortcut("0").disabled(text.factor == 1)
            Divider()
            // The folders of the sidebar and of Inicio (one state for both).
            FolderMenuItems(store: store)
        }
        CommandMenu(L("menu.go")) {
            Button(L("menu.back")) { inWindow { store.goBack() } }.keyboardShortcut("[").disabled(!canGoBack)
            Button(L("menu.forward")) { inWindow { store.goForward() } }.keyboardShortcut("]").disabled(!canGoForward)
            Divider()
            Button(L("route.home")) { go(.home) }.keyboardShortcut("1")
            Button(L("route.sites")) { if let id = store.selectedProject?.id ?? store.projects.first?.id { inWindow { store.openSite(id) } } }
                .keyboardShortcut("2").disabled(!hasProjects)
            // In the sidebar's order; each shortcut keeps the page it always opened (P-37).
            Button(L("sidebar.tools")) { go(toolsRoute) }.keyboardShortcut("6")
            Button(L("sidebar.cloud")) { if let cloudRoute { go(cloudRoute) } }.keyboardShortcut("7").disabled(cloudRoute == nil)
            Section(L("sidebar.components")) {
                // Each row of Componentes opens on its last category seen, like its row.
                Button(L("sidebar.services")) { go(Component.services.lastRoute()) }.keyboardShortcut("3")
                Button(L("sidebar.languages")) { go(Component.languages.lastRoute()) }.keyboardShortcut("4")
                Button(L("route.utilities")) { go(Component.utilities.lastRoute()) }.keyboardShortcut("5")
            }
            // ⌃⌘1…9: each tool that is on, in the sidebar's order.
            Menu(L("menu.goTool")) {
                ForEach(Array(toolRows.prefix(9).enumerated()), id: \.element) { index, id in
                    Button(Route.tool(id).title) { go(.tool(id)) }
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [.control, .command])
                }
            }
            .disabled(toolRows.isEmpty)
            Divider()
            Button(L("menu.quickOpen")) { inWindow { store.showPalette = true } }.keyboardShortcut("o", modifiers: [.command, .shift])
        }
        if gitEnabled {
            CommandMenu(L("menu.git")) { GitMenuItems() }
        }
        CommandMenu(L("menu.project")) {
            Button(project?.enabled == true ? L("menu.stop") : L("menu.start")) {
                if let project { Task { await store.setSite(project, enabled: !project.enabled) } }
            }
            .keyboardShortcut("p", modifiers: [.control, .command])
            .disabled(project == nil || project?.isMissing == true || project?.isServed == false)
            Button(L("menu.openInBrowser")) { if let url = project?.url { NSWorkspace.shared.open(url) } }
                .keyboardShortcut("b", modifiers: [.command, .option])
                .disabled(project?.enabled != true || project?.url == nil)
            Button(L("menu.showInFinder")) { if let path = project?.path { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path) } }
                .keyboardShortcut("r", modifiers: [.command, .shift]).disabled(project == nil || project?.isMissing == true)
            Button(L("project.settings")) { projectSettings?.open() }.keyboardShortcut("i").disabled(projectSettings == nil)
            // ⌃⌥1…4, only on a project's page (⌘⌥ + number is Git's).
            Menu(L("menu.projectTabs")) {
                ForEach(ProjectPage.Tab.allCases) { tab in
                    Button(L("site.tab.\(tab.rawValue)")) { projectTabs?.select(tab) }
                        .keyboardShortcut(KeyEquivalent(tab.shortcutKey), modifiers: [.control, .option])
                        .disabled(projectTabs?.available.contains(tab) != true)
                }
            }
            .disabled(projectTabs == nil)
            Button(L("menu.renameProject")) { if let project { inWindow { store.renaming = RenameRequest(project: project) } } }
                .disabled(project == nil)
            Button(L("menu.changeFolder")) { if let project { inWindow { store.changeFolder(project) } } }
                .disabled(project == nil)
            Divider()
            Button(L("menu.removeProject")) { removeProject() }
                .keyboardShortcut(.delete).disabled(listed == nil && project == nil)
        }
        CommandGroup(replacing: .help) {
            Button(L("menu.setup")) { inWindow { store.showSetup = true } }
            Button(L("menu.website")) { NSWorkspace.shared.open(Self.website) }
            if gitEnabled {
                Divider()
                Button(L("git.dictionary.titleEllipsis")) { GitDictionaryLink.open(openWindow) }
            }
        }
    }

    /// ⌘⌫ removes the project of the list or of the page shown, unless the keyboard is in a text
    /// editor: there the key goes back to it, which deletes to the start of the line.
    private func removeProject() {
        let responder = NSApp.keyWindow?.firstResponder
        let byKey = NSApp.currentEvent?.type == .keyDown
        let focus = ProjectRemoval.focus(of: responder)
        if let target = ProjectRemoval.target(focus: byKey ? focus : .other, listed: listed, shown: project) {
            store.removing = target
        } else if byKey, let responder, let event = NSApp.currentEvent {
            responder.keyDown(with: event)
        }
    }

    /// ⌘F: the find bar of the page's editor, or of the code editor that has the keyboard; else the
    /// sidebar's search.
    private func find() {
        if let finder { finder.show() }
        else if let view = NSApp.keyWindow?.firstResponder as? NSTextView, view.usesFindBar { CodeEditor.showFindBar(view) }
        else { search?.focus() }
    }

    /// Navigation and sheets happen in the main window, opened (or brought forward) first.
    private func inWindow(_ action: () -> Void) {
        openWindow(id: "main")
        action()
    }
    private func go(_ route: Route) { inWindow { store.route = route } }

    private func reload() async {
        await store.refresh()
        await store.refreshRuntimes()
        await store.refreshHealth()
        await store.refreshGit()
    }
}
