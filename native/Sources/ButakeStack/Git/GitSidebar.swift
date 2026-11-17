import SwiftUI

/// The open repository's sidebar, in the window's content column: where to look («Espacio de
/// trabajo»: changes, history, pull requests, problems), its branches (the current one marked;
/// a double click switches to it), the branches that are only on the remote and what is used now and
/// then (tags, saved changes, remotes). What is chosen here fills the detail (`GitWorkspace`).
struct GitSidebar: View {
    @Bindable var tool: GitTool
    @Bindable var repository: GitRepository
    @Bindable var work = GitWork.shared

    enum Item: Hashable {
        case tab(GitTab)
        case branch(String)
    }

    private var selection: Binding<Item?> {
        Binding {
            tool.tab == .branches ? repository.selectedBranch.map(Item.branch) : .tab(tool.tab)
        } set: { item in
            switch item {
            case .tab(let tab): tool.tab = tab
            case .branch(let name): repository.selectedBranch = name; tool.tab = .branches
            case nil: break
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            List(selection: selection) {
                Section(L("git.sidebar.workspace")) {
                    ForEach(GitTab.allCases.filter { $0 != .branches }) { tab in
                        Label(tab.title, systemImage: tab.symbol)
                            .badge(count(tab))
                            .tag(Item.tab(tab))
                            .accessibilityIdentifier("git.tab.\(tab.rawValue)")
                    }
                }
                Section(L("git.tab.branches")) {
                    ForEach(repository.localBranches) { branch in
                        GitBranchRow(branch: branch, protected: repository.isProtected(branch.name) && repository.snapshot.mainProtected,
                                     onRemote: repository.snapshot.remoteBranches.contains { $0.short == branch.name })
                            .tag(Item.branch(branch.name))
                    }
                }
                let remote = repository.remoteOnlyBranches
                if !remote.isEmpty {
                    Section(L("git.branch.remote")) {
                        ForEach(remote) { branch in
                            Label(branch.name, systemImage: Symbols.cloud)
                                .lineLimit(1).truncationMode(.middle)
                                .help(branch.name)
                                .tag(Item.branch(branch.name))
                                .accessibilityIdentifier("git.branch.row.\(branch.name)")
                        }
                    }
                }
                Section(L("git.sidebar.more")) {
                    ForEach([GitMoreSection.tags, .stashes, .remotes]) { section in
                        Button { work.moreSection = section; work.more = true } label: {
                            Label(section.title, systemImage: section.symbol).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }
                        .buttonStyle(HighlightButtonStyle())
                        .accessibilityIdentifier("git.sidebar.\(section.rawValue)")
                    }
                }
            }
            .listStyle(.sidebar)
            .themedScroll()
            .contextMenu(forSelectionType: Item.self) { items in
                if case .branch(let name) = items.first {
                    GitBranchMenuItems(repository: repository, name: name, local: repository.snapshot.branches.contains { $0.name == name })
                }
            } primaryAction: { items in
                if case .branch(let name) = items.first, name != repository.snapshot.branch { GitBranchActions.shared.requestSwitch(name, in: repository) }
            }
            .accessibilityIdentifier("git.sidebar")
            HStack {
                Button { tool.creatingBranch = true } label: { Label(L("git.branch.newEllipsis"), systemImage: Symbols.gitNewBranch) }
                    .buttonStyle(.borderless).disabled(repository.busy)
                    .accessibilityIdentifier("git.branch.new")
                Spacer()
            }
            .padding(.horizontal, 10).frame(height: 29)
            .overlay(alignment: .top) { Divider() }
        }
        .sheet(isPresented: $work.more) { GitMoreSheet(repository: repository, section: work.moreSection).themedSheet() }
    }

    /// Files waiting to be confirmed and problems to look at; nothing for the rest.
    private func count(_ tab: GitTab) -> Int {
        tab == .changes ? repository.snapshot.files.count : tab.badge(repository) ?? 0
    }
}

/// The detail of the Git tool: the list of what was chosen in the sidebar beside its detail (files
/// and their changes, commits and theirs…); a branch has only its detail.
struct GitWorkspace: View {
    let tab: GitTab
    let repository: GitRepository

    var body: some View {
        // Plain stacks, not split views: a split view runs under the toolbar and its divider would
        // cut through the toolbar's buttons. The toolbar keeps one background over both panes.
        Group {
            if tab == .branches {
                tab.detail(repository)
            } else if tab == .history {
                // The commits across the whole width, what the chosen one changed under them.
                GeometryReader { proxy in
                    VStack(spacing: 0) {
                        tab.list(repository).frame(height: max(180, proxy.size.height * 0.45))
                        Divider()
                        tab.detail(repository).frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            } else {
                HStack(spacing: 0) {
                    tab.list(repository).frame(width: 320).frame(maxHeight: .infinity)
                    Divider()
                    tab.detail(repository).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .toolbarBackground(.visible, for: .windowToolbar)
    }
}
