import SwiftUI

/// Historial's detail: the selected commit (message, author, date, identifier, parents and its
/// actions) with a card per changed file; or, for a «Contenido» search, the file of the line found.
struct GitHistoryDetail: View {
    @Bindable var repository: GitRepository

    var body: some View {
        let history = repository.history
        if history.matches != nil {
            if let match = history.selectedMatchItem {
                GitFilePreview(repository: repository, path: match.path, line: match.line)
            } else {
                ContentUnavailableView(L("git.history.chooseMatchTitle"), systemImage: Symbols.search, description: Text(L("git.history.chooseMatchDetail")))
            }
        } else if let commit = history.selectedCommit {
            GitCommitDetailView(repository: repository, commit: commit, detail: history.detail)
        } else {
            ContentUnavailableView(L("git.history.chooseTitle"), systemImage: Symbols.gitHistory, description: Text(L("git.history.chooseDetail")))
        }
    }
}

private struct GitCommitDetailView: View {
    let repository: GitRepository
    let commit: GitCommitSummary
    let detail: GitCommitDetail?
    @State private var collapsed: Set<Int> = []

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let detail, detail.loaded, detail.hash == commit.hash {
                if detail.sections.isEmpty {
                    ContentUnavailableView(L("git.history.noFilesTitle"), systemImage: Symbols.noChanges, description: Text(L("git.history.noFilesDetail")))
                } else {
                    GitDiffSectionsView(sections: detail.sections, collapsed: collapsed) { id in
                        if collapsed.contains(id) { collapsed.remove(id) } else { collapsed.insert(id) }
                    }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onChange(of: commit.hash) { collapsed = [] }
        .accessibilityIdentifier("git.history.detail")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(commit.subject).font(.uiTitle3.weight(.semibold)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let body = detail?.body, detail?.hash == commit.hash, !body.isEmpty {
                Text(body).font(.uiBody).foregroundStyle(.secondary).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).lineLimit(12)
            }
            HStack(spacing: 14) {
                Label(commit.author, systemImage: Symbols.user)
                if let date = commit.date {
                    Label(date.formatted(date: .abbreviated, time: .shortened), systemImage: Symbols.gitHistory)
                        .help(date.formatted(.relative(presentation: .named)))
                }
                Label(String(commit.hash.prefix(10)), systemImage: Symbols.git).font(.uiCaption.monospaced()).help(commit.hash)
                if commit.parents.count > 1 { Text(L("git.history.mergeCommit")) }
                let refs = GitCommitReference.parse(commit.refs, localBranches: Set(repository.snapshot.branches.map(\.name)))
                ForEach(refs.prefix(4)) { GitReferenceMark(reference: $0) }
            }
            .font(.uiCaption).foregroundStyle(.secondary).lineLimit(1)
            GitCommitActions(repository: repository, commit: commit)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
    }
}

/// The commit's actions as buttons with icon and text (the same as its context menu).
private struct GitCommitActions: View {
    let repository: GitRepository
    let commit: GitCommitSummary

    var body: some View {
        let work = GitWork.shared
        let blocked = repository.busy || !repository.snapshot.operation.isEmpty
        let targets = repository.localBranches.map(\.name).filter { $0 != repository.snapshot.branch }
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { buttons(work: work, blocked: blocked, targets: targets) }
            VStack(alignment: .leading, spacing: 6) { buttons(work: work, blocked: blocked, targets: targets) }
        }
        .controlSize(.small)
    }

    @ViewBuilder private func buttons(work: GitWork, blocked: Bool, targets: [String]) -> some View {
        Button { work.reverting = commit } label: { Label(L("git.history.revertEllipsis"), systemImage: Symbols.gitRevert) }
            .buttonStyle(.bordered)
            .disabled(blocked || commit.parents.count != 1 || repository.snapshot.detached)
            .help(L(commit.parents.count > 1 ? "git.history.revertMergeHelp" : "git.history.revertHelp"))
            .accessibilityIdentifier("git.history.detail.revert")
        Menu {
            ForEach(targets, id: \.self) { target in
                Button(target) { work.copying = GitCopyRequest(hashes: [commit.hash], title: commit.subject, target: target) }.accessibilityIdentifier("git.history.copyTo.\(target)")
            }
        } label: {
            Label(L("git.history.copyTo"), systemImage: Symbols.gitCopyCommits)
        }
        .menuStyle(.button).buttonStyle(.bordered).fixedSize()
        .disabled(blocked || targets.isEmpty || commit.parents.count > 1)
        .help(L("git.history.copyToHelp"))
        .accessibilityIdentifier("git.history.detail.copyTo")
        Button { work.naming = GitNameRequest(kind: .branch, commit: commit) } label: {
            Label(L("git.history.branchHereEllipsis"), systemImage: Symbols.gitNewBranch)
        }
        .buttonStyle(.bordered).disabled(repository.busy)
        .accessibilityIdentifier("git.history.detail.branch")
        Button { work.naming = GitNameRequest(kind: .tag, commit: commit) } label: { Label(L("git.history.tagEllipsis"), systemImage: Symbols.tags) }
            .buttonStyle(.bordered).disabled(repository.busy)
            .accessibilityIdentifier("git.history.detail.tag")
        Button { repository.copyIdentifier(commit.hash) } label: { Label(L("git.history.copyHash"), systemImage: Symbols.copy) }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("git.history.detail.copyHash")
    }
}

/// A file of the repository, read only: «Contenido» and the files of «Más…».
struct GitFilePreview: View {
    let repository: GitRepository
    let path: String
    var line: Int?
    @State private var text = ""
    @State private var failure: String?
    @State private var loading = true

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                FileTypeIcon(path: path, size: 18)
                Text(path).font(.uiCallout.weight(.medium)).lineLimit(1).truncationMode(.middle).help(path).textSelection(.enabled)
                Spacer(minLength: 8)
                if let line { Text(String(format: L("git.history.line"), line)).font(.uiCaption).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 14).frame(minHeight: 42)
            Divider()
            if loading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let failure {
                ContentUnavailableView(L("git.files.cantPreview"), systemImage: Symbols.binaryFile, description: Text(failure))
            } else {
                CodeEditor(text: .constant(text), path: path, editable: false)
            }
        }
        .task(id: path) {
            loading = true
            defer { loading = false }
            do {
                let value: GitFileContent = try await repository.store.call(["method": "gitReadFile", "path": repository.root, "file": path])
                text = value.content
                failure = nil
            } catch {
                failure = GitFailure(error).detail.isEmpty ? GitFailure(error).title : GitFailure(error).detail
            }
        }
        .accessibilityIdentifier("git.files.preview")
    }
}

/// The answer of `gitReadFile`.
struct GitFileContent: Decodable, Sendable {
    var content: String
}
