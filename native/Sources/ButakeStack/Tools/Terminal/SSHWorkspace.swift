import AppKit
import Foundation
import SwiftUI

// MARK: - Tabs and panes

/// A tab's layout: one terminal, or terminals side by side (horizontal) or stacked (vertical).
indirect enum PaneNode: Identifiable {
    case leaf(TerminalSession)
    case split(Axis, [PaneNode])

    nonisolated var id: String {
        switch self {
        case .leaf(let session): session.id.uuidString
        case .split(let axis, let children): "\(axis == .horizontal ? "h" : "v")-" + (children.first?.id ?? "")
        }
    }
    @MainActor var sessions: [TerminalSession] {
        switch self {
        case .leaf(let session): [session]
        case .split(_, let children): children.flatMap(\.sessions)
        }
    }
    /// Puts `new` next to `target` along `axis`.
    @MainActor func inserting(_ new: TerminalSession, beside target: UUID, axis: Axis) -> PaneNode {
        switch self {
        case .leaf(let session) where session.id == target: return .split(axis, [self, .leaf(new)])
        case .leaf: return self
        case .split(let current, let children):
            if current == axis, let index = children.firstIndex(where: { if case .leaf(let s) = $0 { s.id == target } else { false } }) {
                var list = children
                list.insert(.leaf(new), at: index + 1)
                return .split(axis, list)
            }
            return .split(current, children.map { $0.inserting(new, beside: target, axis: axis) })
        }
    }
    /// Without `target`; nil when nothing is left.
    @MainActor func removing(_ target: UUID) -> PaneNode? {
        switch self {
        case .leaf(let session): return session.id == target ? nil : self
        case .split(let axis, let children):
            let left = children.compactMap { $0.removing(target) }
            if left.isEmpty { return nil }
            return left.count == 1 ? left[0] : .split(axis, left)
        }
    }
}

enum WorkspaceTabKind: Hashable { case terminal, sftp(String) }

@MainActor @Observable final class WorkspaceTab: Identifiable {
    let id = UUID()
    let kind: WorkspaceTabKind
    var root: PaneNode?
    var focused: UUID?
    var browser: SFTPBrowser?
    init(session: TerminalSession) {
        kind = .terminal
        root = .leaf(session)
        focused = session.id
    }
    init(browser: SFTPBrowser) {
        kind = .sftp(browser.host.id)
        self.browser = browser
    }
    var sessions: [TerminalSession] { root?.sessions ?? [] }
    var focusedSession: TerminalSession? { sessions.first { $0.id == focused } ?? sessions.first }
    var title: String {
        if let browser { return String(format: L("ssh.sftp.tabTitle"), browser.host.name) }
        return focusedSession?.title ?? L("ssh.local.shell")
    }
    var symbol: String {
        if browser != nil { return Symbols.folder }
        return focusedSession?.kind.isLocal == true ? Symbols.terminal : Symbols.server
    }
    var ended: Bool { !sessions.isEmpty && sessions.allSatisfy { !$0.running && $0.exitCode != nil } }
    /// The saved host the tab belongs to (nil for a local shell).
    var hostID: String? { browser?.host.id ?? focusedSession?.kind.hostID }
    /// Closing it would end something under way: a session's process or a transfer.
    var busy: Bool { sessions.contains(where: \.busy) || browser?.transfers.contains { $0.state == .running } == true }
}

/// The terminal side of the SSH plugin: open tabs (terminals and SFTP browsers), the selected
/// one and the terminal theme. Sessions survive leaving the page; they end with the app.
@MainActor @Observable final class SSHWorkspace {
    static let shared = SSHWorkspace()
    var tabs: [WorkspaceTab] = []
    /// nil = the selected host's page (its forwards).
    var selected: UUID?
    /// The program of «Este Mac» chosen in the list (its card in the detail); nil while a host is.
    var localSelection: String?
    /// A sheet of the page: they open from the toolbar and from the list's empty state.
    var sheet: Sheet?
    enum Sheet: String, Identifiable { case importConfig, snippets, groups; var id: String { rawValue } }
    /// ⌘F while no terminal is shown: the host list's search field takes the keyboard.
    var searchRequests = 0
    /// A tab with something under way the user asked to close: it waits for a confirmation.
    var closing: WorkspaceTab?
    /// The host's card beside a session (hidden until the user opens it), as the user left it.
    var inspector: Bool { didSet { UserDefaults.standard.set(inspector, forKey: "ssh.inspector") } }
    var themeID: String { didSet { UserDefaults.standard.set(themeID, forKey: "ssh.terminal.theme") } }
    var customThemes: [TerminalTheme] { didSet { saveThemes() } }
    @ObservationIgnored private var clickMonitor: Any?

    init() {
        inspector = UserDefaults.standard.object(forKey: "ssh.inspector") as? Bool ?? false
        themeID = UserDefaults.standard.string(forKey: "ssh.terminal.theme") ?? "auto"
        customThemes = (UserDefaults.standard.data(forKey: "ssh.terminal.themes")).flatMap { try? JSONDecoder().decode([TerminalTheme].self, from: $0) } ?? []
    }
    private func saveThemes() {
        if let data = try? JSONEncoder().encode(customThemes) { UserDefaults.standard.set(data, forKey: "ssh.terminal.themes") }
    }
    var themes: [TerminalTheme] { [TerminalTheme.automatic()] + TerminalTheme.presets + customThemes }
    var theme: TerminalTheme { themes.first { $0.id == themeID } ?? TerminalTheme.automatic() }

    var current: WorkspaceTab? { tabs.first { $0.id == selected } }

    /// The row the list highlights, always what the detail shows: the host of the tab on screen,
    /// or the program of its console of this Mac; without a tab on screen, what was chosen by hand
    /// (a program, or the host `chosen`), and «Consola» while nothing was.
    func listSelection(host chosen: String?) -> String {
        if let tab = current {
            if let host = tab.hostID { return host }
            if let program = tab.focusedSession?.kind.launch?.program { return SSHHostList.tag(local: program) }
        }
        return localSelection.map(SSHHostList.tag(local:)) ?? chosen ?? SSHHostList.tag(local: LocalProgram.shellID)
    }

    /// The focused pane follows the mouse: a click inside a terminal makes it the active one.
    private func watchClicks() {
        guard clickMonitor == nil else { return }
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            MainActor.assumeIsolated {
                let workspace = SSHWorkspace.shared
                for tab in workspace.tabs {
                    for session in tab.sessions where session.view.window === event.window {
                        let point = session.view.convert(event.locationInWindow, from: nil)
                        if session.view.bounds.contains(point) { tab.focused = session.id }
                    }
                }
            }
            return event
        }
    }

    @discardableResult func openTerminal(_ kind: TerminalKind, title: String) -> TerminalSession {
        watchClicks()
        let session = TerminalSession(kind: kind, title: title)
        let tab = WorkspaceTab(session: session)
        tabs.append(tab)
        selected = tab.id
        Task { await session.start(); try? await Task.sleep(for: .milliseconds(150)); session.focus() }
        return session
    }
    /// A console of this Mac: `program` in the home folder, or in `directory` when given.
    func openLocal(_ program: LocalProgram = .shell, directory: String? = nil) {
        openLocal(LocalConsoles.launch(program, directory: directory ?? NSHomeDirectory()))
    }
    func openLocal(_ launch: LocalLaunch) {
        let program = LocalProgram(id: launch.program, executable: nil, version: nil)
        openTerminal(.local(launch), title: LocalConsoles.title(program, directory: launch.directory))
    }

    func openSFTP(_ host: SSHHost, path: String = "") {
        if let tab = tabs.first(where: { $0.kind == .sftp(host.id) }) { selected = tab.id; return }
        let tab = WorkspaceTab(browser: SFTPBrowser(host: host))
        tabs.append(tab)
        selected = tab.id
        Task { await tab.browser?.load(path) }
    }

    /// A new terminal next to the focused one, of the same kind (same host or local shell).
    func split(_ tab: WorkspaceTab, axis: Axis) {
        guard let root = tab.root, let focused = tab.focusedSession else { return }
        let session = TerminalSession(kind: focused.kind, title: focused.title)
        tab.root = root.inserting(session, beside: focused.id, axis: axis)
        tab.focused = session.id
        Task { await session.start(); try? await Task.sleep(for: .milliseconds(150)); session.focus() }
    }

    func closePane(_ tab: WorkspaceTab, _ session: TerminalSession) {
        session.terminate()
        tab.root = tab.root?.removing(session.id)
        if tab.root == nil { close(tab) } else { tab.focused = tab.sessions.first?.id }
    }

    /// ⌘W and the tab's close button: at once, or after a confirmation while something runs.
    func requestClose(_ tab: WorkspaceTab) {
        if tab.busy { closing = tab } else { close(tab) }
    }

    /// ⌃Tab and ⌃⇧Tab: the next or the previous tab, the host's page first.
    func cycle(_ step: Int) {
        let order: [UUID?] = [nil] + tabs.map(\.id)
        let index = order.firstIndex(of: selected) ?? 0
        selected = order[(index + step + order.count) % order.count]
        current?.focusedSession?.focus()
    }

    func close(_ tab: WorkspaceTab) {
        tab.sessions.forEach { $0.terminate() }
        tab.browser?.cancelAll()
        let index = tabs.firstIndex { $0.id == tab.id } ?? 0
        tabs.removeAll { $0.id == tab.id }
        if selected == tab.id { selected = tabs.isEmpty ? nil : tabs[max(0, min(index, tabs.count) - 1)].id }
    }
}

// MARK: - Snippets

struct SSHSnippet: Codable, Identifiable, Hashable, Sendable {
    var id: String = ""
    var name: String = ""
    var command: String = ""
    var description: String = ""
    /// A host's id; nil = every terminal.
    var host: String?
}

@MainActor @Observable final class SSHSnippets {
    static let shared = SSHSnippets()
    let store = StackStore.shared
    var list: [SSHSnippet] = []
    var loaded = false

    /// The ones that apply to a terminal: global ones and those of its host.
    func available(for kind: TerminalKind?) -> [SSHSnippet] {
        list.filter { $0.host == nil || $0.host == kind?.hostID }
    }
    func load() async {
        if let value: [SSHSnippet] = try? await store.call(["method": "sshSnippets"]) { list = value }
        loaded = true
    }
    func save(_ snippet: SSHSnippet) async -> Bool {
        do {
            let object = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(snippet))) as? [String: Any] ?? [:]
            let _: SSHSnippet = try await store.call(["method": "sshSnippetSave", "snippet": object])
            await load()
            return true
        } catch { store.report(error); return false }
    }
    func delete(_ snippet: SSHSnippet) async {
        do {
            let _: Bool = try await store.call(["method": "sshSnippetDelete", "id": snippet.id])
            await load()
        } catch { store.report(error) }
    }
}
