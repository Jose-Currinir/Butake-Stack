import SwiftUI

/// Ramas in the content column: local branches (the current one marked, what each has to send and
/// to bring) and the remote ones that have no local copy yet. «Nueva rama…» at the foot.
struct GitBranchesList: View {
    @Bindable var repository: GitRepository
    @Bindable var tool = GitTool.shared
    @State private var search = ""

    private func matches(_ name: String) -> Bool { search.isEmpty || name.localizedCaseInsensitiveContains(search) }

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $repository.selectedBranch) {
                let local = repository.localBranches.filter { matches($0.name) }
                if !local.isEmpty {
                    Section(L("git.branch.local")) {
                        ForEach(local) { branch in
                            GitBranchRow(branch: branch, protected: repository.isProtected(branch.name) && repository.snapshot.mainProtected,
                                         onRemote: repository.snapshot.remoteBranches.contains { $0.short == branch.name })
                                .tag(branch.name)
                                .contextMenu { GitBranchMenuItems(repository: repository, name: branch.name, local: true) }
                        }
                    }
                }
                let remote = repository.remoteOnlyBranches.filter { matches($0.name) }
                if !remote.isEmpty {
                    Section(L("git.branch.remote")) {
                        ForEach(remote) { branch in
                            Label(branch.name, systemImage: Symbols.cloud)
                                .lineLimit(1).truncationMode(.middle)
                                .help(branch.name)
                                .tag(branch.name)
                                .contextMenu { GitBranchMenuItems(repository: repository, name: branch.name, local: false) }
                                .accessibilityIdentifier("git.branch.row.\(branch.name)")
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .themedScroll()
            .overlay {
                if !search.isEmpty && repository.localBranches.allSatisfy({ !matches($0.name) }) && repository.remoteOnlyBranches.allSatisfy({ !matches($0.name) }) {
                    ContentUnavailableView.search(text: search)
                }
            }
            .searchable(text: $search, placement: .sidebar, prompt: L("git.branch.search"))
            .accessibilityIdentifier("git.branch.list")
            HStack {
                Button { tool.creatingBranch = true } label: { Label(L("git.branch.newEllipsis"), systemImage: Symbols.gitNewBranch) }
                    .buttonStyle(.borderless).disabled(repository.busy)
                    .accessibilityIdentifier("git.branch.new")
                Spacer()
            }
            .padding(.horizontal, 10).frame(height: 29)
            .overlay(alignment: .top) { Divider() }
        }
        .onAppear { if repository.selectedBranch == nil { repository.selectedBranch = repository.snapshot.currentBranch?.name } }
    }
}

/// A local branch: name, the current one marked, ↑ to send and ↓ to bring, its remote gone.
private struct GitBranchRow: View {
    let branch: GitBranch
    let protected: Bool
    /// A branch of the same name exists on the remote (it is only not followed).
    let onRemote: Bool
    var body: some View {
        HStack(spacing: 6) {
            Label {
                Text(branch.name).lineLimit(1).truncationMode(.middle).fontWeight(branch.current ? .semibold : .regular)
            } icon: {
                Image(systemName: branch.current ? Symbols.selected : Symbols.git).foregroundStyle(branch.current ? Brand.success : .secondary)
            }
            Spacer(minLength: 4)
            if protected { Image(systemName: Symbols.locked).foregroundStyle(.secondary).help(L("git.branch.protectedHelp")) }
            if branch.gone {
                Image(systemName: Symbols.warning).foregroundStyle(Brand.warning).help(L("git.branch.goneHelp"))
            } else if branch.upstream.isEmpty {
                Text(L(onRemote ? "git.branch.untracked" : "git.branch.localOnly")).font(.uiCaption).foregroundStyle(.secondary)
                    .help(L(onRemote ? "git.branch.untrackedHelp" : "git.branch.localOnlyHelp"))
            }
            if branch.behind > 0 { Text(String(format: L("git.repo.behind"), branch.behind)).font(.uiCaption.monospacedDigit()).foregroundStyle(.secondary) }
            if branch.ahead > 0 { Text(String(format: L("git.repo.ahead"), branch.ahead)).font(.uiCaption.monospacedDigit()).foregroundStyle(.secondary) }
        }
        .help(branch.current ? String(format: L("git.branch.currentHelp"), branch.name) : branch.name)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("git.branch.row.\(branch.name)")
    }
}

/// The actions on a branch, in its context menu and in the detail.
struct GitBranchMenuItems: View {
    let repository: GitRepository
    let name: String
    let local: Bool

    var body: some View {
        let current = name == repository.snapshot.branch
        Button { GitBranchActions.shared.requestSwitch(name, in: repository) } label: { Label(L("git.branch.switch"), systemImage: Symbols.forward) }.accessibilityIdentifier("git.branch.menu.switch")
            .disabled(current || repository.busy)
        if local {
            Button { GitBranchActions.shared.merging = name } label: {
                Label(String(format: L("git.branch.mergeInto"), repository.branchTitle), systemImage: Symbols.gitMerge)
            }
            .disabled(current || repository.busy || repository.snapshot.detached)
            .accessibilityIdentifier("git.branch.menu.merge")
            Divider()
            Button { GitBranchActions.shared.renaming = name } label: { Label(L("git.branch.renameEllipsis"), systemImage: Symbols.edit) }.accessibilityIdentifier("git.branch.menu.rename")
                .disabled(repository.isProtected(name) || repository.busy)
            Button(role: .destructive) { GitBranchActions.shared.deleting = name } label: { Label(L("git.branch.deleteEllipsis"), systemImage: Symbols.delete) }.accessibilityIdentifier("git.branch.menu.delete")
                .disabled(current || repository.isProtected(name) || repository.busy)
        }
    }
}
