import SwiftUI

/// The commit box at the foot of Cambios: summary (required), description, «Corregir el último
/// commit» and «Confirmar en ‹rama›» (⌘↩). Under it, «Deshacer el último commit» while that commit
/// is only on this Mac. The text survives refreshes and changing files; it clears once confirmed.
struct GitCommitBox: View {
    @Bindable var repository: GitRepository
    @State private var summary = ""
    @State private var details = ""
    @State private var amend = false
    @State private var undoing = false
    @FocusState private var summaryFocused: Bool

    private var included: Int { repository.stagedFiles.count }
    private var canCommit: Bool {
        !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !repository.busy && repository.conflicts.isEmpty
            && (amend || included > 0) && !repository.snapshot.onProtectedMain
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if repository.snapshot.onProtectedMain {
                Label(String(format: L("git.commit.protected"), repository.snapshot.primaryBranch), systemImage: Symbols.locked)
                    .font(.uiCaption).foregroundStyle(.secondary)
                    .help(L("git.commit.protectedHelp"))
            }
            TextField(L("git.commit.summary"), text: $summary)
                .textFieldStyle(.roundedBorder)
                .focused($summaryFocused)
                .accessibilityIdentifier("git.commit.summary")
            TextField(L("git.commit.description"), text: $details, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...5)
                .accessibilityIdentifier("git.commit.description")
            Toggle(L("git.commit.amend"), isOn: $amend)
                .toggleStyle(.checkbox)
                .disabled(!repository.canUndoCommit)
                .help(L(repository.canUndoCommit ? "git.commit.amendHelp" : "git.commit.amendUnavailable"))
                .accessibilityIdentifier("git.commit.amend")
            Button { Task { await commit() } } label: {
                Label(String(format: L(amend ? "git.commit.amendButton" : "git.commit.button"), repository.branchTitle), systemImage: Symbols.gitCommit)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!canCommit)
            .help(help)
            .accessibilityIdentifier("git.commit.confirm")
            if repository.canUndoCommit, let head = repository.snapshot.headCommit {
                HStack(spacing: 6) {
                    Text(String(format: L("git.commit.last"), head.subject)).font(.uiCaption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.tail).help(head.subject)
                    Spacer(minLength: 4)
                    Button { undoing = true } label: { Label(L("git.commit.undoShort"), systemImage: Symbols.gitUndoCommit) }
                        .buttonStyle(.bordered).controlSize(.small)
                        .disabled(repository.busy)
                        .help(L("git.commit.undoHelp"))
                        .accessibilityIdentifier("git.commit.undo")
                }
            }
        }
        .padding(12)
        .onChange(of: amend) {
            // Correcting starts from the last commit's subject when nothing was written.
            if amend, summary.isEmpty { summary = repository.snapshot.headCommit?.subject ?? "" }
        }
        .confirmationDialog(L("git.commit.undoTitle"), isPresented: $undoing) {
            Button(L("git.commit.undo")) { Task { await undo() } }
                .accessibilityIdentifier("git.commit.undoConfirm")
            Button(L("common.cancel"), role: .cancel) {}.accessibilityIdentifier("git.commit.confirmCancel")
        } message: {
            Text(L("git.commit.undoDetail"))
        }
        #if DEBUG
        .task { if let text = GitQA.commitSummary { summary = text } }
        #endif
    }

    private var help: String {
        if repository.snapshot.onProtectedMain { return L("git.commit.protectedHelp") }
        if !repository.conflicts.isEmpty { return L("git.commit.conflictsHelp") }
        if !amend && included == 0 { return L("git.commit.nothingHelp") }
        if summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return L("git.commit.summaryHelp") }
        return String(format: L("git.commit.help"), included)
    }

    private func commit() async {
        guard canCommit else { return }
        if await repository.commit(summary: summary, description: details, amend: amend) {
            summary = ""
            details = ""
            amend = false
        }
    }

    /// The last commit's message comes back to the box, so it can be confirmed again after changes.
    private func undo() async {
        let previous = repository.snapshot.headCommit?.subject ?? ""
        if await repository.perform(.undoCommit), summary.isEmpty { summary = previous }
    }
}
