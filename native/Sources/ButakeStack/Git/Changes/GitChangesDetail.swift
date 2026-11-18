import AppKit
import SwiftUI

/// Cambios' detail: the selected file's diff, with «Preparar bloque» on each block of its unstaged
/// part. A file with a staged and an unstaged part says which one is on screen and switches.
struct GitChangesDetail: View {
    @Bindable var repository: GitRepository

    var body: some View {
        if let file = repository.file {
            VStack(spacing: 0) {
                header(file)
                Divider()
                if let diff = repository.diff {
                    GitDiffView(content: diff, path: file.path,
                                onStageHunk: repository.diffIsStaged || file.newInParts || file.conflicted || repository.busy ? nil : { repository.stageHunk($0) })
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .accessibilityIdentifier("git.changes.detail")
        } else if repository.files.isEmpty {
            ContentUnavailableView {
                Label(L("git.changes.cleanTitle"), systemImage: Symbols.success)
            } description: {
                Text(String(format: L("git.changes.cleanDetail"), repository.branchTitle))
            }
            .accessibilityIdentifier("git.changes.clean")
        } else {
            ContentUnavailableView(L("git.changes.chooseTitle"), systemImage: Symbols.gitChanges, description: Text(L("git.changes.chooseDetail")))
        }
    }

    private func header(_ file: GitFile) -> some View {
        HStack(spacing: 8) {
            FileTypeIcon(path: file.path, size: 18)
            Text(file.path).font(.uiCallout.weight(.medium)).lineLimit(1).truncationMode(.middle).help(file.path).textSelection(.enabled)
            GitChangeKindBadge(kind: file.kind)
            Spacer(minLength: 8)
            if file.hasStaged && file.hasUnstaged {
                Picker(L("git.diff.partLabel"), selection: $repository.showStaged) {
                    Text(L("git.diff.unstagedPart")).tag(false)
                    Text(L("git.diff.stagedPart")).tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .help(L("git.diff.partHelp"))
                .accessibilityIdentifier("git.diff.part")
            }
            let stats = repository.stats(file)
            if !stats.isEmpty { GitStatsBadge(stats: stats) }
            Button { repository.discarding = [file] } label: { Label(L("git.discard.ellipsis"), systemImage: Symbols.gitDiscard) }
                .buttonStyle(.bordered)
                .disabled(!file.hasUnstaged || repository.busy)
                .help(L(file.untracked ? "git.discard.untrackedHelp" : "git.discard.help"))
                .accessibilityIdentifier("git.diff.discard")
        }
        .padding(.horizontal, 14).frame(minHeight: 42)
    }
}

extension View {
    /// «Descartar cambios», confirmed: what goes away and that it can't be undone.
    func gitDiscardConfirmation(repository: GitRepository) -> some View {
        let files = repository.discarding ?? []
        let untracked = files.contains(where: \.untracked)
        let title = files.count == 1 ? String(format: L("git.discard.oneTitle"), files[0].path) : String(format: L("git.discard.manyTitle"), files.count)
        return confirmationDialog(title, isPresented: Binding(get: { repository.discarding != nil }, set: { if !$0 { repository.discarding = nil } })) {
            Button(L("git.discard.confirm"), role: .destructive) { Task { await repository.discard(files) } }
                .accessibilityIdentifier("git.discard.confirm")
            Button(L("common.cancel"), role: .cancel) {}.accessibilityIdentifier("git.changes.discardCancel")
        } message: {
            Text(L(untracked ? "git.discard.untrackedDetail" : "git.discard.detail"))
        }
    }
}
