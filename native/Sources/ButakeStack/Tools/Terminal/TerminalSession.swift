import AppKit
import Foundation
import SwiftTerm
import SwiftUI

// MARK: - Terminal themes

/// Colors and size of the embedded terminal. "auto" follows the app's theme (light or dark).
struct TerminalTheme: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var background: UInt32
    var foreground: UInt32
    var cursor: UInt32
    var selection: UInt32
    /// The 16 ANSI colors (normal then bright).
    var ansi: [UInt32]
    var fontSize: Double = 12.5
    var builtin: Bool = false

    static let defaultANSIDark: [UInt32] = [0x1E1E1E, 0xF2777A, 0x99CC99, 0xFFCC66, 0x6699CC, 0xCC99CC, 0x66CCCC, 0xD3D0C8,
                                            0x747369, 0xF2777A, 0x99CC99, 0xFFCC66, 0x6699CC, 0xCC99CC, 0x66CCCC, 0xF2F0EC]
    static let defaultANSILight: [UInt32] = [0x1D1D1F, 0xC0392B, 0x2E7D32, 0x9A6700, 0x1F5FBF, 0x8E44AD, 0x00838F, 0x8A8A8E,
                                             0x5C5C60, 0xE04B3A, 0x3C9A41, 0xB7850B, 0x2F74E0, 0xA25BC2, 0x0097A7, 0x1D1D1F]
    static let presets: [TerminalTheme] = [
        TerminalTheme(id: "butake-dark", name: "Butake oscuro", background: 0x16171B, foreground: 0xE6E6E6, cursor: 0x6BA8FF, selection: 0x2E4A73, ansi: defaultANSIDark, builtin: true),
        TerminalTheme(id: "butake-light", name: "Butake claro", background: 0xFFFFFF, foreground: 0x1D1D1F, cursor: 0x1F5FBF, selection: 0xCFE0FA, ansi: defaultANSILight, builtin: true),
        TerminalTheme(id: "solarized-dark", name: "Solarized oscuro", background: 0x002B36, foreground: 0x93A1A1, cursor: 0x93A1A1, selection: 0x073642,
                      ansi: [0x073642, 0xDC322F, 0x859900, 0xB58900, 0x268BD2, 0xD33682, 0x2AA198, 0xEEE8D5, 0x002B36, 0xCB4B16, 0x586E75, 0x657B83, 0x839496, 0x6C71C4, 0x93A1A1, 0xFDF6E3], builtin: true),
        TerminalTheme(id: "solarized-light", name: "Solarized claro", background: 0xFDF6E3, foreground: 0x586E75, cursor: 0x586E75, selection: 0xEEE8D5,
                      ansi: [0x073642, 0xDC322F, 0x859900, 0xB58900, 0x268BD2, 0xD33682, 0x2AA198, 0xEEE8D5, 0x002B36, 0xCB4B16, 0x586E75, 0x657B83, 0x839496, 0x6C71C4, 0x93A1A1, 0xFDF6E3], builtin: true),
    ]

    /// The app's own theme turned into terminal colors.
    @MainActor static func automatic() -> TerminalTheme {
        let theme = Brand.theme
        let dark = ThemeStore.shared.isDark
        let base = dark ? presets[0] : presets[1]
        var ansi = dark ? defaultANSIDark : defaultANSILight
        ansi[1] = theme.deletion.value; ansi[2] = theme.addition.value; ansi[3] = theme.warning.value
        ansi[4] = theme.accent.value; ansi[5] = theme.renamed.value; ansi[6] = theme.modified.value
        return TerminalTheme(id: "auto", name: L("ssh.terminal.theme.auto"), background: theme.surface?.value ?? theme.background?.value ?? base.background,
                             foreground: theme.text?.value ?? base.foreground, cursor: theme.accent.value, selection: base.selection, ansi: ansi, builtin: true)
    }
}

extension UInt32 {
    var nsColor: NSColor { HexColor(self).ns }
    var termColor: SwiftTerm.Color {
        SwiftTerm.Color(red: UInt16((self >> 16) & 0xFF) * 257, green: UInt16((self >> 8) & 0xFF) * 257, blue: UInt16(self & 0xFF) * 257)
    }
}

// MARK: - Sessions

enum TerminalKind: Hashable, Sendable {
    /// A program of this Mac (the shell or an assistant), as it was launched.
    case local(LocalLaunch)
    case ssh(String)
    var hostID: String? { if case .ssh(let id) = self { id } else { nil } }
    var launch: LocalLaunch? { if case .local(let launch) = self { launch } else { nil } }
    var isLocal: Bool { launch != nil }
}

private struct SessionLaunch: Codable, Sendable { var executable: String; var args: [String]; var title: String }

/// One terminal: a SwiftTerm view (kept alive across SwiftUI updates) and the process behind it.
/// SSH sessions run `/usr/bin/ssh` with exactly the arguments the engine builds and validates.
@MainActor @Observable final class TerminalSession: Identifiable {
    let id = UUID()
    let kind: TerminalKind
    var title: String
    /// What the remote program sets (OSC title), shown under the tab name.
    var programTitle = ""
    var running = false
    var exitCode: Int32?
    var started: Date?
    var searchVisible = false
    var searchText = ""
    var matchSummary = ""
    @ObservationIgnored let view: LocalProcessTerminalView
    @ObservationIgnored private var bridge: SessionBridge?
    @ObservationIgnored var appliedSignature = ""
    /// What the assistant of this session reports about its consumption (`AssistantUsage`); nil
    /// while it has reported nothing, and always for a program that reports none.
    var usage: AssistantUsage?
    /// Stack asked the assistant for its status in this launch (not when the user has a status
    /// line of their own, which Stack leaves alone).
    var usageReported = false
    @ObservationIgnored private var report: AssistantUsageReport?
    @ObservationIgnored private var usageWatch: Task<Void, Never>?

    init(kind: TerminalKind, title: String) {
        self.kind = kind
        self.title = title
        view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        view.optionAsMetaKey = true
        // The scroll bar as in the rest of the app: no track of its own over the theme's background.
        view.subviews.compactMap { $0 as? NSScroller }.forEach { $0.scrollerStyle = .overlay }
        let bridge = SessionBridge(session: self)
        self.bridge = bridge
        view.processDelegate = bridge
        view.setAccessibilityIdentifier("ssh.terminal.view")
    }

    /// The environment of an SSH session: only what ssh needs (the agent, the home folder, UTF-8).
    static func sshEnvironment() -> [String] {
        let env = ProcessInfo.processInfo.environment
        var out = ["TERM=xterm-256color", "COLORTERM=truecolor", "LANG=\(env["LANG"] ?? "en_US.UTF-8")", "PATH=/usr/bin:/bin:/usr/sbin:/sbin"]
        for name in ["HOME", "USER", "LOGNAME", "SSH_AUTH_SOCK"] { if let value = env[name] { out.append("\(name)=\(value)") } }
        return out
    }
    func start() async {
        guard !running else { return }
        exitCode = nil
        switch kind {
        case .local(let launch):
            // A folder that is gone (a project moved away) starts in the home folder instead.
            var folder: ObjCBool = false
            let present = FileManager.default.fileExists(atPath: launch.directory, isDirectory: &folder) && folder.boolValue
            view.startProcess(executable: launch.executable, args: launch.arguments + watchUsage(of: launch), environment: launch.environment,
                              execName: launch.execName, currentDirectory: present ? launch.directory : NSHomeDirectory())
        case .ssh(let id):
            do {
                let launch: SessionLaunch = try await StackStore.shared.call(["method": "sshSession", "id": id])
                guard launch.executable == "/usr/bin/ssh" else { return }
                title = launch.title
                view.startProcess(executable: launch.executable, args: launch.args, environment: TerminalSession.sshEnvironment())
            } catch {
                StackStore.shared.report(error)
                exitCode = -1
                return
            }
        }
        running = true
        started = .now
    }

    /// Asks the assistant of `launch` to report its status to a file of this session and follows
    /// it while the session runs; the arguments that go after the program's own (none for a
    /// program that reports no status, or when the user has their own status line).
    private func watchUsage(of launch: LocalLaunch) -> [String] {
        endUsage()
        guard AssistantUsageSource.of(launch.program)?.reportsStatus == true, !AssistantUsageReport.userHasStatusLine(),
              let report = AssistantUsageReport.make(id: id) else { return [] }
        self.report = report
        usageReported = true
        usageWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled else { return }
                if let usage = report.read(), usage != self.usage { self.usage = usage }
            }
        }
        return report.arguments
    }
    private func endUsage() {
        usageWatch?.cancel()
        usageWatch = nil
        report?.remove()
        report = nil
        usageReported = false
        usage = nil
    }

    /// Types one of the assistant's own commands («/usage») in the session and runs it.
    func run(command: String) {
        guard running else { return }
        view.send(txt: command)
        Task { try? await Task.sleep(for: .milliseconds(150)); if running { view.send(txt: "\r") }; focus() }
    }

    func reconnect() async {
        view.getTerminal().resetToInitialState()
        view.feed(text: "\u{1b}[2J\u{1b}[H")
        await start()
    }

    /// Ends the process and everything it started (`SessionReaper`): nothing is left running
    /// after its tab or pane closes. `ending` is the reaping, for whoever must wait for it.
    func terminate() {
        guard running else { return }
        let leader = view.process.shellPid
        let members = SessionReaper.members(of: leader)
        view.terminate()
        running = false
        endUsage()
        ending = Task.detached { await SessionReaper.end(leader: leader, members: members) }
    }
    @ObservationIgnored var ending: Task<Void, Never>?

    /// Closing it would end something under way: a connection, an assistant, or a command the
    /// console is running (a console idle at its prompt closes without asking).
    var busy: Bool {
        guard running else { return false }
        guard let launch = kind.launch, launch.program == LocalProgram.shellID else { return true }
        return SessionReaper.members(of: view.process.shellPid).count > 1
    }

    func terminated(_ code: Int32?) {
        running = false
        endUsage()
        exitCode = code ?? -1
        // A refused host key makes ssh exit with 255 at once: compare the server again.
        if let id = kind.hostID, code == 255, let started, Date.now.timeIntervalSince(started) < 20 {
            Task { await SSHTerminal.shared.recheckAfterFailure(id) }
        }
    }

    /// Writes a snippet at the prompt. Without `run` nothing is executed: a multi-line snippet
    /// goes as a bracketed paste (the shell keeps it editable) or, if the program does not
    /// support that, only when the user chose to run it.
    @discardableResult func insert(_ command: String, run: Bool) -> Bool {
        guard running else { return false }
        let text = command.replacingOccurrences(of: "\r\n", with: "\n")
        let bracketed = view.getTerminal().bracketedPasteMode
        if !run && text.contains("\n") && !bracketed { return false }
        if bracketed { view.send(txt: "\u{1b}[200~" + text + "\u{1b}[201~") } else { view.send(txt: text) }
        if run { view.send(txt: "\r") }
        focus()
        return true
    }

    func focus() { view.window?.makeFirstResponder(view) }

    func apply(theme: TerminalTheme, scale: Double) {
        let size = max(8, min(36, theme.fontSize * scale))
        let signature = "\(theme.hashValue)-\(size)"
        guard signature != appliedSignature else { return }
        appliedSignature = signature
        view.font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        // SwiftTerm sizes the grid for the new font over the whole width, scroller included: the
        // last columns would be drawn under it. Sizing it again as a resize does leaves the room.
        view.setFrameSize(view.frame.size)
        view.installColors(theme.ansi.prefix(16).map(\.termColor))
        view.nativeBackgroundColor = theme.background.nsColor
        view.nativeForegroundColor = theme.foreground.nsColor
        view.caretColor = theme.cursor.nsColor
        view.selectedTextBackgroundColor = theme.selection.nsColor
    }

    func find(next: Bool) {
        guard !searchText.isEmpty else { matchSummary = ""; return }
        let found = next ? view.findNext(searchText) : view.findPrevious(searchText)
        matchSummary = found ? "" : L("ssh.terminal.search.none")
    }
    func closeSearch() {
        searchVisible = false
        matchSummary = ""
        view.clearSearch()
        focus()
    }
}

/// Receives SwiftTerm's process callbacks (on the main queue) for a session.
@MainActor private final class SessionBridge: NSObject {
    weak var session: TerminalSession?
    init(session: TerminalSession) { self.session = session }
}
extension SessionBridge: @preconcurrency LocalProcessTerminalViewDelegate {
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) { session?.programTitle = String(title.prefix(120)) }
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func processTerminated(source: TerminalView, exitCode: Int32?) { session?.terminated(exitCode) }
}
