import SwiftUI

/// Historial, across the top of the detail: the branch's commits with a simple graph, author, relative date
/// and the marks of branches and tags; a search with scopes (message, author, file, date,
/// identifier, content); pages at the end; «Organizar commits…», «Sincronizar ramas…» and «Más…» at
/// the foot. A reorganization offers «Deshacer» on top while it can be undone.
struct GitHistoryList: View {
    @Bindable var repository: GitRepository
    @Bindable var work = GitWork.shared
    @AppStorage("git.history.onlyBranch") private var onlyBranch = true

    var body: some View {
        let history = repository.history
        VStack(spacing: 0) {
            if let backup = history.lastBackup, backup.branch == repository.snapshot.branch {
                undoBanner
                Divider()
            }
            Group {
                if history.matches != nil {
                    GitContentMatchList(history: history)
                } else {
                    GitCommitList(repository: repository, history: history)
                }
            }
            .frame(maxHeight: .infinity)
            .safeAreaInset(edge: .top, spacing: 0) {
                // The scopes of the search, always visible (DISENO.md, «Búsquedas»).
                HStack(spacing: 6) {
                    Picker(L("git.history.searchIn"), selection: Bindable(history).scope) {
                        ForEach(GitHistorySearchScope.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.menu).fixedSize()
                    .help(L("git.history.searchInHelp"))
                    .accessibilityIdentifier("git.history.scope")
                    Spacer(minLength: 0)
                    if history.searching { ProgressView().controlSize(.small) }
                }
                .padding(.horizontal, 12).padding(.bottom, 6)
            }
            .searchable(text: Bindable(history).search, placement: .sidebar, prompt: history.scope.prompt)
            .searchSuggestions {
                ForEach(history.suggestions, id: \.self) { Text($0).searchCompletion($0) }
            }
            footer
        }
        .gitWorkDialogs(repository: repository)
        .task(id: "\(repository.snapshot.headCommit?.hash ?? "")|\(repository.snapshot.branch)|\(repository.historyLimit)|\(onlyBranch)") {
            history.onlyBranch = onlyBranch
            await history.reloadBranch()
            if history.selected == nil { history.selected = history.commits.first?.hash }
        }
        .task(id: history.scope) { if history.scope == .file || history.scope == .content { await history.loadPaths() } }
    }

    private var undoBanner: some View {
        HStack(spacing: 8) {
            Label(L("git.history.rewritten"), systemImage: Symbols.gitOrganize).font(.uiCallout)
            Spacer(minLength: 4)
            Button { Task { await repository.undoRewrite() } } label: { Label(L("git.history.undoRewrite"), systemImage: Symbols.gitUndoCommit) }
                .buttonStyle(.bordered).controlSize(.small).disabled(repository.busy)
                .help(L("git.history.undoRewriteHelp"))
                .accessibilityIdentifier("git.history.undoRewrite")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private var footer: some View {
        HStack(spacing: 4) {
            Toggle(isOn: $onlyBranch) { Text(L("git.history.onlyBranch")) }
                .toggleStyle(.checkbox).controlSize(.small)
                .help(L("git.history.onlyBranchHelp"))
                .accessibilityIdentifier("git.history.onlyBranch")
            Spacer(minLength: 4)
            Menu {
                Button { work.organizing = true } label: { Label(L("git.organize.titleEllipsis"), systemImage: Symbols.gitOrganize) }
                    .disabled(repository.busy || repository.snapshot.detached)
                    .accessibilityIdentifier("git.history.organize")
                Button { work.syncingBranches = true } label: { Label(L("git.syncBranches.titleEllipsis"), systemImage: Symbols.gitSyncBranches) }
                    .disabled(repository.busy)
                    .accessibilityIdentifier("git.history.syncBranches")
                Divider()
                Button { work.more = true } label: { Label(L("git.more.titleEllipsis"), systemImage: Symbols.more) }
                    .accessibilityIdentifier("git.history.more")
                GitAssistantMenu(directory: repository.root, suffix: "history")
            } label: {
                Label(L("git.history.tools"), systemImage: Symbols.more)
            }
            .menuStyle(.borderlessButton).fixedSize()
            .help(L("git.history.toolsHelp"))
            .accessibilityIdentifier("git.history.tools")
        }
        .padding(.horizontal, 10).frame(height: 29)
        .overlay(alignment: .top) { Divider() }
    }
}

/// The commits: graph, subject, marks, author and date; «Cargar más» at the end.
private struct GitCommitList: View {
    let repository: GitRepository
    @Bindable var history: GitHistory

    var body: some View {
        let commits = history.commits
        let locals = Set(repository.snapshot.branches.map(\.name))
        let graph = history.searchingCommits ? nil : history.graph(commits, localBranches: locals)
        List(selection: $history.selected) {
            if !commits.isEmpty {
                GitCommitColumns(graphWidth: graph.map { GitCommitGraphCell.width(lanes: $0.width, lane: GitCommitGraphCell.laneWidth(lanes: $0.width)) })
                    .listRowInsets(EdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 8))
                    .selectionDisabled()
            }
            ForEach(Array(commits.enumerated()), id: \.element.hash) { index, commit in
                GitCommitRow(commit: commit, row: graph?.rows[safe: index], lanes: graph?.width, localBranches: locals,
                             selected: history.selected == commit.hash)
                    .tag(commit.hash)
                    .listRowInsets(EdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 8))
                    .contextMenu { GitCommitMenu(repository: repository, commit: commit) }
            }
            if history.canLoadMore {
                Button { Task { await history.loadMore() } } label: {
                    Label(L(history.loadingMore ? "git.history.loading" : "git.history.loadMore"), systemImage: Symbols.gitLoadMore)
                }
                .buttonStyle(.bordered).controlSize(.small).disabled(history.loadingMore)
                .frame(maxWidth: .infinity).padding(.vertical, 6)
                .accessibilityIdentifier("git.history.loadMore")
                .selectionDisabled()
            }
        }
        .listStyle(.sidebar)
        .environment(\.defaultMinListRowHeight, GitCommitRow.height)
        .themedScroll()
        .accessibilityIdentifier("git.history.list")
        .overlay {
            if history.searching && commits.isEmpty {
                ProgressView()
            } else if commits.isEmpty {
                if !history.search.isEmpty {
                    ContentUnavailableView {
                        Label(L("git.history.noResults"), systemImage: Symbols.search)
                    } description: {
                        Text(history.searchNote ?? String(format: L("git.history.noResultsDetail"), history.search))
                    }
                } else {
                    ContentUnavailableView(L("git.history.emptyTitle"), systemImage: Symbols.gitHistory, description: Text(L("git.history.emptyDetail")))
                }
            }
        }
    }
}

/// A commit, one line across the detail: its lane of the graph, the marks of its branches and tags,
/// the subject and, in columns, identifier, author and date. Every row is equally tall, so the
/// graph's lanes join from one row to the next; a graph with many lanes narrows them.
struct GitCommitRow: View {
    @MainActor static var height: CGFloat { TextScale.points(26) }
    /// Widths of the columns after the description, shared with the header.
    @MainActor static var hashWidth: CGFloat { TextScale.points(70) }
    @MainActor static var authorWidth: CGFloat { TextScale.points(124) }
    @MainActor static var dateWidth: CGFloat { TextScale.points(150) }
    let commit: GitCommitSummary
    let row: GitGraphRow?
    let lanes: Int?
    let localBranches: Set<String>
    let selected: Bool

    var body: some View {
        HStack(spacing: 8) {
            if let row {
                GitCommitGraphCell(row: row, selected: selected, lanes: lanes,
                                   laneWidth: GitCommitGraphCell.laneWidth(lanes: lanes ?? row.laneCount))
                    .frame(height: Self.height)
            }
            HStack(spacing: 6) {
                let references = GitCommitReference.parse(commit.refs, localBranches: localBranches)
                ForEach(references.prefix(2)) { GitReferenceMark(reference: $0).frame(maxWidth: TextScale.points(130), alignment: .leading) }
                if references.count > 2 {
                    Text(verbatim: "+\(references.count - 2)").font(.uiCaption).foregroundStyle(.secondary).fixedSize()
                        .help(references.dropFirst(2).map(\.name).joined(separator: ", "))
                }
                Text(commit.subject).font(.uiBody).lineLimit(1).truncationMode(.tail).layoutPriority(1)
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading).clipped()
            Group {
                Text(commit.hash.prefix(8)).font(.uiCaption.monospaced()).frame(width: Self.hashWidth, alignment: .leading)
                Text(commit.author).frame(width: Self.authorWidth, alignment: .leading)
                Text(commit.date.map { $0.formatted(date: .numeric, time: .shortened) } ?? "").frame(width: Self.dateWidth, alignment: .leading)
            }
            .font(.uiCallout).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(height: Self.height)
        .help("\(commit.subject)\n\(commit.hash.prefix(10)) · \(commit.author)")
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("git.history.row.\(commit.hash.prefix(7))")
    }
}

/// The titles over the commits' columns.
struct GitCommitColumns: View {
    /// The graph's column in the rows under it.
    var graphWidth: CGFloat?
    var body: some View {
        HStack(spacing: 8) {
            if let graphWidth { Color.clear.frame(width: graphWidth, height: 1) }
            Text(L("git.history.column.description")).frame(maxWidth: .infinity, alignment: .leading)
            Text(L("git.history.column.commit")).frame(width: GitCommitRow.hashWidth, alignment: .leading)
            Text(L("git.history.column.author")).frame(width: GitCommitRow.authorWidth, alignment: .leading)
            Text(L("git.history.column.date")).frame(width: GitCommitRow.dateWidth, alignment: .leading)
        }
        .font(.uiCaption.weight(.medium)).foregroundStyle(.secondary).lineLimit(1)
        .frame(height: GitCommitRow.height)
        .accessibilityHidden(true)
    }
}

/// A branch, remote branch or tag on a commit.
struct GitReferenceMark: View {
    let reference: GitCommitReference
    var body: some View {
        let (symbol, color): (String, Color) = switch reference.kind {
        case .head: (Symbols.selected, Brand.success)
        case .branch: (Symbols.git, Brand.info)
        case .remote: (Symbols.cloud, .secondary)
        case .tag: (Symbols.tags, Brand.warning)
        }
        Label(reference.name, systemImage: symbol)
            .font(.uiCaption).foregroundStyle(color).lineLimit(1)
            .help(L("git.history.ref.\(reference.kind)") + ": " + reference.name)
    }
}

/// The lines of the files that contain the text («Contenido»).
private struct GitContentMatchList: View {
    @Bindable var history: GitHistory

    var body: some View {
        let matches = history.matches ?? []
        List(matches, selection: $history.selectedMatch) { match in
            HStack(spacing: 7) {
                FileTypeIcon(path: match.path, size: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(match.text).font(.uiBody.monospaced()).lineLimit(1)
                    Text(String(format: L("git.history.matchPlace"), match.path, match.line)).font(.uiCaption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            .help(match.path)
            .tag(match.id)
            .accessibilityIdentifier("git.history.match.\(match.id)")
        }
        .listStyle(.sidebar)
        .themedScroll()
        .accessibilityIdentifier("git.history.matches")
        .overlay {
            if history.searching && matches.isEmpty {
                ProgressView()
            } else if matches.isEmpty {
                ContentUnavailableView {
                    Label(L("git.history.noResults"), systemImage: Symbols.search)
                } description: {
                    Text(history.searchNote ?? String(format: L("git.history.noContentDetail"), history.search))
                }
            }
        }
    }
}
