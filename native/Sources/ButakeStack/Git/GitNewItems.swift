import SwiftUI

/// The ways to bring a repository in, in the window's «+» menu while the Git tool is on screen.
/// The only menu for them: the repository list and the empty page offer the same three as shortcuts.
struct GitNewItems: View {
    var body: some View {
        Button { GitTool.shared.chooseAndAdd() } label: { Label(L("git.repo.add"), systemImage: Symbols.add) }
            .help(L("git.repo.addHelp")).accessibilityIdentifier("toolbar.add.gitRepository")
        Button { GitHosting.shared.cloning = true } label: { Label(L("git.clone.ellipsis"), systemImage: Symbols.gitClone) }
            .help(L("git.clone.help")).accessibilityIdentifier("toolbar.add.gitClone")
        Button { GitHosting.shared.creating = true } label: { Label(L("git.create.ellipsis"), systemImage: Symbols.gitCreateRepository) }
            .help(L("git.create.help")).accessibilityIdentifier("toolbar.add.gitCreate")
    }
}
