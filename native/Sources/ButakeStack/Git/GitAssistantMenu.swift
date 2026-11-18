import SwiftUI

/// «Abrir asistente aquí»: a terminal assistant (or the console) in Stack's Terminal, started in the
/// repository's folder or in one of its worktrees. Only while the Terminal is on: Git has no
/// terminal of its own.
struct GitAssistantMenu: View {
    /// The repository's folder or a worktree's; nil disables the menu.
    let directory: String?
    /// The identifier's suffix when there are several on screen (a worktree's row).
    var suffix: String?
    @Bindable private var store = StackStore.shared

    var body: some View {
        if store.pluginEnabled("ssh-terminal") {
            Menu {
                ForEach(LocalConsoles.programs) { program in
                    Button { if let directory { GitAssistant.open(program, in: directory) } } label: {
                        Label(program.title, systemImage: program.isShell ? Symbols.terminal : Symbols.ai)
                    }
                    .accessibilityIdentifier("git.assistant.\(program.id)" + (suffix.map { ".\($0)" } ?? ""))
                }
            } label: {
                Label(L("git.assistant.open"), systemImage: Symbols.ai)
            }
            .disabled(directory == nil)
            .help(L("git.assistant.help"))
            .accessibilityIdentifier("git.assistant" + (suffix.map { ".\($0)" } ?? ""))
        }
    }
}

/// Starts the program in Stack's Terminal. When the folder is a Stack project's, the project's
/// versions go first on PATH, as from the project's page.
@MainActor enum GitAssistant {
    static func open(_ program: LocalProgram, in directory: String) {
        let store = StackStore.shared
        guard store.pluginEnabled("ssh-terminal") else { store.openTool("ssh-terminal"); return }
        let project = store.projects.first { URL(fileURLWithPath: $0.path).standardizedFileURL.path == URL(fileURLWithPath: directory).standardizedFileURL.path }
        store.route = .tool("ssh-terminal")
        Task {
            let launch = if let project { await LocalConsoles.launch(program, in: project) } else { LocalConsoles.launch(program, directory: directory) }
            SSHWorkspace.shared.openLocal(launch)
        }
    }
}
