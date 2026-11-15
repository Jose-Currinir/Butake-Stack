import SwiftUI

/// A program of «Este Mac» in the Terminal's list: its tile (the product's logo, or the terminal's
/// for «Consola»), its name and version, and how many of its sessions are open. Return or a
/// double click opens it in a new tab.
struct LocalProgramRow: View {
    let program: LocalProgram
    @Bindable var workspace: SSHWorkspace
    var body: some View {
        let sessions = workspace.tabs.flatMap(\.sessions).filter { $0.kind.launch?.program == program.id && $0.running }.count
        HStack(spacing: 8) {
            LocalProgramTile(program: program, size: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(program.title).font(.uiBody).lineLimit(1).truncationMode(.tail)
                Text(program.summary).font(.uiCaption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 4)
            if sessions > 0 {
                Image(systemName: Symbols.terminal).font(.uiCaption).foregroundStyle(.secondary)
                    .help(String(format: L("ssh.sessionsOpen"), sessions)).accessibilityLabel(String(format: L("ssh.sessionsOpen"), sessions))
            }
        }
        .accessibilityIdentifier("ssh.local.row.\(program.id)")
    }
}

/// The tile of a program of this Mac: the product's logo, or a solid terminal tile for the shell.
struct LocalProgramTile: View {
    let program: LocalProgram
    var size: CGFloat = 32
    var body: some View {
        if let tech = program.tech { TechLogo(tech: tech, size: size) } else { IconTile(symbol: Symbols.terminal, size: size) }
    }
}

/// «Abrir consola aquí» of a project: «Consola» and each assistant detected, opened in the
/// Terminal in the project's folder with its versions first on PATH.
struct ProjectConsoleItems: View {
    let project: Project
    /// From the menu bar panel the window may be closed: it opens first.
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        ForEach(LocalConsoles.programs) { program in
            Button { openWindow(id: "main"); LocalConsoles.open(program, project: project) } label: {
                Label(program.title, systemImage: program.isShell ? Symbols.terminal : Symbols.ai)
            }
            .accessibilityIdentifier("ssh.local.project.\(program.id)")
        }
    }
}

/// What the Terminal adds: a console of this Mac (here or in a folder), each assistant detected,
/// or a new host. The window's «+» shows them on this page, and so does the list's footer.
struct TerminalNewItems: View {
    /// The identifiers' prefix: each place that shows them has its own.
    var scope = "ssh.local.new"
    var body: some View {
        let workspace = SSHWorkspace.shared
        Button { workspace.openLocal() } label: { Label(L("ssh.local.newConsole"), systemImage: Symbols.terminal) }
            .help(L("ssh.local.newConsoleHelp")).accessibilityIdentifier("\(scope).console")
        Button { if let folder = LocalConsoles.chooseFolder() { workspace.openLocal(directory: folder) } } label: {
            Label(L("ssh.local.newConsoleInFolderEllipsis"), systemImage: Symbols.folder)
        }
        .help(L("ssh.local.newConsoleInFolderHelp")).accessibilityIdentifier("\(scope).consoleInFolder")
        let assistants = LocalConsoles.programs.filter { !$0.isShell }
        if !assistants.isEmpty {
            Divider()
            ForEach(assistants) { program in
                Button { workspace.openLocal(program) } label: { Label(program.title, systemImage: Symbols.ai) }
                    .help(String(format: L("ssh.local.newAssistantHelp"), program.title))
                    .accessibilityIdentifier("\(scope).\(program.id)")
            }
        }
        Divider()
        Button { SSHTerminal.shared.editing = SSHHost() } label: { Label(L("ssh.newHostEllipsis"), systemImage: Symbols.newHost) }
            .help(L("ssh.newHostHelp")).accessibilityIdentifier("\(scope).host")
    }
}

/// What opens from a program of this Mac: here, or in a folder chosen first.
struct LocalProgramMenu: View {
    let program: LocalProgram
    @Bindable var workspace: SSHWorkspace
    var body: some View {
        Button { workspace.openLocal(program) } label: { Label(L("ssh.local.open"), systemImage: Symbols.terminal) }
            .accessibilityIdentifier("ssh.local.menu.open")
        Button { if let folder = LocalConsoles.chooseFolder() { workspace.openLocal(program, directory: folder) } } label: {
            Label(L("ssh.local.openInFolderEllipsis"), systemImage: Symbols.folder)
        }
        .accessibilityIdentifier("ssh.local.menu.openInFolder")
    }
}
