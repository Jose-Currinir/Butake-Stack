import SwiftUI

/// Pull requests in the content column: the current branch's or the repository's (open, joined,
/// closed), each with its state and its checks; «Nuevo pull request…» at the foot. Without a
/// remote, a provider or an account the column only names what is missing: the detail explains
/// it and has the button.
struct GitPullRequestsList: View {
    let repository: GitRepository

    var body: some View {
        let session = GitHosting.shared.session(for: repository)
        GitPullRequestsColumn(session: session)
            .task(id: "\(repository.root)|\(repository.snapshot.remote)|\(GitHosting.shared.accounts.count)") { await session.load() }
    }
}

private struct GitPullRequestsColumn: View {
    @Bindable var session: GitHostingSession
    @State private var search = ""

    private var shown: [GitPullRequest] {
        session.pullRequests.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || "#\($0.id)".contains(search)
            || $0.author.localizedCaseInsensitiveContains(search) || $0.source.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        switch session.availability {
        case .ready:
            VStack(spacing: 0) {
                Picker(L("git.pr.scope.label"), selection: $session.scope) {
                    ForEach(GitHostingSession.Scope.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden().pickerStyle(.menu)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .help(L("git.pr.scope.help"))
                .accessibilityIdentifier("git.pr.scope")
                Divider()
                list
                footer
            }
            .sheet(isPresented: $session.composing) { GitPullRequestSheet(session: session).themedSheet() }
        default:
            GitHostingMissing(session: session, compact: true)
        }
    }

    private var list: some View {
        List(selection: $session.selected) {
            ForEach(shown) { pr in
                GitPullRequestRow(pr: pr, checks: session.listChecks[pr.id]).tag(pr.id)
            }
        }
        .listStyle(.sidebar)
        .themedScroll()
        .searchable(text: $search, placement: .sidebar, prompt: L("git.pr.search"))
        .overlay {
            if session.loading && session.pullRequests.isEmpty {
                ProgressView()
            } else if let failure = session.failure, session.pullRequests.isEmpty {
                ContentUnavailableView(failure.title, systemImage: Symbols.warning, description: Text(failure.detail))
            } else if shown.isEmpty, session.loaded {
                if search.isEmpty {
                    ContentUnavailableView(L("git.pr.empty.\(session.scope.rawValue)"), systemImage: Symbols.gitPullRequests,
                                           description: Text(session.scope == .branch ? String(format: L("git.pr.empty.branchDetail"), session.repository.branchTitle) : ""))
                } else {
                    ContentUnavailableView.search(text: search)
                }
            }
        }
        .accessibilityIdentifier("git.pr.list")
    }

    private var footer: some View {
        HStack {
            Button { session.composing = true } label: { Label(L("git.pr.newEllipsis"), systemImage: Symbols.gitNewPullRequest) }
                .buttonStyle(.borderless)
                .disabled(session.working || session.repository.snapshot.detached || session.repository.snapshot.branch == session.repository.snapshot.primaryBranch)
                .help(L("git.pr.newHelp"))
                .accessibilityIdentifier("git.pr.new")
            Spacer()
            Button { Task { await session.loadList() } } label: { Label(L("git.pr.reload"), systemImage: Symbols.reload).labelStyle(.iconOnly) }
                .buttonStyle(.borderless).disabled(session.loading)
                .help(L("git.pr.reload"))
                .accessibilityIdentifier("git.pr.reload")
        }
        .padding(.horizontal, 10).frame(height: 29)
        .overlay(alignment: .top) { Divider() }
    }
}

/// A pull request: its state, title, number, author and branches, and how its checks are going.
private struct GitPullRequestRow: View {
    let pr: GitPullRequest
    let checks: [GitHostingCheck]?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: pr.stateSymbol).foregroundStyle(pr.stateColor).frame(width: 18).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(pr.title).font(.uiBody).lineLimit(2)
                Text(String(format: L("git.pr.rowDetail"), pr.id, pr.author, pr.source)).font(.uiCaption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 4)
            if let checks, let summary = GitChecksSummary(checks) {
                Image(systemName: summary.symbol).foregroundStyle(summary.color).help(summary.title)
                    .accessibilityLabel(summary.title)
            }
        }
        .padding(.vertical, 2)
        .help("\(pr.title) · \(pr.source) → \(pr.target)")
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("git.pr.row.\(pr.id)")
    }
}

/// How the checks of a commit are going, in one line.
struct GitChecksSummary {
    let title: String
    let symbol: String
    let color: Color

    /// Nil when there are no checks.
    @MainActor init?(_ checks: [GitHostingCheck]) {
        guard !checks.isEmpty else { return nil }
        let failed = checks.filter { $0.state == .failure }.count
        let running = checks.filter { $0.state == .pending }.count
        if failed > 0 {
            title = failed == 1 ? L("git.pr.checks.oneFailed") : String(format: L("git.pr.checks.someFailed"), failed)
            symbol = Symbols.gitCheckFailed; color = Brand.danger
        } else if running > 0 {
            title = String(format: L("git.pr.checks.running"), running)
            symbol = Symbols.gitCheckRunning; color = Brand.warning
        } else {
            title = L("git.pr.checks.passed")
            symbol = Symbols.success; color = Brand.success
        }
    }
}

extension GitPullRequest {
    var stateSymbol: String {
        if draft && state == .open { return Symbols.gitDraft }
        switch state {
        case .open: return Symbols.gitPullRequests
        case .merged: return Symbols.gitMerge
        case .closed: return Symbols.gitClosed
        }
    }
    @MainActor var stateColor: Color {
        if draft && state == .open { return .secondary }
        switch state {
        case .open: return Brand.success
        case .merged: return Brand.special
        case .closed: return Brand.danger
        }
    }
    var stateTitle: String { draft && state == .open ? L("git.pr.state.draft") : state.title }
}

/// What the tab needs before it can show pull requests, and the button that gets it: publish the
/// repository, use a remote of GitHub or Bitbucket, or connect an account. Compact in the content
/// column (just what is missing), complete in the detail.
struct GitHostingMissing: View {
    let session: GitHostingSession
    let compact: Bool

    var body: some View {
        switch session.availability {
        case .noRemote:
            unavailable("git.pr.missing.noRemote", Symbols.gitPublishRepository, L("git.pr.missing.noRemoteDetail")) {
                Button { GitHosting.shared.publishing = true } label: { Label(L("git.publish.titleEllipsis"), systemImage: Symbols.gitPublishRepository) }
                    .buttonStyle(.borderedProminent).accessibilityIdentifier("git.pr.missing.publish")
            }
        case .unsupported(let remote):
            unavailable("git.pr.missing.unsupported", Symbols.gitPullRequests, String(format: L("git.pr.missing.unsupportedDetail"), remote)) { EmptyView() }
        case .noAccount(let provider):
            unavailable(String(format: L("git.pr.missing.noAccount"), provider.title), Symbols.gitAccounts,
                        String(format: L("git.pr.missing.noAccountDetail"), provider.title), literal: true) {
                Button { SettingsRouter.shared.open(.accounts) } label: { Label(L("git.pr.missing.openAccounts"), systemImage: Symbols.settings) }
                    .buttonStyle(.borderedProminent).accessibilityIdentifier("git.pr.missing.accounts")
            }
        case .ready:
            EmptyView()
        }
    }

    @ViewBuilder
    private func unavailable(_ title: String, _ symbol: String, _ detail: String, literal: Bool = false, @ViewBuilder actions: () -> some View) -> some View {
        let text = literal ? title : L(title)
        if compact {
            ContentUnavailableView(text, systemImage: symbol).accessibilityIdentifier("git.pr.missing")
        } else {
            ContentUnavailableView {
                Label(text, systemImage: symbol)
            } description: {
                Text(detail)
            } actions: {
                actions()
            }
            .accessibilityIdentifier("git.pr.missing.detail")
        }
    }
}
