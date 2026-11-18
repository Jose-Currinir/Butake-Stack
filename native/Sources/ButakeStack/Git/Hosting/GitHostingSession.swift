import SwiftUI

/// The pull requests of one open repository: which provider and account it uses, the list, the
/// one selected with its detail, the checks of the current branch and the provider's protection
/// of the primary branch. Reads happen when the Pull requests tab is shown (never at launch: a
/// token is read only when needed); every change on the provider is confirmed first by the view.
@MainActor @Observable final class GitHostingSession {
    /// What the tab can show for this repository.
    enum Availability: Equatable {
        /// The repository has no remote: «Publicar repositorio…».
        case noRemote
        /// The remote is not on GitHub or Bitbucket Cloud.
        case unsupported(remote: String)
        /// The provider is known but no account of it is connected: Ajustes › Cuentas.
        case noAccount(GitHostingProvider)
        case ready(GitHostedRepository, GitHostingAccount)
    }

    /// Which pull requests the list shows.
    enum Scope: String, CaseIterable, Identifiable {
        /// The open ones whose source is the current branch.
        case branch
        case open, merged, closed
        var id: String { rawValue }
        var title: String { L("git.pr.scope.\(rawValue)") }
    }

    /// Everything the detail shows of one pull request.
    struct Detail: Equatable {
        var comments: [GitPullRequestComment] = []
        var reviews: [GitPullRequestReview] = []
        var checks: [GitHostingCheck] = []
        /// Files from the local copies of both branches (`origin/…`); nil when they are not here yet.
        var files: [GitBranchComparison.File]?
    }

    let repository: GitRepository
    @ObservationIgnored let hosting: GitHosting

    var scope: Scope = .branch { didSet { if scope != oldValue { Task { await loadList() } } } }
    /// The latest list load: asking again cancels the one before, and an answer that is no longer
    /// the latest (another scope or branch) is dropped instead of overwriting the list on screen.
    @ObservationIgnored private var listTask: Task<Void, Never>?
    @ObservationIgnored private var listGeneration = 0
    private(set) var pullRequests: [GitPullRequest] = []
    /// The checks of the open pull requests on the list, by number.
    private(set) var listChecks: [Int: [GitHostingCheck]] = [:]
    private(set) var loading = false
    private(set) var loaded = false
    var failure: GitHostingFailure?
    var selected: Int? { didSet { if selected != oldValue { detail = nil; if selected != nil { Task { await loadDetail() } } } } }
    private(set) var detail: Detail?
    private(set) var loadingDetail = false
    /// «Nuevo pull request…» is on screen.
    var composing = false
    /// A change on the provider in progress (approve, comment, merge, create).
    private(set) var working = false
    /// The checks of the current branch's last commit, and which commit they belong to.
    private(set) var branchChecks: [GitHostingCheck] = []
    private(set) var branchChecksCommit: String?
    /// The open pull request of the current branch, when there is one.
    private(set) var branchPullRequest: GitPullRequest?

    init(repository: GitRepository, hosting: GitHosting) {
        self.repository = repository
        self.hosting = hosting
    }

    var availability: Availability {
        guard repository.snapshot.hasRemote, !remote.isEmpty else { return .noRemote }
        guard let hosted = hosting.hosted(remote) else { return .unsupported(remote: remote) }
        guard let account = hosting.account(for: hosted.provider) else { return .noAccount(hosted.provider) }
        return .ready(hosted, account)
    }

    /// `origin`'s address as written in the repository's configuration (Git's `insteadOf` rules
    /// may turn it into another one when it connects); the snapshot's until it is read.
    private var configuredRemote: String?
    var remote: String { configuredRemote ?? repository.snapshot.remote }
    var hosted: GitHostedRepository? { hosting.hosted(remote) }
    var selectedPullRequest: GitPullRequest? { pullRequests.first { $0.id == selected } }

    // MARK: Reading

    /// Reads `origin`'s configured address (without credentials: the engine filters them).
    func readRemote() async {
        let request: [String: Any] = ["method": "gitQuery", "path": repository.root, "args": ["config", "--get", "remote.origin.url"]]
        let value: String
        do {
            value = try await repository.store.call(request, as: String.self).trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            // Without `origin` Git answers with an error: the snapshot's (none) is right. Any other
            // failure keeps what was read before.
            if !repository.snapshot.hasRemote { configuredRemote = nil }
            return
        }
        // A password in the address is never kept (the engine already hides it; this is a second lock).
        // Any user in an https address counts: a token is often pasted as the user name.
        let withUser = value.range(of: #"^https?://[^/@]*@"#, options: .regularExpression) != nil
        configuredRemote = value.isEmpty || withUser ? nil : value
    }

    /// The list, the current branch's checks and the provider's protection, as the tab appears.
    func load() async {
        if !hosting.accountsLoaded { await hosting.loadAccounts() }
        await readRemote()
        guard case .ready = availability else { loaded = true; return }
        await loadList()
        await refreshBranchChecks()
        await syncProtection()
    }

    /// The provider asked to wait (rate limit): nothing is requested until then. Kept apart from
    /// `failure`, so a later, unrelated failure does not end the pause early.
    @ObservationIgnored private var retryAt: Date?
    private var pausedUntil: Date? {
        if let until = failure?.retryAfter, until > (retryAt ?? .distantPast) { retryAt = until }
        guard let until = retryAt, until > Date() else { return nil }
        return until
    }

    func loadList() async {
        listTask?.cancel()
        var latest = Task { await readList() }
        listTask = latest
        await latest.value
        // Superseded while waiting: this call returns once the list it was replaced by is there.
        while let next = listTask, next != latest { latest = next; await next.value }
    }

    private func readList() async {
        guard case .ready(let hosted, _) = availability, pausedUntil == nil else { return }
        // What this load asks is fixed now: the scope and the branch may change while it waits.
        listGeneration += 1
        let generation = listGeneration
        let scope = self.scope, branch = repository.snapshot.branch
        loading = true
        defer { if generation == listGeneration { loading = false }; loaded = true }
        do {
            let credentials = try await hosting.credentials(for: hosted.provider)
            let state: GitPullRequestState = switch scope { case .branch, .open: .open; case .merged: .merged; case .closed: .closed }
            var next = try await hosting.client.pullRequests(hosted, state: state, source: scope == .branch ? branch : nil, credentials: credentials)
            guard generation == listGeneration else { return }
            if scope == .branch { next = next.filter { $0.source == branch } }
            failure = nil
            if next != pullRequests { pullRequests = next }
            if let selected, !next.contains(where: { $0.id == selected }) { self.selected = nil }
            if selected == nil { selected = next.first?.id }
            await loadListChecks(next.filter { $0.state == .open }.prefix(10), hosted, credentials, generation: generation)
        } catch {
            guard generation == listGeneration, !Task.isCancelled else { return }
            fail(error)
        }
    }

    /// The checks of the first open pull requests of the list, read together (one request each).
    private func loadListChecks(_ pulls: ArraySlice<GitPullRequest>, _ hosted: GitHostedRepository, _ credentials: GitHostingCredentials,
                                  generation: Int) async {
        let client = hosting.client
        // At most three at a time: bursts of requests trip the providers' secondary limits.
        let found = await withTaskGroup(of: (Int, [GitHostingCheck]?).self) { group in
            var all: [Int: [GitHostingCheck]] = [:]
            var running = 0
            for pr in pulls {
                guard let head = pr.head else { continue }
                if running == 3, let (id, checks) = await group.next() { all[id] = checks; running -= 1 }
                group.addTask { (pr.id, try? await client.checks(hosted, commit: head, credentials: credentials)) }
                running += 1
            }
            for await (id, checks) in group { all[id] = checks }
            return all
        }
        if generation == listGeneration, found != listChecks { listChecks = found }
    }

    /// Checks of the current branch's last commit and its open pull request (for «Problemas»).
    func refreshBranchChecks() async {
        guard pausedUntil == nil else { return }
        guard case .ready(let hosted, _) = availability, !repository.snapshot.detached,
              let commit = repository.snapshot.headCommit?.hash else { branchChecks = []; branchChecksCommit = nil; return }
        do {
            let credentials = try await hosting.credentials(for: hosted.provider)
            let open = try await hosting.client.pullRequests(hosted, state: .open, source: repository.snapshot.branch, credentials: credentials)
            branchPullRequest = open.first { $0.source == repository.snapshot.branch }
            // Only a commit already on the provider has checks: the pushed one when the branch is ahead.
            let checks = try await hosting.client.checks(hosted, commit: branchPullRequest?.head ?? commit, credentials: credentials)
            branchChecks = checks
            branchChecksCommit = branchPullRequest?.head ?? commit
        } catch {
            // A failure here is not shown twice: the list already says it.
            branchChecks = []
            branchChecksCommit = nil
        }
    }

    /// Reads the provider's protection of the primary branch and keeps it in the repository
    /// (`gitSetRemoteProtection`): pushing to a protected `main` is then refused before Git runs.
    func syncProtection() async {
        guard pausedUntil == nil else { return }
        guard case .ready(let hosted, _) = availability, let credentials = try? await hosting.credentials(for: hosted.provider) else { return }
        let value: String
        switch await hosting.client.protection(hosted, branch: repository.snapshot.primaryBranch, credentials: credentials) {
        case .protected: value = "true"
        case .open: value = "false"
        case .unknown: value = "unknown"
        case .unreachable: return
        }
        _ = try? await repository.store.call(["method": "gitSetRemoteProtection", "path": repository.root, "value": value], as: String.self)
        await repository.refresh()
    }

    func loadDetail() async {
        guard case .ready(let hosted, _) = availability, let pr = selectedPullRequest else { return }
        loadingDetail = true
        defer { if selected == pr.id { loadingDetail = false } }
        do {
            let credentials = try await hosting.credentials(for: hosted.provider)
            var next = Detail()
            next.comments = try await hosting.client.comments(hosted, pr: pr.id, credentials: credentials)
            next.reviews = (try? await hosting.client.reviews(hosted, pr: pr.id, credentials: credentials)) ?? []
            if let head = pr.head { next.checks = (try? await hosting.client.checks(hosted, commit: head, credentials: credentials)) ?? [] }
            next.files = await files(of: pr)
            guard selected == pr.id else { return }
            detail = next
        } catch {
            // The error of a pull request that is no longer the selected one is not shown.
            guard selected == pr.id else { return }
            fail(error)
        }
    }

    /// The files the pull request changes, from the local copies of both branches (no extra request
    /// to the provider; the same for both). Nil when one of them was never fetched.
    private func files(of pr: GitPullRequest) async -> [GitBranchComparison.File]? {
        guard [pr.source, pr.target].allSatisfy({ !$0.hasPrefix("-") && !$0.contains("..") }) else { return nil }
        let range = "origin/\(pr.target)...origin/\(pr.source)"
        guard let text: String = try? await repository.store.call(["method": "gitQuery", "path": repository.root,
                                                                   "args": ["diff", "--numstat", "--no-renames", "--no-color", range]]) else { return nil }
        return text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 2).map(String.init)
            guard parts.count == 3 else { return nil }
            return GitBranchComparison.File(path: parts[2], additions: Int(parts[0]), deletions: Int(parts[1]))
        }
    }

    /// One file's changes in the pull request, as a patch for `GitDiffView`.
    func patch(of file: String, in pr: GitPullRequest) async -> String? {
        try? await repository.store.call(["method": "gitQuery", "path": repository.root,
                                          "args": ["diff", "--no-ext-diff", "--no-color", "origin/\(pr.target)...origin/\(pr.source)", "--", file]])
    }

    // MARK: Changes on the provider (each one already confirmed by the user)

    /// «Aprobar», «Combinar…» or a comment. Returns whether it worked.
    @discardableResult
    func act(_ action: Action, on pr: GitPullRequest) async -> Bool {
        guard case .ready(let hosted, _) = availability, !working else { return false }
        working = true
        defer { working = false }
        do {
            let credentials = try await hosting.credentials(for: hosted.provider)
            switch action {
            case .approve: try await hosting.client.approve(hosted, pr: pr.id, credentials: credentials)
            case .merge: try await hosting.client.merge(hosted, pr: pr.id, head: pr.head, credentials: credentials)
            case .comment(let text): try await hosting.client.comment(hosted, pr: pr.id, text: text, credentials: credentials)
            }
            repository.store.notify(action.done)
            if case .merge = action { await repository.perform(.fetch, notify: false) }
            await loadList()
            await loadDetail()
            return true
        } catch {
            fail(error)
            return false
        }
    }

    enum Action: Equatable {
        case approve, merge, comment(String)
        var done: String {
            switch self {
            case .approve: L("git.pr.done.approve")
            case .merge: L("git.pr.done.merge")
            case .comment: L("git.pr.done.comment")
            }
        }
    }

    /// «Crear pull request», confirmed: from the current branch into `target`.
    func create(title: String, body: String, target: String, draft: Bool) async -> Bool {
        guard case .ready(let hosted, _) = availability, !working else { return false }
        working = true
        defer { working = false }
        do {
            let credentials = try await hosting.credentials(for: hosted.provider)
            let created = try await hosting.client.createPullRequest(hosted, title: title, body: body, source: repository.snapshot.branch,
                                                                     target: target, draft: draft, credentials: credentials)
            repository.store.notify(String(format: L("git.pr.done.create"), created.id))
            scope = .branch
            await loadList()
            selected = created.id
            await refreshBranchChecks()
            return true
        } catch {
            fail(error)
            return false
        }
    }

    private func fail(_ error: Error) {
        guard !(error is CancellationError) else { return }
        failure = error as? GitHostingFailure ?? GitHostingFailure(.offline, provider: hosted?.provider)
    }
}
