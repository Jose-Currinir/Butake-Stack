import SwiftUI

/// The actions on a commit, in its context menu and its detail: revert it, copy it to another
/// branch, start a branch or a tag on it, copy its identifier.
struct GitCommitMenu: View {
    let repository: GitRepository
    let commit: GitCommitSummary

    var body: some View {
        let work = GitWork.shared
        let blocked = repository.busy || !repository.snapshot.operation.isEmpty
        Button { work.reverting = commit } label: { Label(L("git.history.revertEllipsis"), systemImage: Symbols.gitRevert) }.accessibilityIdentifier("git.history.menu.revert")
            .disabled(blocked || commit.parents.count != 1 || repository.snapshot.detached)
            .help(L(commit.parents.count > 1 ? "git.history.revertMergeHelp" : "git.history.revertHelp"))
        Menu {
            ForEach(targets, id: \.self) { target in
                Button(target) { work.copying = GitCopyRequest(hashes: [commit.hash], title: commit.subject, target: target) }.accessibilityIdentifier("git.history.menu.copyTo.\(target)")
            }
        } label: {
            Label(L("git.history.copyTo"), systemImage: Symbols.gitCopyCommits)
        }
        .disabled(blocked || targets.isEmpty || commit.parents.count > 1)
        .accessibilityIdentifier("git.history.menu.copyTo")
        Divider()
        Button { work.naming = GitNameRequest(kind: .branch, commit: commit) } label: {
            Label(L("git.history.branchHereEllipsis"), systemImage: Symbols.gitNewBranch)
        }
        .disabled(repository.busy)
        .accessibilityIdentifier("git.history.menu.branchHere")
        Button { work.naming = GitNameRequest(kind: .tag, commit: commit) } label: { Label(L("git.history.tagEllipsis"), systemImage: Symbols.tags) }.accessibilityIdentifier("git.history.menu.tag")
            .disabled(repository.busy)
        Divider()
        Button { repository.copyIdentifier(commit.hash) } label: { Label(L("git.history.copyHash"), systemImage: Symbols.copy) }.accessibilityIdentifier("git.history.menu.copyHash")
    }

    /// Local branches other than the current one.
    private var targets: [String] {
        repository.localBranches.map(\.name).filter { $0 != repository.snapshot.branch }
    }
}
