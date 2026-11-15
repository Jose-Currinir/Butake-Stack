import SwiftUI

/// Something of the open repository that needs attention, said in plain words (DISENO.md,
/// «Problemas»): what happens, why, how serious it is, and the button that solves it.
struct GitProblem: Identifiable {
    /// Errors first: they block work. Warnings can wait a little; notes only inform.
    enum Severity: Int, Comparable, Sendable {
        case error, warning, note
        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
        var color: Color {
            switch self {
            case .error: TileColor.error
            case .warning: TileColor.warning
            case .note: TileColor.system
            }
        }
        var title: String { L("git.problems.severity.\(self)") }
    }

    /// Stable: `<source>.<kind>` (`git.conflicts`, `hosting.checks`…); the row's identifier uses it.
    let id: String
    let severity: Severity
    /// What happens, in one line.
    let title: String
    /// Why it happens and what it means.
    let reason: String
    let symbol: String
    /// The button that solves it.
    let action: GitProblemAction?
    /// A second way out («Cancelar la operación…»), when there is one.
    var secondary: GitProblemAction?
    /// The files or commits involved, listed in the detail.
    var items: [String] = []
}

/// A button of a problem: its text and symbol, and what it does.
struct GitProblemAction {
    let title: String
    let symbol: String
    /// Identifier suffix of the button (`git.problems.action.<id>`).
    let id: String
    var destructive = false
    let run: @MainActor () async -> Void
}

// MARK: - Extension point: sources of problems
//
// A source turns the state of the open repository into problems. Built-in sources live in
// `GitProblemsBuiltIn.swift`; another part of the tool adds its own once, at start, under its own
// id (registering the same id again replaces it). A source reads observable state, so the list,
// the tab's count, the repository picker and the project's «Git» row follow it by themselves.
// Git/Hosting's failed checks of a pull request are such a source (`GitHostingProblems.source`).

/// Every source of «Problemas», built-in first.
@MainActor @Observable final class GitProblemSources {
    typealias Source = @MainActor (GitRepository) -> [GitProblem]
    static let shared = GitProblemSources()

    private(set) var sources: [(id: String, make: Source)] = [("git", GitProblemsBuiltIn.problems), ("hosting.checks", GitHostingProblems.source)]

    /// Adds a source, or replaces the one with the same id.
    func register(_ id: String, _ make: @escaping Source) {
        sources.removeAll { $0.id == id }
        sources.append((id, make))
    }

    func unregister(_ id: String) { sources.removeAll { $0.id == id } }

    /// The repository's problems: errors first, each source in its order.
    func problems(for repository: GitRepository) -> [GitProblem] {
        let all = sources.flatMap { $0.make(repository) }
        return all.enumerated().sorted { ($0.element.severity, $0.offset) < ($1.element.severity, $1.offset) }.map(\.element)
    }
}

extension Int {
    /// The count to show next to a title: nothing when it is zero.
    var positive: Int? { self > 0 ? self : nil }
}
