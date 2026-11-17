import AppKit
import SwiftUI

/// The Git tool's toolbar: the same actions always in the same place (`GitActionBar`).
struct GitToolbar: ToolbarContent {
    @Bindable var repository: GitRepository
    /// Symbols only (titles in the tooltips): the detail is too narrow for the titles.
    var compact = false

    var body: some ToolbarContent {
        // `.primaryAction` keeps them in the detail's part of the toolbar at every width.
        ToolbarItemGroup(placement: .primaryAction) {
            GitActionBar(repository: repository, compact: compact)
        }
    }
}

/// The current branch: switch to another (local or remote), create one, find one.
struct GitBranchMenu: View {
    @Bindable var repository: GitRepository
    @Bindable var tool = GitTool.shared
    @State private var finding = false

    var body: some View {
        Menu {
            Button { tool.creatingBranch = true } label: { Label(L("git.branch.newEllipsis"), systemImage: Symbols.gitNewBranch) }
                .accessibilityIdentifier("git.branchMenu.new")
            Button { finding = true } label: { Label(L("git.branch.findEllipsis"), systemImage: Symbols.search) }
                .accessibilityIdentifier("git.branchMenu.find")
            Divider()
            Section(L("git.branch.local")) {
                ForEach(repository.localBranches.prefix(15)) { branch in
                    Button { requestSwitch(branch.name) } label: {
                        Label(branch.name, systemImage: branch.current ? Symbols.selected : Symbols.git)
                    }
                    .disabled(branch.current)
                    .accessibilityIdentifier("git.branchMenu.switch.\(branch.name)")
                }
            }
        } label: {
            Label(repository.branchTitle, systemImage: Symbols.git)
                .labelStyle(.titleAndIcon)
        }
        .disabled(repository.busy)
        .help(L("git.branch.menuHelp"))
        .accessibilityIdentifier("git.toolbar.branch")
        .sheet(isPresented: $finding) { GitBranchFinderSheet(repository: repository) { requestSwitch($0) }.themedSheet() }
    }

    private func requestSwitch(_ name: String) { GitBranchActions.shared.requestSwitch(name, in: repository) }
}

/// The actions of every day, each one always in its place: confirm, bring, send, ask the remote, the
/// branch (switch, create, search), combine another branch into this one and put changes aside. A
/// count beside the title says what waits; what cannot be done now is dimmed, never hidden. While a
/// transfer runs, its progress and «Cancelar» take the place of the remote's actions.
struct GitActionBar: View {
    @Bindable var repository: GitRepository
    @Bindable var tool = GitTool.shared
    var compact = false
    @State private var confirmingMain = false

    var body: some View {
        let snapshot = repository.snapshot, state = repository.syncState
        button(counted(L("git.action.commit"), repository.files.count), Symbols.gitCommit, "commit", L("git.action.commitHelp")) { tool.tab = .changes }
        if case .running(let title, let cancellable) = state {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(title).font(.uiCallout).foregroundStyle(.secondary).lineLimit(1)
                if cancellable {
                    Button { repository.cancel() } label: { Label(L("common.cancel"), systemImage: Symbols.close) }
                        .help(L("git.sync.cancelHelp")).accessibilityIdentifier("git.sync.cancel")
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(state.identifier)
        } else if case .unfinished = state {
            button(state.title, state.symbol, "continue", state.help) { Task { await repository.sync() } }
        } else {
            button(counted(L("git.action.pull"), snapshot.behind), Symbols.gitPull, "pull", L("git.sync.pullHelp")) { Task { await repository.perform(.pull) } }
                .disabled(!snapshot.tracked)
            button(counted(L("git.action.push"), snapshot.ahead), Symbols.gitPush, "push", pushHelp(state)) { push(state) }
                .disabled(snapshot.detached)
                .confirmationDialog(String(format: L("git.sync.pushMainTitle"), snapshot.primaryBranch), isPresented: $confirmingMain) {
                    Button(L("git.sync.pushMainConfirm")) { Task { await repository.perform(.push) } }
                        .accessibilityIdentifier("git.sync.pushMainConfirm")
                    Button(L("common.cancel"), role: .cancel) {}.accessibilityIdentifier("git.sync.pushMainCancel")
                } message: {
                    Text(L("git.sync.pushMainDetail"))
                }
            button(L("git.sync.fetch"), Symbols.reload, "fetch", GitSyncState.fetch(last: repository.lastFetch).help) { Task { await repository.perform(.fetch) } }
                .disabled(!snapshot.hasRemote)
        }
        GitBranchMenu(repository: repository)
        Menu {
            ForEach(repository.localBranches.filter { !$0.current }) { branch in
                Button { GitBranchActions.shared.merging = branch.name } label: { Label(branch.name, systemImage: Symbols.git) }
                    .accessibilityIdentifier("git.action.merge.\(branch.name)")
            }
        } label: {
            if compact { Label(L("git.action.merge"), systemImage: Symbols.gitMerge).labelStyle(.iconOnly) }
            else { Label(L("git.action.merge"), systemImage: Symbols.gitMerge).labelStyle(.titleAndIcon) }
        }
        .disabled(repository.busy || snapshot.detached || repository.localBranches.count < 2)
        .help(L("git.action.merge") + ": " + String(format: L("git.action.mergeHelp"), repository.branchTitle))
        .accessibilityIdentifier("git.action.merge")
        button(L("git.action.stash"), Symbols.gitStash, "stash", L("git.more.stashNowHelp")) { Task { await repository.perform(.stash) } }
            .disabled(repository.files.isEmpty)
    }

    private func counted(_ title: String, _ count: Int) -> String {
        count > 0 ? String(format: L("git.tab.counted"), title, count) : title
    }

    private func button(_ title: String, _ symbol: String, _ id: String, _ help: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            if compact { Label(title, systemImage: symbol).labelStyle(.iconOnly) } else { Label(title, systemImage: symbol).labelStyle(.titleAndIcon) }
        }
        .disabled(repository.busy && id != "commit")
        .help(compact ? "\(title): \(help)" : help)
            .accessibilityIdentifier("git.action.\(id)")
    }

    /// «Subir» publishes what has nowhere to go yet: the repository, or the branch.
    private func pushHelp(_ state: GitSyncState) -> String {
        switch state {
        case .publishRepository, .publishBranch: state.help
        default: L("git.sync.pushHelp")
        }
    }

    private func push(_ state: GitSyncState) {
        if case .publishRepository = state { GitHosting.shared.publishing = true }
        else if repository.snapshot.tracked, repository.snapshot.branch == repository.snapshot.primaryBranch { confirmingMain = true }
        else { Task { await repository.perform(.push) } }
    }
}
