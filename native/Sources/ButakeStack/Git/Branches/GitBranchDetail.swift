import SwiftUI

/// Ramas' detail: the selected branch, its remote and how it compares with the current branch
/// (what each has that the other lacks, the files that differ, who wrote it), with its actions.
struct GitBranchDetail: View {
    @Bindable var repository: GitRepository
    @State private var comparison: GitBranchComparison?
    @State private var loading = false

    var body: some View {
        if let name = repository.selectedBranch {
            let branch = repository.snapshot.branches.first { $0.name == name }
            Form {
                Section {
                    LabeledContent(L("git.branch.name")) { Text(name).textSelection(.enabled) }
                    if let branch {
                        LabeledContent(L("git.branch.upstream"), value: branch.upstream.isEmpty ? L("git.branch.localOnly") : branch.upstream)
                        if !branch.upstream.isEmpty {
                            LabeledContent(L("git.branch.tracking"), value: branch.gone ? L("git.branch.gone")
                                           : String(format: L("git.aheadBehind"), branch.ahead, branch.behind))
                        }
                        if branch.updated > 0 {
                            LabeledContent(L("git.branch.updated"), value: Date(timeIntervalSince1970: TimeInterval(branch.updated)).formatted(.relative(presentation: .named)))
                        }
                    } else {
                        LabeledContent(L("git.branch.upstream"), value: L("git.branch.remoteOnly"))
                    }
                } header: {
                    HStack {
                        Text(branch?.current == true ? L("git.branch.currentTitle") : L("git.branch.title"))
                        Spacer()
                        actions(name, local: branch != nil, current: branch?.current == true)
                    }
                }
                if branch?.current != true {
                    comparisonSection(name)
                }
            }
            .formStyle(.grouped)
            .themedScroll()
            .task(id: "\(name)|\(repository.snapshot.branch)|\(repository.snapshot.headCommit?.hash ?? "")") {
                loading = true
                comparison = await repository.comparison(of: name)
                loading = false
            }
            .accessibilityIdentifier("git.branch.detail")
        } else {
            ContentUnavailableView(L("git.branch.chooseTitle"), systemImage: Symbols.git, description: Text(L("git.branch.chooseDetail")))
        }
    }

    @ViewBuilder private func actions(_ name: String, local: Bool, current: Bool) -> some View {
        if !current {
            Button { GitBranchActions.shared.requestSwitch(name, in: repository) } label: { Label(L("git.branch.switch"), systemImage: Symbols.forward) }
                .buttonStyle(.borderedProminent).controlSize(.small)
                .disabled(repository.busy)
                .accessibilityIdentifier("git.branch.detail.switch")
        }
        Menu {
            GitBranchMenuItems(repository: repository, name: name, local: local)
        } label: {
            Label(L("git.branch.more"), systemImage: Symbols.more).labelStyle(.iconOnly)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help(L("git.branch.more"))
        .accessibilityIdentifier("git.branch.detail.more")
    }

    @ViewBuilder private func comparisonSection(_ name: String) -> some View {
        Section {
            if let comparison {
                LabeledContent(String(format: L("git.branch.onlyHere"), name), value: "\(comparison.ahead)")
                LabeledContent(String(format: L("git.branch.onlyThere"), repository.branchTitle), value: "\(comparison.behind)")
                if !comparison.authors.isEmpty {
                    LabeledContent(L("git.branch.authors"), value: comparison.authors.prefix(4).map { "\($0.name) (\($0.count))" }.joined(separator: ", "))
                }
                ForEach(comparison.files.prefix(200), id: \.path) { file in
                    LabeledContent {
                        GitStatsBadge(stats: GitLineStats(additions: file.additions, deletions: file.deletions))
                    } label: {
                        Label { Text(file.path).lineLimit(1).truncationMode(.middle).help(file.path) } icon: { FileTypeIcon(path: file.path, size: 16) }
                    }
                }
                if comparison.files.count > 200 {
                    Text(String(format: L("git.branch.moreFiles"), comparison.files.count - 200)).font(.uiCaption).foregroundStyle(.secondary)
                }
            } else if loading {
                ProgressView().frame(maxWidth: .infinity)
            } else {
                Text(L("git.branch.noComparison")).foregroundStyle(.secondary)
            }
        } header: {
            Text(String(format: L("git.branch.compareTitle"), repository.branchTitle))
        }
    }
}
