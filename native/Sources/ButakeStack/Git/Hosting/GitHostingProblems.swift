import AppKit
import Foundation

/// Something on the provider that needs attention, for the «Problemas» tab (G-3), in plain words:
/// what happens, why, and what the button does. The orchestrator turns each one into a `GitProblem`.
struct GitHostingProblem: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable { case checksFailed }
    let kind: Kind
    /// «2 comprobaciones fallaron en feature/pagos»
    let title: String
    /// Why it matters, and the names of the failed checks.
    let detail: String
    /// The button's title («Ver en GitHub») and the page it opens.
    let actionTitle: String
    let page: URL?
    /// The failed checks' names, in order.
    let checks: [String]
    var id: String { "\(kind.rawValue):\(checks.joined(separator: ","))" }
}

/// The source of «checks fallidos» for «Problemas».
///
/// `current(for:)` reads what the Pull requests tab already loaded for the repository (no network,
/// no Keychain); `problems(…)` is the pure rule underneath, tested without a window. The checks are
/// read when the Pull requests tab appears; «Problemas» can ask for them again with
/// `GitHosting.shared.session(for: repository).refreshBranchChecks()` before calling this.
///
/// ```swift
/// // In Problemas (G-3), once integrated:
/// let hosting = GitHostingProblems.current(for: repository)
/// // → [GitHostingProblem(kind: .checksFailed,
/// //      title: "2 comprobaciones fallaron en feature/pagos",
/// //      detail: "El proveedor no aceptará combinar hasta que pasen: build, lint.",
/// //      actionTitle: "Ver en GitHub", page: https://github.com/acme/tienda/pull/7, checks: ["build", "lint"])]
/// problems += hosting.map { GitProblem(hosting: $0) }
/// ```
@MainActor enum GitHostingProblems {
    static func current(for repository: GitRepository) -> [GitHostingProblem] {
        let session = GitHosting.shared.session(for: repository)
        guard let provider = session.hosted?.provider else { return [] }
        return problems(branch: repository.snapshot.branch, provider: provider, checks: session.branchChecks,
                        pullRequest: session.branchPullRequest, repositoryPage: session.hosted?.webPage(GitHosting.shared.endpoints))
    }

    /// The source «Problemas» registers: the branch's failed checks, as a problem that opens their page.
    static func source(_ repository: GitRepository) -> [GitProblem] {
        current(for: repository).map { found in
            GitProblem(id: "hosting.checks", severity: .warning, title: found.title, reason: found.detail, symbol: Symbols.warning,
                       action: found.page.map { page in
                           GitProblemAction(title: found.actionTitle, symbol: Symbols.openInBrowser, id: "hosting.checks") { NSWorkspace.shared.open(page) }
                       },
                       items: found.checks)
        }
    }

    /// One problem when any check of the branch failed; none while they pass or still run.
    nonisolated static func problems(branch: String, provider: GitHostingProvider, checks: [GitHostingCheck],
                                     pullRequest: GitPullRequest?, repositoryPage: URL?) -> [GitHostingProblem] {
        let failed = checks.filter { $0.state == .failure }
        guard !failed.isEmpty else { return [] }
        let names = failed.map(\.name)
        let title = failed.count == 1 ? String(format: L("git.problem.checks.one"), branch) : String(format: L("git.problem.checks.many"), failed.count, branch)
        let detail = String(format: L(pullRequest == nil ? "git.problem.checks.detail" : "git.problem.checks.detailPR"), names.joined(separator: ", "))
        // The failed check's own page when there is only one; otherwise the pull request or the repository.
        let page = failed.count == 1 ? failed[0].page ?? pullRequest?.page ?? repositoryPage : pullRequest?.page ?? repositoryPage
        return [GitHostingProblem(kind: .checksFailed, title: title, detail: detail,
                                  actionTitle: String(format: L("git.pr.openIn"), provider.title), page: page, checks: names)]
    }
}
