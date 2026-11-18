import SwiftUI

/// One keyboard shortcut of the app: what it does (a `Localizable.strings` key), the menu or page
/// that owns it, and its chord. The menus, the palette and the «Atajos de teclado» sheet read it
/// from `Shortcuts`; a test fails when two shortcuts that can be active at once share a chord.
struct AppShortcut: Identifiable, Equatable {
    /// The menu (or page) that owns the shortcut. The global groups live in the menu bar; the others
    /// only act while their page is shown, so the same chord may serve in two of them.
    enum Group: String, CaseIterable {
        case app, file, edit, view, go, project, git, help, database, terminal, vault

        var title: String { L("shortcuts.group.\(rawValue)") }
        /// The menu bar is always there; a page's shortcuts only while that page is shown.
        var scope: String { [.database, .terminal, .vault].contains(self) ? rawValue : "global" }
    }

    let id: String
    let group: Group
    /// `Localizable.strings` key of the action; ignored when `label` is given (a tab, a tool).
    var titleKey = ""
    var label: String?
    let key: KeyEquivalent
    var modifiers: EventModifiers = .command

    var title: String { label ?? L(titleKey) }

    /// The chord as the menus draw it: ⌃⌥⇧⌘ and then the key.
    var display: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text + Self.glyph(key)
    }

    static func glyph(_ key: KeyEquivalent) -> String {
        switch key {
        case .return: "↩"
        case .delete: "⌫"
        case .tab: "⇥"
        case .escape: "⎋"
        case .upArrow: "↑"
        case .downArrow: "↓"
        case .leftArrow: "←"
        case .rightArrow: "→"
        case .space: "Space"
        default: String(key.character).localizedUppercase
        }
    }

    /// Two shortcuts that can be active together and press the same chord.
    func collides(with other: AppShortcut) -> Bool {
        id != other.id && key == other.key && modifiers == other.modifiers
            && (group.scope == "global" || other.group.scope == "global" || group.scope == other.group.scope)
    }
}

extension View {
    /// Binds the registry's chord, so a shortcut has one definition.
    func shortcut(_ shortcut: AppShortcut) -> some View {
        keyboardShortcut(shortcut.key, modifiers: shortcut.modifiers)
    }
}

/// The registry. Menu items read their chord from here (`.shortcut(Shortcuts.reload)`); the pages
/// keep their buttons where they are but are listed too, so the test and the sheet know them.
enum Shortcuts {
    // Aplicación
    static let settings = AppShortcut(id: "settings", group: .app, titleKey: "menu.settings", key: ",")
    // Archivo
    static let newProject = AppShortcut(id: "newProject", group: .file, titleKey: "menu.newProject", key: "n")
    static let addExisting = AppShortcut(id: "addExisting", group: .file, titleKey: "menu.addExisting", key: "n", modifiers: [.command, .option])
    static let newFolder = AppShortcut(id: "newFolder", group: .file, titleKey: "menu.newFolder", key: "n", modifiers: [.command, .shift])
    // Edición
    static let find = AppShortcut(id: "find", group: .edit, titleKey: "menu.find", key: "f")
    // Visualización
    static let reload = AppShortcut(id: "reload", group: .view, titleKey: "menu.reload", key: "r")
    static let textBigger = AppShortcut(id: "textBigger", group: .view, titleKey: "menu.textBigger", key: "+")
    static let textSmaller = AppShortcut(id: "textSmaller", group: .view, titleKey: "menu.textSmaller", key: "-")
    static let textReset = AppShortcut(id: "textReset", group: .view, titleKey: "menu.textReset", key: "0")
    // Ir
    static let back = AppShortcut(id: "back", group: .go, titleKey: "menu.back", key: "[")
    static let forward = AppShortcut(id: "forward", group: .go, titleKey: "menu.forward", key: "]")
    static let home = AppShortcut(id: "home", group: .go, titleKey: "route.home", key: "1")
    static let projects = AppShortcut(id: "projects", group: .go, titleKey: "route.sites", key: "2")
    static let services = AppShortcut(id: "services", group: .go, titleKey: "sidebar.services", key: "3")
    static let languages = AppShortcut(id: "languages", group: .go, titleKey: "sidebar.languages", key: "4")
    static let utilities = AppShortcut(id: "utilities", group: .go, titleKey: "route.utilities", key: "5")
    static let tools = AppShortcut(id: "tools", group: .go, titleKey: "sidebar.tools", key: "6")
    static let cloud = AppShortcut(id: "cloud", group: .go, titleKey: "sidebar.cloud", key: "7")
    static let quickOpen = AppShortcut(id: "quickOpen", group: .go, titleKey: "menu.quickOpen", key: "o", modifiers: [.command, .shift])
    /// Also opens the palette; bound apart from the menu (RootView).
    static let quickOpenAlt = AppShortcut(id: "quickOpenAlt", group: .go, titleKey: "menu.quickOpen", key: "k")
    /// ⌃⌘1…9: the n-th tool that is on.
    static func goTool(_ index: Int, title: String) -> AppShortcut {
        AppShortcut(id: "goTool.\(index)", group: .go, label: String(format: L("shortcuts.goTool"), title),
                    key: KeyEquivalent(Character("\(index)")), modifiers: [.control, .command])
    }
    // Proyecto
    static let startStop = AppShortcut(id: "startStop", group: .project, titleKey: "shortcuts.startStop", key: "p", modifiers: [.control, .command])
    static let openInBrowser = AppShortcut(id: "openInBrowser", group: .project, titleKey: "menu.openInBrowser", key: "b", modifiers: [.command, .option])
    static let showInFinder = AppShortcut(id: "showInFinder", group: .project, titleKey: "menu.showInFinder", key: "r", modifiers: [.command, .shift])
    static let projectSettings = AppShortcut(id: "projectSettings", group: .project, titleKey: "project.settings", key: "i")
    static let removeProject = AppShortcut(id: "removeProject", group: .project, titleKey: "menu.removeProject", key: .delete)
    /// ⌃⌥1…4: a tab of the project's page.
    static func projectTab(_ key: KeyEquivalent, title: String) -> AppShortcut {
        AppShortcut(id: "projectTab.\(key.character)", group: .project, label: title, key: key, modifiers: [.control, .option])
    }
    // Git
    static let gitSync = AppShortcut(id: "gitSync", group: .git, titleKey: "git.sync.fetch", key: "s", modifiers: [.command, .option])
    static let gitNewBranch = AppShortcut(id: "gitNewBranch", group: .git, titleKey: "git.branch.newEllipsis", key: "b", modifiers: [.command, .shift])
    static let gitDictionary = AppShortcut(id: "gitDictionary", group: .git, titleKey: "git.dictionary.titleEllipsis", key: "d", modifiers: [.command, .option])
    /// ⌥⌘1…5: a tab of the Git tool.
    static func gitTab(_ key: KeyEquivalent, title: String) -> AppShortcut {
        AppShortcut(id: "gitTab.\(key.character)", group: .git, label: title, key: key, modifiers: [.command, .option])
    }
    // Ayuda
    static let shortcutsSheet = AppShortcut(id: "shortcutsSheet", group: .help, titleKey: "menu.shortcuts", key: "/")
    // Bases de datos
    /// ⌘R belongs to Visualización › Recargar; the client's own reload took the same chord.
    static let dbReload = AppShortcut(id: "dbReload", group: .database, titleKey: "common.refresh", key: "r", modifiers: [.command, .option])
    static let dbRun = AppShortcut(id: "dbRun", group: .database, titleKey: "db.run", key: .return)
    static let dbFormat = AppShortcut(id: "dbFormat", group: .database, titleKey: "db.sql.format", key: "f", modifiers: [.command, .shift])
    static let dbNewTab = AppShortcut(id: "dbNewTab", group: .database, titleKey: "db.sql.newTab", key: "t")
    static let dbCloseTab = AppShortcut(id: "dbCloseTab", group: .database, titleKey: "db.sql.closeTab", key: "w")
    static let dbNextTab = AppShortcut(id: "dbNextTab", group: .database, titleKey: "db.sql.nextTab", key: .tab, modifiers: .control)
    static let dbPreviousTab = AppShortcut(id: "dbPreviousTab", group: .database, titleKey: "db.sql.previousTab", key: .tab, modifiers: [.control, .shift])
    // Terminal
    static let sshNewTab = AppShortcut(id: "sshNewTab", group: .terminal, titleKey: "ssh.tabs.new", key: "t")
    static let sshCloseTab = AppShortcut(id: "sshCloseTab", group: .terminal, titleKey: "ssh.terminal.closeTab", key: "w")
    static let sshNextTab = AppShortcut(id: "sshNextTab", group: .terminal, titleKey: "ssh.tabs.next", key: .tab, modifiers: .control)
    static let sshPreviousTab = AppShortcut(id: "sshPreviousTab", group: .terminal, titleKey: "ssh.tabs.previous", key: .tab, modifiers: [.control, .shift])
    static let sshSplitRight = AppShortcut(id: "sshSplitRight", group: .terminal, titleKey: "shortcuts.splitRight", key: "d")
    static let sshSplitDown = AppShortcut(id: "sshSplitDown", group: .terminal, titleKey: "shortcuts.splitDown", key: "d", modifiers: [.command, .shift])
    static let sshSearchHosts = AppShortcut(id: "sshSearchHosts", group: .terminal, titleKey: "ssh.searchHosts", key: "f", modifiers: [.command, .option])
    static let sshInspector = AppShortcut(id: "sshInspector", group: .terminal, titleKey: "ssh.inspector.toggle", key: "i", modifiers: [.command, .option])
    // Bóveda
    /// Esc, the Mac's way back out of a detail; ⌘[ is Ir › Atrás.
    static let vaultBack = AppShortcut(id: "vaultBack", group: .vault, titleKey: "menu.back", key: .escape, modifiers: [])
    static let vaultLock = AppShortcut(id: "vaultLock", group: .vault, titleKey: "vault.lock", key: "l", modifiers: [.command, .control])

    /// Every shortcut, in the order of the menus. The tabs and tools are listed with their
    /// positions; titles are read when called, so they follow the language.
    static var all: [AppShortcut] {
        var list = [settings, newProject, addExisting, newFolder, find, reload, textBigger, textSmaller, textReset,
                    back, forward, home, projects, services, languages, utilities, tools, cloud, quickOpen, quickOpenAlt]
        list += (1...9).map { goTool($0, title: "\($0)") }
        list += [startStop, openInBrowser, showInFinder, projectSettings, removeProject]
        list += ProjectPage.Tab.allCases.map { projectTab(KeyEquivalent($0.shortcutKey), title: L("site.tab.\($0.rawValue)")) }
        list += GitTab.allCases.map { gitTab($0.shortcut, title: $0.title) }
        list += [gitSync, gitNewBranch, gitDictionary, shortcutsSheet,
                 dbReload, dbRun, dbFormat, dbNewTab, dbCloseTab, dbNextTab, dbPreviousTab,
                 sshNewTab, sshCloseTab, sshNextTab, sshPreviousTab, sshSplitRight, sshSplitDown, sshSearchHosts, sshInspector,
                 vaultBack, vaultLock]
        return list
    }

    /// The pairs that press the same chord while both can be active. Empty is healthy.
    static func collisions(in list: [AppShortcut] = Shortcuts.all) -> [(AppShortcut, AppShortcut)] {
        var found: [(AppShortcut, AppShortcut)] = []
        for (index, first) in list.enumerated() {
            for second in list[(index + 1)...] where first.collides(with: second) { found.append((first, second)) }
        }
        return found
    }

    /// The chord of a palette action, by its command id (what the menu shows for the same thing).
    static func chord(forCommand id: String) -> String {
        let map: [String: AppShortcut] = ["new": newProject, "add": addExisting, "page.home": home, "settings.general": settings]
        return map[id]?.display ?? ""
    }

    /// The registry as the help sheet lists it: by group, in menu order, those that match `query`
    /// (without accents or capitals) in the action or the chord.
    static func sections(matching query: String, in list: [AppShortcut] = Shortcuts.all) -> [(group: AppShortcut.Group, items: [AppShortcut])] {
        let words = PaletteMatch.fold(query).split(separator: " ")
        return AppShortcut.Group.allCases.compactMap { group in
            let items = list.filter { shortcut in
                guard shortcut.group == group else { return false }
                let haystack = PaletteMatch.fold(shortcut.title + " " + shortcut.display)
                return words.allSatisfy { haystack.contains($0) }
            }
            return items.isEmpty ? nil : (group, items)
        }
    }
}
