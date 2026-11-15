import AppKit
import Darwin
import Foundation
import SwiftTerm

// MARK: - Programs of this Mac

/// A program of this Mac the Terminal opens in a tab: the login shell («Consola») or a terminal
/// assistant found by the Utilidades page (installed by Stack or some other way).
struct LocalProgram: Identifiable, Hashable, Sendable {
    static let shellID = "shell"
    /// `shell` or the utility's id (`claude-code`, `codex`).
    let id: String
    /// The program's file; nil for the login shell, which is read when the session starts.
    let executable: String?
    let version: String?

    static let shell = LocalProgram(id: shellID, executable: nil, version: nil)
    var isShell: Bool { id == Self.shellID }
    var title: String { isShell ? L("ssh.local.shell") : L("tool.\(id)") }
    var detail: String { isShell ? L("ssh.local.shellDetail") : L("toolDetail.\(id)") }
    /// The list row's second line, short enough for the column at its narrowest.
    var summary: String { isShell ? L("ssh.local.shellShort") : version ?? detail }
    var tech: Tech? { isShell ? nil : .of(id) }
}

/// What a local session runs: the program, its arguments, the folder it starts in and its
/// environment. Built once when the tab opens; «Volver a abrir» runs it again as it was.
struct LocalLaunch: Hashable, Sendable {
    var program: String
    var executable: String
    var arguments: [String] = []
    /// argv[0]; a leading «-» makes the shell a login shell (`$SHELL -l`).
    var execName: String?
    var directory: String
    var environment: [String]
    /// The project whose versions go first on PATH, when it opened from one.
    var project: String?
}

/// The Terminal's consoles of this Mac: which programs it offers, how each one starts and how a
/// closed one ends with everything it started. Nothing is run without the user's action, nothing
/// of what is typed or shown is kept, and no secret goes in an argument or a variable.
@MainActor enum LocalConsoles {
    /// The utilities that make sense as an interactive session: the terminal assistants. The rest
    /// (AWS CLI, GitHub CLI, Git…) are commands of the console, not sessions of their own.
    static let assistants = ["claude-code", "codex"]

    /// «Consola» and each assistant detected on this Mac, in that order. One that is not
    /// installed (or whose file is gone) is not offered: it is installed from Utilidades.
    static func programs(_ tools: [String: DevToolStatus], fileExists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> [LocalProgram] {
        [.shell] + assistants.compactMap { id in
            guard let status = tools[id], status.installed, let path = status.path, fileExists(path) else { return nil }
            return LocalProgram(id: id, executable: path, version: status.version)
        }
    }
    static var programs: [LocalProgram] { programs(StackStore.shared.devTools) }
    static func program(_ id: String?) -> LocalProgram? { programs.first { $0.id == id } }

    /// The user's login shell (their account's, else zsh).
    static func loginShell() -> String {
        var shell = "/bin/zsh"
        if let entry = getpwuid(getuid()), let raw = entry.pointee.pw_shell { shell = String(cString: raw) }
        return FileManager.default.isExecutableFile(atPath: shell) ? shell : "/bin/zsh"
    }

    /// The console's PATH: the given folders first (a project's versions, or Stack's links in
    /// `~/.local/bin`), then what the app inherited, then the system's; each folder once.
    nonisolated static func path(first: [String], inherited: String?) -> String {
        var seen = Set<String>()
        let all = first + (inherited ?? "").split(separator: ":").map(String.init) + ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        return all.filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: ":")
    }

    /// The session's environment: a terminal's (TERM, COLORTERM, LANG, USER, LOGNAME, HOME), the
    /// agent's socket and the temporary folder, the shell, and PATH with Stack's versions. A
    /// project adds only the paths of its versions (JAVA_HOME, VIRTUAL_ENV) and its Google Cloud
    /// account and project (GCPLink), never its `.env`.
    static func environment(shell: String, project: [String: String] = [:]) -> [String] {
        let inherited = ProcessInfo.processInfo.environment
        var out = Terminal.getEnvironmentVariables(termName: "xterm-256color", trueColor: true)
        for name in ["SSH_AUTH_SOCK", "TMPDIR"] { if let value = inherited[name] { out.append("\(name)=\(value)") } }
        out.append("SHELL=\(shell)")
        let home = NSHomeDirectory()
        let links = [home + "/.local/bin", home + "/.cargo/bin"].filter { FileManager.default.fileExists(atPath: $0) }
        let first = (project["PATH"]?.split(separator: ":").map(String.init) ?? []) + links
        out.append("PATH=\(path(first: first, inherited: inherited["PATH"]))")
        for name in ["JAVA_HOME", "VIRTUAL_ENV"] + GCPLink.variables { if let value = project[name] { out.append("\(name)=\(value)") } }
        return out
    }

    /// How `program` starts in `directory`: the shell as a login shell; an assistant through the
    /// login shell (so it finds what the user's profile adds to PATH), which then becomes it. The
    /// command line is fixed: the program's path goes as an argument, never inside the script.
    static func launch(_ program: LocalProgram, directory: String, project: String? = nil, projectEnvironment: [String: String] = [:]) -> LocalLaunch {
        let shell = loginShell()
        let environment = environment(shell: shell, project: projectEnvironment)
        let name = (shell as NSString).lastPathComponent
        guard let executable = program.executable else {
            return LocalLaunch(program: program.id, executable: shell, execName: "-" + name, directory: directory, environment: environment, project: project)
        }
        // Shells that take `-l -i -c` and pass `$0` on; any other runs the program by itself.
        guard ["zsh", "bash", "sh", "ksh", "dash"].contains(name) else {
            return LocalLaunch(program: program.id, executable: executable, directory: directory, environment: environment, project: project)
        }
        return LocalLaunch(program: program.id, executable: shell, arguments: ["-l", "-i", "-c", "exec \"$0\"", executable],
                           directory: directory, environment: environment, project: project)
    }

    /// The same, with the versions of `project` and its Google Cloud account and project (asked to
    /// the engine, which lets a value the project sets by hand win over the link).
    static func launch(_ program: LocalProgram, in project: Project) async -> LocalLaunch {
        let environment: [String: String] = (try? await StackStore.shared.call(["method": "siteShellEnvironment", "id": project.id])) ?? [:]
        return launch(program, directory: project.path, project: project.id, projectEnvironment: environment)
    }

    /// «Programa · carpeta»: the folder's name, or «~» for the home folder.
    static func title(_ program: LocalProgram, directory: String) -> String {
        let folder = directory == NSHomeDirectory() ? "~" : (directory as NSString).lastPathComponent
        return String(format: L("ssh.local.tabTitle"), program.title, folder)
    }

    /// Opens `program` in the Terminal from elsewhere (Utilidades, a project): the tool's page
    /// with a new tab. With the tool off it opens Ajustes › Herramientas on its row instead.
    static func open(_ program: LocalProgram, project: Project? = nil) {
        let store = StackStore.shared
        guard store.pluginEnabled("ssh-terminal") else { store.openTool("ssh-terminal"); return }
        store.route = .tool("ssh-terminal")
        Task {
            let workspace = SSHWorkspace.shared
            if let project { workspace.openLocal(await launch(program, in: project)) }
            else { workspace.openLocal(program) }
        }
    }

    /// «Nueva consola en carpeta…»: the folder chosen in the open panel, or nothing.
    static func chooseFolder() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory())
        panel.prompt = L("ssh.local.chooseFolder")
        return panel.runModal() == .OK ? panel.url?.standardizedFileURL.path : nil
    }
}

// MARK: - Ending a session

/// Ends a local session with everything it started. Closing the terminal hangs up its pty and
/// asks the program to end; then each process of the session gets SIGHUP, what is still there
/// after a moment gets SIGKILL, and the program is reaped, so no orphan nor zombie is left.
/// Only a program that left the session on purpose (a daemon) stays, as in any terminal.
enum SessionReaper {
    /// Every process of the session `leader` began (the program and what runs inside it).
    static func members(of leader: pid_t) -> [pid_t] {
        guard leader > 0 else { return [] }
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [leader] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let found = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        let members = pids.prefix(Int(max(0, found))).filter { $0 > 0 && getsid($0) == leader }
        return members.contains(leader) ? members : [leader] + members
    }

    /// Whether `pid` is still running (a zombie of ours counts as gone once reaped).
    static func alive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 || errno == EPERM }

    /// Hangs up and, if needed, kills `members` (the leader first); reaps the leader. Off the
    /// main thread: it waits up to `grace` for them to end by themselves.
    static func end(leader: pid_t, members: [pid_t], grace: Duration = .milliseconds(1500)) async {
        guard leader > 0 else { return }
        for pid in members { kill(pid, SIGHUP) }
        let deadline = ContinuousClock.now + grace
        var status: Int32 = 0
        var reaped = false
        while ContinuousClock.now < deadline {
            // SwiftTerm may have reaped it already: then it is not our child any more (ECHILD).
            if !reaped {
                let result = waitpid(leader, &status, WNOHANG)
                reaped = result == leader || (result == -1 && errno == ECHILD)
            }
            if reaped && !members.contains(where: { $0 != leader && alive($0) && getsid($0) == leader }) { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
        for pid in members where pid == leader ? !reaped : (alive(pid) && getsid(pid) == leader) { kill(pid, SIGKILL) }
        if !reaped { waitpid(leader, &status, 0) }
    }
}
