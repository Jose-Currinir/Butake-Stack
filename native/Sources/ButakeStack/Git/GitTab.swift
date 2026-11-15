import SwiftUI

/// The tabs of the Git tool (DISENO.md, «Pestañas»): each one has a list in the content column and
/// a detail. Shortcuts ⌥⌘1…⌥⌘5 (⌘1…⌘6 belong to the Ir menu).
enum GitTab: String, CaseIterable, Identifiable, Sendable {
    case changes, history, branches, pullRequests, problems
    var id: String { rawValue }
    var title: String { L("git.tab.\(rawValue)") }
    var symbol: String {
        switch self {
        case .changes: Symbols.gitChanges
        case .history: Symbols.gitHistory
        case .branches: Symbols.git
        case .pullRequests: Symbols.gitPullRequests
        case .problems: Symbols.gitProblems
        }
    }
    var shortcut: KeyEquivalent { KeyEquivalent(Character("\((GitTab.allCases.firstIndex(of: self) ?? 0) + 1)")) }
}

// MARK: - The content of each tab
//
// Each tab's views live in their own folder (`Changes/`, `History/`, `Branches/`, `Hosting/`,
// `Problems/`), take the open repository and read or change it through `GitRepository` (state,
// `perform`, `refresh`); `badge` returns the count shown next to the tab's title (Problemas).

extension GitTab {
    /// The tab's list, in the window's content column under the repository picker.
    @MainActor @ViewBuilder func list(_ repository: GitRepository) -> some View {
        switch self {
        case .changes: GitChangesList(repository: repository)
        case .branches: GitBranchesList(repository: repository)
        case .history: GitHistoryList(repository: repository)
        case .problems: GitProblemsList(repository: repository)
        case .pullRequests: GitPullRequestsList(repository: repository)
        }
    }

    /// The tab's detail: what is selected in its list.
    @MainActor @ViewBuilder func detail(_ repository: GitRepository) -> some View {
        switch self {
        case .changes: GitChangesDetail(repository: repository)
        case .branches: GitBranchDetail(repository: repository)
        case .history: GitHistoryDetail(repository: repository)
        case .problems: GitProblemDetail(repository: repository)
        case .pullRequests: GitPullRequestDetail(repository: repository)
        }
    }

    /// The count next to the tab's title: how many problems need attention.
    @MainActor func badge(_ repository: GitRepository) -> Int? {
        switch self {
        case .problems: GitProblemSources.shared.problems(for: repository).count.positive
        case .changes, .history, .branches, .pullRequests: nil
        }
    }

    /// The title in the tab picker, with its count when it has one.
    @MainActor func title(_ repository: GitRepository) -> String {
        badge(repository).map { String(format: L("git.tab.counted"), title, $0) } ?? title
    }
}
