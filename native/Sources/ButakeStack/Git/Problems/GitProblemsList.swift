import SwiftUI

/// Problemas in the content column: everything that needs attention, errors first, each row with
/// what happens and its button. «Todo en orden» when there is nothing.
struct GitProblemsList: View {
    @Bindable var repository: GitRepository
    @State private var selection: String?

    var body: some View {
        let problems = GitProblemSources.shared.problems(for: repository)
        Group {
            if problems.isEmpty {
                ContentUnavailableView {
                    Label(L("git.problems.emptyTitle"), systemImage: Symbols.success)
                } description: {
                    Text(L("git.problems.emptyDetail"))
                }
                .accessibilityIdentifier("git.problems.empty")
            } else {
                List(selection: $selection) {
                    ForEach(problems) { problem in
                        GitProblemRow(problem: problem, busy: repository.busy).tag(problem.id)
                    }
                }
                .listStyle(.sidebar)
                .themedScroll()
                .accessibilityIdentifier("git.problems.list")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .gitWorkDialogs(repository: repository)
        .onChange(of: problems.map(\.id), initial: true) { old, ids in
            // The first problem stays selected while it is the first; a choice of the user stays while it exists.
            if selection == nil || !ids.contains(selection ?? "") || selection == old.first { selection = ids.first }
            GitProblemSelection.shared.id = selection
        }
        .onChange(of: selection) { GitProblemSelection.shared.id = selection }
    }
}

/// The problem selected in the list, for the detail.
@MainActor @Observable final class GitProblemSelection {
    static let shared = GitProblemSelection()
    var id: String?
}

/// A problem: its symbol on a tile of its severity, what happens, and the button that solves it.
private struct GitProblemRow: View {
    let problem: GitProblem
    let busy: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            IconTile(symbol: problem.symbol, color: problem.severity.color, size: 26)
            VStack(alignment: .leading, spacing: 4) {
                Text(problem.title).font(.uiBody.weight(.medium)).lineLimit(3)
                Text(problem.severity.title).font(.uiCaption).foregroundStyle(.secondary)
                if let action = problem.action {
                    GitProblemButton(action: action, prominent: false, busy: busy).controlSize(.small)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .help(problem.reason)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("git.problems.row.\(problem.id)")
    }
}

/// A problem's button: icon and text, disabled while the repository is busy.
struct GitProblemButton: View {
    let action: GitProblemAction
    let prominent: Bool
    let busy: Bool

    var body: some View {
        let button = Button(role: action.destructive ? .destructive : nil) { Task { await action.run() } } label: {
            Label(action.title, systemImage: action.symbol)
        }
        .disabled(busy)
        .accessibilityIdentifier("git.problems.action.\(action.id)")
        if prominent { button.buttonStyle(.borderedProminent) } else { button.buttonStyle(.bordered) }
    }
}
