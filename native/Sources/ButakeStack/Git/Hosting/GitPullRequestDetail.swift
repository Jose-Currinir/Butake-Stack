import SwiftUI

/// The selected pull request: its state and branches, checks, reviews, description, conversation
/// and files, with «Combinar…», «Aprobar…», a comment and the page on the provider. Joining and
/// approving ask first; joining with failed checks says so in the question.
struct GitPullRequestDetail: View {
    let repository: GitRepository

    var body: some View {
        let session = GitHosting.shared.session(for: repository)
        if case .ready = session.availability {
            if let pr = session.selectedPullRequest {
                GitPullRequestForm(session: session, pr: pr).id(pr.id)
            } else {
                ContentUnavailableView(L("git.pr.chooseTitle"), systemImage: Symbols.gitPullRequests, description: Text(L("git.pr.chooseDetail")))
            }
        } else {
            GitHostingMissing(session: session, compact: false)
        }
    }
}

private struct GitPullRequestForm: View {
    @Bindable var session: GitHostingSession
    let pr: GitPullRequest
    @State private var confirming: GitHostingSession.Action?
    @State private var comment = ""
    @State private var viewing: GitBranchComparison.File?

    private var detail: GitHostingSession.Detail? { session.detail }
    private var failing: Int { detail?.checks.filter { $0.state == .failure }.count ?? 0 }
    private var provider: GitHostingProvider { session.hosted?.provider ?? .github }

    var body: some View {
        Form {
            Section {
                LabeledContent(L("git.pr.field.state")) {
                    Label(pr.stateTitle, systemImage: pr.stateSymbol).foregroundStyle(pr.stateColor)
                }
                LabeledContent(L("git.pr.field.branches")) {
                    Text(String(format: L("git.pr.branches"), pr.source, pr.target)).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                }
                LabeledContent(L("git.pr.field.author"), value: pr.author)
                if let updated = pr.updated {
                    LabeledContent(L("git.pr.field.updated"), value: updated.formatted(.relative(presentation: .named)))
                }
            } header: {
                HStack(alignment: .firstTextBaseline) {
                    Text(String(format: L("git.pr.titleNumber"), pr.title, pr.id)).textSelection(.enabled).lineLimit(2)
                    Spacer()
                    actions
                }
            }
            if let failure = session.failure {
                Section { Notice(.error, failure.title, detail: failure.detail.isEmpty ? nil : failure.detail) }
            }
            checksSection
            if let reviews = detail?.reviews, !reviews.isEmpty {
                Section(L("git.pr.reviews")) {
                    ForEach(reviews) { review in
                        LabeledContent(review.author) {
                            Label(L("git.pr.review.\(review.verdict.rawValue)"), systemImage: review.verdict.symbol).foregroundStyle(review.verdict.color)
                        }
                    }
                }
            }
            Section(L("git.pr.description")) {
                if pr.body.isEmpty {
                    Text(L("git.pr.noDescription")).foregroundStyle(.secondary)
                } else {
                    GitMarkdownText(pr.body)
                }
            }
            conversationSection
            filesSection
        }
        .formStyle(.grouped)
        .themedScroll()
        .accessibilityIdentifier("git.pr.detail")
        .confirmationDialog(confirming == .merge ? String(format: L("git.pr.mergeTitle"), pr.id, pr.target) : String(format: L("git.pr.approveTitle"), pr.id),
                            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }), titleVisibility: .visible) {
            if confirming == .merge {
                Button(L("git.pr.mergeConfirm"), role: failing > 0 ? .destructive : nil) { run(.merge) }
                    .accessibilityIdentifier("git.pr.mergeConfirm")
            } else {
                Button(L("git.pr.approveConfirm")) { run(.approve) }.accessibilityIdentifier("git.pr.approveConfirm")
            }
            Button(L("common.cancel"), role: .cancel) {}.accessibilityIdentifier("git.pr.confirmCancel")
        } message: {
            Text(confirming == .merge
                 ? String(format: L("git.pr.mergeDetail"), pr.source, pr.target, provider.title) + (failing > 0 ? "\n\n" + String(format: L("git.pr.mergeWithFailures"), failing) : "")
                 : String(format: L("git.pr.approveDetail"), provider.title))
        }
        .sheet(item: $viewing) { file in GitPullRequestFileSheet(session: session, pr: pr, path: file.path).themedSheet() }
    }

    private func run(_ action: GitHostingSession.Action) {
        confirming = nil
        Task { await session.act(action, on: pr) }
    }

    @ViewBuilder private var actions: some View {
        if pr.state == .open {
            Button { confirming = .approve } label: { Label(L("git.pr.approveEllipsis"), systemImage: Symbols.gitApprove) }
                .buttonStyle(.bordered).controlSize(.small).disabled(session.working)
                .accessibilityIdentifier("git.pr.approve")
            Button { confirming = .merge } label: { Label(L("git.pr.mergeEllipsis"), systemImage: Symbols.gitMerge) }
                .buttonStyle(.borderedProminent).controlSize(.small).disabled(session.working || pr.draft)
                .help(pr.draft ? L("git.pr.draftHelp") : L("git.pr.mergeHelp"))
                .accessibilityIdentifier("git.pr.merge")
        }
        Button { GitHosting.shared.open(pr.page) } label: {
            Label(String(format: L("git.pr.openIn"), provider.title), systemImage: Symbols.openInBrowser).labelStyle(.iconOnly)
        }
        .buttonStyle(.borderless).disabled(pr.page == nil)
        .help(String(format: L("git.pr.openIn"), provider.title))
        .accessibilityIdentifier("git.pr.open")
    }

    @ViewBuilder private var checksSection: some View {
        Section {
            if let checks = detail?.checks {
                if checks.isEmpty {
                    Text(L("git.pr.checks.none")).foregroundStyle(.secondary)
                } else {
                    ForEach(checks.sorted { $0.state.order < $1.state.order }) { check in
                        LabeledContent {
                            HStack(spacing: 8) {
                                Text(L("git.pr.check.\(check.state.rawValue)")).foregroundStyle(.secondary)
                                if let page = check.page {
                                    Button { GitHosting.shared.open(page) } label: { Label(L("git.pr.check.open"), systemImage: Symbols.openInBrowser).labelStyle(.iconOnly) }
                                        .buttonStyle(.borderless).help(L("git.pr.check.open"))
                                        .accessibilityIdentifier("git.pr.check.open.\(check.id)")
                                }
                            }
                        } label: {
                            Label(check.name, systemImage: check.state.symbol).foregroundStyle(check.state.color)
                        }
                        .accessibilityIdentifier("git.pr.check.\(check.id)")
                    }
                }
            } else if session.loadingDetail {
                ProgressView().frame(maxWidth: .infinity)
            }
        } header: {
            Text(detail.flatMap { GitChecksSummary($0.checks)?.title } ?? L("git.pr.checks"))
        }
    }

    @ViewBuilder private var conversationSection: some View {
        Section(L("git.pr.conversation")) {
            ForEach(detail?.comments ?? []) { item in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(item.author).font(.uiHeadline)
                        if let created = item.created { Text(created.formatted(.relative(presentation: .named))).font(.uiCaption).foregroundStyle(.secondary) }
                        Spacer()
                        if let path = item.path {
                            Text(item.line.map { "\(path):\($0)" } ?? path).font(.uiCaption.monospaced()).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.head).help(path)
                        }
                    }
                    GitMarkdownText(item.body)
                }
                .padding(.vertical, 2)
            }
            VStack(alignment: .trailing, spacing: 8) {
                TextEditor(text: $comment)
                    .font(.uiBody).frame(minHeight: 60)
                    .scrollContentBackground(.hidden)
                    .accessibilityLabel(L("git.pr.commentPlaceholder"))
                    .accessibilityIdentifier("git.pr.commentText")
                    .overlay(alignment: .topLeading) {
                        if comment.isEmpty { Text(L("git.pr.commentPlaceholder")).foregroundStyle(.tertiary).padding(.leading, 5).allowsHitTesting(false) }
                    }
                Button {
                    let text = comment.trimmingCharacters(in: .whitespacesAndNewlines)
                    Task { if await session.act(.comment(text), on: pr) { comment = "" } }
                } label: { Label(L("git.pr.comment"), systemImage: Symbols.gitComment) }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || session.working)
                    .help(String(format: L("git.pr.commentHelp"), provider.title))
                    .accessibilityIdentifier("git.pr.sendComment")
            }
        }
    }

    @ViewBuilder private var filesSection: some View {
        Section(L("git.pr.files")) {
            if let files = detail?.files {
                if files.isEmpty { Text(L("git.pr.noFiles")).foregroundStyle(.secondary) }
                ForEach(files.prefix(300), id: \.path) { file in
                    LabeledContent {
                        HStack(spacing: 8) {
                            GitStatsBadge(stats: GitLineStats(additions: file.additions, deletions: file.deletions))
                            Button { viewing = file } label: { Label(L("git.pr.viewFile"), systemImage: Symbols.reveal).labelStyle(.iconOnly) }
                                .buttonStyle(.borderless).help(L("git.pr.viewFile"))
                                .accessibilityIdentifier("git.pr.file.\(file.path)")
                        }
                    } label: {
                        Label { Text(file.path).lineLimit(1).truncationMode(.middle).help(file.path) } icon: { FileTypeIcon(path: file.path, size: 16) }
                    }
                }
            } else if session.loadingDetail {
                ProgressView().frame(maxWidth: .infinity)
            } else {
                LabeledContent {
                    Button { Task { await session.repository.perform(.fetch); await session.loadDetail() } } label: {
                        Label(L("git.sync.fetch"), systemImage: Symbols.reload)
                    }
                    .buttonStyle(.bordered).disabled(session.repository.busy)
                    .accessibilityIdentifier("git.pr.files.fetch")
                } label: {
                    Text(String(format: L("git.pr.filesNeedFetch"), pr.source, pr.target)).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// One file of a pull request, its changes between both branches.
private struct GitPullRequestFileSheet: View {
    let session: GitHostingSession
    let pr: GitPullRequest
    let path: String
    @State private var content: GitDiffContent?

    var body: some View {
        SheetFrame(title: (path as NSString).lastPathComponent, symbol: Symbols.file, detail: path, width: 760, height: 560,
                   actionTitle: L("common.close"), actionID: "git.pr.file.close") { true } content: {
            Group {
                if let content { GitDiffView(content: content, path: path) } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task {
            let text = await session.patch(of: path, in: pr) ?? ""
            content = text.isEmpty ? .unchanged : .patch(text)
        }
    }
}

/// Text with the inline Markdown of the providers (bold, code, links), keeping line breaks.
struct GitMarkdownText: View {
    let source: String
    init(_ source: String) { self.source = source }
    var body: some View {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        Text((try? AttributedString(markdown: source, options: options)) ?? AttributedString(source))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension GitHostingCheck.State {
    /// Failed first, then running, passed and skipped.
    var order: Int { switch self { case .failure: 0; case .pending: 1; case .success: 2; case .skipped: 3 } }
    var symbol: String {
        switch self {
        case .success: Symbols.success
        case .failure: Symbols.gitCheckFailed
        case .pending: Symbols.gitCheckRunning
        case .skipped: Symbols.gitCheckSkipped
        }
    }
    @MainActor var color: Color {
        switch self {
        case .success: Brand.success
        case .failure: Brand.danger
        case .pending: Brand.warning
        case .skipped: .secondary
        }
    }
}

extension GitPullRequestReview.Verdict {
    var symbol: String {
        switch self {
        case .approved: Symbols.success
        case .changesRequested: Symbols.gitChangesRequested
        case .commented: Symbols.gitComment
        }
    }
    @MainActor var color: Color {
        switch self {
        case .approved: Brand.success
        case .changesRequested: Brand.warning
        case .commented: .secondary
        }
    }
}

extension GitBranchComparison.File: Identifiable {
    var id: String { path }
}
