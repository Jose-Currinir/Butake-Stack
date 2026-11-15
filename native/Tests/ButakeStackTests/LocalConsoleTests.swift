import Darwin
import Foundation
import Testing
@testable import ButakeStack

/// «Este Mac» offers «Consola» and only the terminal assistants found on this Mac: one that is not
/// installed, whose file is gone, or that is not an interactive program (AWS CLI, Git) is not.
@MainActor @Test func localListHasOnlyWhatIsDetected() {
    let tools: [String: DevToolStatus] = [
        "claude-code": DevToolStatus(installed: true, version: "2.1.0", path: "/qa/bin/claude"),
        "codex": DevToolStatus(installed: false, version: nil),
        "aws": DevToolStatus(installed: true, version: "2.30", path: "/qa/bin/aws"),
        "gh": DevToolStatus(installed: true, version: "2.80", path: "/qa/bin/gh"),
    ]
    let programs = LocalConsoles.programs(tools) { $0.hasPrefix("/qa/bin/") }
    #expect(programs.map(\.id) == ["shell", "claude-code"])
    #expect(programs[1].executable == "/qa/bin/claude" && programs[1].version == "2.1.0")
    // Installed but its file is gone: not offered either.
    #expect(LocalConsoles.programs(tools) { _ in false }.map(\.id) == ["shell"])
    #expect(LocalConsoles.programs([:]).map(\.id) == ["shell"])
}

/// A console starts in the home folder, or in the project's with its versions first on PATH;
/// an assistant goes through the login shell with its path as an argument, never in the script.
@MainActor @Test func localConsoleStartsInTheRightFolder() async throws {
    let home = LocalConsoles.launch(.shell, directory: NSHomeDirectory())
    #expect(home.directory == NSHomeDirectory() && home.execName?.hasPrefix("-") == true && home.arguments.isEmpty)
    #expect(LocalConsoles.title(.shell, directory: NSHomeDirectory()).hasSuffix("· ~"))

    let assistant = LocalProgram(id: "claude-code", executable: "/qa/bin/claude", version: nil)
    let project = LocalConsoles.launch(assistant, directory: "/qa/tienda", project: "tienda",
                                       projectEnvironment: ["PATH": "/qa/runtimes/php/8.3/bin:/usr/bin", "JAVA_HOME": "/qa/jdk", "SECRET": "x"])
    #expect(project.directory == "/qa/tienda" && project.project == "tienda")
    if !project.arguments.isEmpty {
        #expect(project.arguments.last == "/qa/bin/claude" && !project.arguments.dropLast().contains { $0.contains("/qa/bin/claude") })
    }
    let path = try #require(project.environment.first { $0.hasPrefix("PATH=") })
    #expect(path.hasPrefix("PATH=/qa/runtimes/php/8.3/bin:"))
    #expect(project.environment.contains("JAVA_HOME=/qa/jdk") && !project.environment.contains { $0.hasPrefix("SECRET=") })
    #expect(LocalConsoles.path(first: ["/a", "/usr/bin"], inherited: "/b:/a:") == "/a:/usr/bin:/b:/bin:/usr/sbin:/sbin")

    // The process really starts there.
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("stack-console-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let launch = LocalLaunch(program: "qa", executable: "/bin/sh", arguments: ["-c", "pwd -P > where.txt"], directory: folder.path,
                             environment: ["PATH=/usr/bin:/bin"])
    let session = TerminalSession(kind: .local(launch), title: "qa")
    await session.start()
    let file = folder.appendingPathComponent("where.txt")
    for _ in 0..<100 where !FileManager.default.fileExists(atPath: file.path) { try await Task.sleep(for: .milliseconds(50)) }
    let written = try String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    let real = try #require(realpath(folder.path, nil))
    defer { free(real) }
    #expect(written == String(cString: real))
    session.terminate()
    await session.ending?.value
}

/// Closing a local session's tab ends its program and what it started (a job in the background
/// that ignores the hang-up too): nothing is left running nor waiting to be reaped.
@MainActor @Test func closingALocalSessionLeavesNoOrphans() async throws {
    let launch = LocalLaunch(program: LocalProgram.shellID, executable: "/bin/sh", arguments: ["-c", "(trap '' HUP TERM; exec sleep 300) & sleep 301; wait"],
                             directory: NSTemporaryDirectory(), environment: ["PATH=/usr/bin:/bin"])
    let workspace = SSHWorkspace()
    let session = TerminalSession(kind: .local(launch), title: "qa")
    let tab = WorkspaceTab(session: session)
    workspace.tabs = [tab]
    await session.start()
    let leader = session.view.process.shellPid
    #expect(leader > 0)
    var members: [pid_t] = []
    for _ in 0..<100 {
        members = SessionReaper.members(of: leader)
        if members.count >= 3 { break }
        try await Task.sleep(for: .milliseconds(50))
    }
    #expect(members.count >= 3, "The shell and its two sleeps: \(members)")
    // A console running a command asks before closing.
    #expect(tab.busy)
    workspace.close(tab)
    await session.ending?.value
    #expect(workspace.tabs.isEmpty && !session.running)
    // Orphans are reaped by launchd a moment after they die.
    for _ in 0..<40 where members.contains(where: { SessionReaper.alive($0) && getsid($0) == leader }) {
        try await Task.sleep(for: .milliseconds(50))
    }
    let left = members.filter { SessionReaper.alive($0) && getsid($0) == leader }
    #expect(left.isEmpty, "Still running: \(left)")
    // The program itself is not left as a zombie of the app.
    var status: Int32 = 0
    #expect(waitpid(leader, &status, WNOHANG) == -1)
}

/// The list highlights what the detail shows: the host or the console of the tab on screen, even
/// when another row was chosen before; without a tab on screen, what was chosen by hand; «Consola»
/// while nothing was.
@MainActor @Test func listSelectionFollowsTheTabOnScreen() {
    func local(_ program: String) -> WorkspaceTab {
        let launch = LocalLaunch(program: program, executable: "/bin/sh", directory: "/", environment: [])
        return WorkspaceTab(session: TerminalSession(kind: .local(launch), title: program))
    }
    let workspace = SSHWorkspace()
    let shell = SSHHostList.tag(local: LocalProgram.shellID)
    #expect(workspace.listSelection(host: nil) == shell)
    #expect(workspace.listSelection(host: "prod") == "prod")

    let console = local(LocalProgram.shellID)
    let assistant = local("claude-code")
    let remote = WorkspaceTab(session: TerminalSession(kind: .ssh("prod"), title: "prod"))
    workspace.tabs = [console, assistant, remote]
    // A console of this Mac on screen: its row, not the host chosen before.
    workspace.selected = console.id
    #expect(workspace.listSelection(host: "staging") == shell)
    workspace.selected = assistant.id
    #expect(workspace.listSelection(host: "staging") == SSHHostList.tag(local: "claude-code"))
    // A host's session: its host, also over a program chosen by hand.
    workspace.selected = remote.id
    workspace.localSelection = "claude-code"
    #expect(workspace.listSelection(host: "staging") == "prod")
    // The card instead of a tab, or no tabs at all: what was chosen by hand.
    workspace.selected = nil
    #expect(workspace.listSelection(host: "staging") == SSHHostList.tag(local: "claude-code"))
    workspace.localSelection = nil
    workspace.tabs = []
    #expect(workspace.listSelection(host: "staging") == "staging")
}
