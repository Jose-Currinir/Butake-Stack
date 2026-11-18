import SwiftUI

/// Problemas' detail: the selected problem explained (what happens, why, what is involved) with
/// the button that solves it and, when there is one, the other way out.
struct GitProblemDetail: View {
    @Bindable var repository: GitRepository
    @Bindable var selection = GitProblemSelection.shared

    var body: some View {
        let problems = GitProblemSources.shared.problems(for: repository)
        if let problem = problems.first(where: { $0.id == selection.id }) ?? problems.first {
            Form {
                Section {
                    HStack(alignment: .top, spacing: 12) {
                        IconTile(symbol: problem.symbol, color: problem.severity.color, size: 40)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(problem.title).font(.uiTitle3.weight(.semibold)).frame(maxWidth: .infinity, alignment: .leading)
                            Text(problem.severity.title).font(.uiCaption).foregroundStyle(.secondary)
                        }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L("git.problems.why")).font(.uiHeadline)
                        Text(problem.reason).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                    }
                }
                if !problem.items.isEmpty {
                    Section(L("git.problems.involved")) {
                        ForEach(problem.items.prefix(200), id: \.self) { item in
                            Label { Text(item).lineLimit(1).truncationMode(.middle).help(item) } icon: { FileTypeIcon(path: item, size: 16) }
                        }
                        if problem.items.count > 200 {
                            Text(String(format: L("git.branch.moreFiles"), problem.items.count - 200)).font(.uiCaption).foregroundStyle(.secondary)
                        }
                    }
                }
                Section {
                    HStack(spacing: 8) {
                        if let action = problem.action { GitProblemButton(action: action, prominent: true, busy: repository.busy) }
                        if let secondary = problem.secondary { GitProblemButton(action: secondary, prominent: false, busy: repository.busy) }
                        Spacer(minLength: 0)
                    }
                } header: {
                    Text(L("git.problems.solution"))
                } footer: {
                    if repository.busy, let operation = repository.operation {
                        Label(operation.title, systemImage: Symbols.reload).font(.uiCaption).foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            .themedScroll()
            .accessibilityIdentifier("git.problems.detail")
        } else {
            ContentUnavailableView {
                Label(L("git.problems.emptyTitle"), systemImage: Symbols.success)
            } description: {
                Text(String(format: L("git.problems.emptyDetailBranch"), repository.branchTitle))
            }
            .accessibilityIdentifier("git.problems.detailEmpty")
        }
    }
}
