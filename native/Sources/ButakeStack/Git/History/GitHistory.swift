import Foundation

/// Historial of the open repository: the commits on screen (the current branch or all of them),
/// the search and its results, the selected commit with its message and diff, the pages and the
/// last reorganization («Deshacer»). One per repository (`GitRepository.history`).
@MainActor @Observable final class GitHistory {
    /// Weak: a search or a read still running never keeps a closed repository alive.
    @ObservationIgnored private weak var repository: GitRepository?
    @ObservationIgnored private let store: StackStore
    @ObservationIgnored private let root: String

    /// Only the current branch (true) or every branch, remote branch and tag.
    var onlyBranch = true { didSet { if onlyBranch != oldValue { Task { await reloadBranch(); await runSearch() } } } }
    var search = "" { didSet { if search != oldValue { scheduleSearch() } } }
    var scope: GitHistorySearchScope = .message { didSet { if scope != oldValue { scheduleSearch() } } }

    /// The current branch's commits (the snapshot mixes every branch).
    private(set) var branchCommits: [GitCommitSummary]?
    /// The commits found; nil while there is no search of commits.
    private(set) var results: [GitCommitSummary]?
    /// The lines found by «Contenido»; nil otherwise.
    private(set) var matches: [GitContentMatch]?
    private(set) var searching = false
    /// Why the history or a search could not be read (not the same as «0 resultados»).
    private(set) var readFailure: GitFailure?
    /// Why a search could not be asked («Escribe una fecha…»).
    private(set) var searchNote: String?
    /// Tracked and untracked files (the «Archivo» scope and the suggestions).
    private(set) var paths: [String] = []

    var selected: String? { didSet { if selected != oldValue { loadDetail() } } }
    var selectedMatch: String?
    private(set) var detail: GitCommitDetail?
    /// The last reorganization of this branch, while it can be undone.
    var lastBackup: GitRewriteBackup?
    private(set) var loadingMore = false

    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var detailTask: Task<Void, Never>?
    @ObservationIgnored private var searchGeneration = 0
    @ObservationIgnored private var graphKey = ""
    @ObservationIgnored private var graphCache = GitCommitGraph(commits: [])

    init(repository: GitRepository) {
        self.repository = repository
        store = repository.store
        root = repository.root
    }

    private var snapshotCommits: [GitCommitSummary] { repository?.snapshot.commits ?? [] }
    private var limit: Int { repository?.historyLimit ?? 180 }
    private func query(_ arguments: [String]) async throws -> String {
        try await store.call(["method": "gitQuery", "path": root, "args": arguments])
    }

    // MARK: The list

    /// What the list shows: the results of a search, or the history.
    var commits: [GitCommitSummary] {
        if let results { return results }
        return onlyBranch ? branchCommits ?? [] : snapshotCommits
    }

    var searchingCommits: Bool { results != nil }

    /// The lanes of the history on screen (no graph for search results: they skip commits).
    func graph(_ shown: [GitCommitSummary], localBranches: Set<String>) -> GitCommitGraph {
        let key = "\(shown.count)|\(shown.first?.hash ?? "")|\(shown.last?.hash ?? "")|\(onlyBranch)|\(shown.first?.refs ?? "")"
        if key != graphKey {
            graphKey = key
            graphCache = GitCommitGraph(commits: shown.map { GitGraphCommit(hash: $0.hash, parents: $0.parents, refs: $0.refs) },
                                        localBranches: localBranches, pruneMissingParents: onlyBranch)
        }
        return graphCache
    }

    /// Reads the current branch's commits again (after a refresh or a page more).
    func reloadBranch() async {
        guard onlyBranch else { return }
        guard !snapshotCommits.isEmpty else { branchCommits = []; return }
        let arguments = ["log", "-\(limit)", "--no-show-signature", "--topo-order", GitHistorySearch.format, "HEAD"]
        do {
            let next = GitHistorySearch.commits(try await query(arguments))
            if next != branchCommits { branchCommits = next }
            // A failed search keeps its message until the search changes; only the branch's own clears here.
            if results == nil, matches == nil { readFailure = nil }
        } catch {
            let failure = GitFailure(error)
            if !failure.cancelled { readFailure = failure }
            if branchCommits == nil { branchCommits = [] }
        }
        if selected == nil { selected = commits.first?.hash }
    }

    /// The list may go on: it is as long as the page.
    var canLoadMore: Bool { results == nil && commits.count >= limit }

    func loadMore() async {
        guard !loadingMore, canLoadMore, let repository else { return }
        loadingMore = true
        defer { loadingMore = false }
        repository.historyLimit += 180
        await repository.refresh()
        await reloadBranch()
    }

    // MARK: Searching

    private func scheduleSearch() {
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await self?.runSearch()
        }
    }

    /// Asks Git for the search on screen.
    func runSearch() async {
        let text = search.trimmingCharacters(in: .whitespacesAndNewlines)
        searchNote = nil
        guard !text.isEmpty else { results = nil; matches = nil; readFailure = nil; return }
        if (scope == .file || scope == .content) && paths.isEmpty { await loadPaths() }
        guard let arguments = GitHistorySearch.arguments(scope, text: text, onlyBranch: onlyBranch, paths: paths) else {
            if scope == .content { matches = [] } else { results = []; matches = nil }
            searchNote = L("git.history.note.\(scope.rawValue)")
            return
        }
        searchGeneration += 1
        let generation = searchGeneration
        searching = true
        defer { if generation == searchGeneration { searching = false } }
        let output: String
        do {
            output = try await query(arguments)
        } catch {
            guard generation == searchGeneration else { return }
            let failure = GitFailure(error)
            if !failure.cancelled { readFailure = failure }
            return
        }
        // A newer search, or other text, scope or branch filter, makes this answer stale.
        guard generation == searchGeneration, text == search.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        readFailure = nil
        if scope == .content {
            results = nil
            matches = GitHistorySearch.matches(output)
            if let first = matches?.first, selectedMatch == nil || !(matches?.contains { $0.id == selectedMatch } ?? false) { selectedMatch = first.id }
        } else {
            matches = nil
            results = GitHistorySearch.commits(output)
            if let first = results?.first, !(results?.contains { $0.hash == selected } ?? false) { selected = first.hash }
        }
    }

    /// The repository's files, once per search session.
    func loadPaths() async {
        let output: String
        do { output = try await query(["ls-files", "--cached", "--others", "--exclude-standard", "-z"]) } catch {
            let failure = GitFailure(error)
            if !failure.cancelled { readFailure = failure }
            return
        }
        paths = output.split(separator: "\0").map(String.init)
    }

    var suggestions: [String] {
        GitHistorySearch.suggestions(scope, text: search, commits: snapshotCommits, paths: paths)
    }

    // MARK: The selected commit

    var selectedCommit: GitCommitSummary? {
        guard let selected else { return nil }
        return commits.first { $0.hash == selected } ?? snapshotCommits.first { $0.hash == selected }
    }

    private func loadDetail() {
        detailTask?.cancel()
        guard let hash = selected else { detail = nil; return }
        if detail?.hash != hash { detail = GitCommitDetail(hash: hash) }
        detailTask = Task { [weak self] in
            guard let self else { return }
            async let body = self.query(["show", "-s", "--no-show-signature", "--format=%B", hash])
            async let patch = self.query(["show", "--format=", "--no-ext-diff", "--no-textconv", "--no-color",
                                                     "--diff-merges=first-parent", hash])
            let message = (try? await body) ?? ""
            let text = (try? await patch) ?? ""
            guard !Task.isCancelled, self.selected == hash else { return }
            let lines = message.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
            let rest = lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            self.detail = GitCommitDetail(hash: hash, body: rest, sections: GitDiffSection.split(text), loaded: true)
        }
    }

    /// The selected content match's file, read to preview it.
    var selectedMatchItem: GitContentMatch? { matches?.first { $0.id == selectedMatch } }
}

/// The message and diff of the selected commit.
struct GitCommitDetail: Equatable, Sendable {
    var hash: String
    var body = ""
    var sections: [GitDiffSection] = []
    var loaded = false
}

/// A reorganization that can be undone: the copy of the branch kept before it.
struct GitRewriteBackup: Equatable, Sendable {
    var reference: String
    var branch: String
}
