import SwiftUI

extension View {
    func gitWorkDialogs(repository: GitRepository) -> some View {
        modifier(GitWorkDialogs(repository: repository))
    }
}

private struct GitWorkDialogs: ViewModifier {
    let repository: GitRepository
    @Bindable var work = GitWork.shared

    /// «¿Cancelar una combinación?»; nothing to name when no operation is halfway.
    private var abortTitle: String {
        let operation = repository.snapshot.operation
        return operation.isEmpty ? L("git.problems.abort") : String(format: L("git.problems.abortTitle"), L("git.operation.\(operation)"))
    }

    private func shown<T>(_ value: Binding<T?>) -> Binding<Bool> {
        Binding(get: { value.wrappedValue != nil }, set: { if !$0 { value.wrappedValue = nil } })
    }

    func body(content: Content) -> some View {
        content
            .confirmationDialog(L("git.history.revertTitle"), isPresented: shown($work.reverting), presenting: work.reverting) { commit in
                Button(L("git.history.revert")) { Task { await repository.perform(.revert, value: commit.hash) } }
                    .accessibilityIdentifier("git.history.revertConfirm")
                Button(L("common.cancel"), role: .cancel) {}.accessibilityIdentifier("git.history.revertCancel")
            } message: { commit in
                Text(String(format: L("git.history.revertDetail"), commit.subject, repository.branchTitle))
            }
            .confirmationDialog(String(format: L("git.history.copyTitle"), work.copying?.target ?? ""), isPresented: shown($work.copying),
                                presenting: work.copying) { request in
                Button(L("git.history.copyConfirm")) { Task { await repository.copyCommits(request.hashes, to: request.target) } }
                    .accessibilityIdentifier("git.history.copyConfirm")
                Button(L("common.cancel"), role: .cancel) {}.accessibilityIdentifier("git.history.copyCancel")
            } message: { request in
                Text(String(format: L("git.history.copyDetail"), request.title, request.target, repository.branchTitle))
            }
            .confirmationDialog(abortTitle, isPresented: $work.aborting) {
                Button(L("git.problems.abort"), role: .destructive) { Task { await repository.abortOperation() } }
                    .accessibilityIdentifier("git.problems.abortConfirm")
                Button(L("common.cancel"), role: .cancel) {}.accessibilityIdentifier("git.problems.abortCancel")
            } message: {
                Text(L("git.problems.abortDetail"))
            }
            .confirmationDialog(String(format: L("git.problems.ignoreTitle"), work.ignoring?.count ?? 0), isPresented: shown($work.ignoring),
                                presenting: work.ignoring) { paths in
                Button(L("git.problems.ignoreConfirm")) {
                    Task { for path in paths { guard await repository.perform(.ignorePath, value: path, notify: false) else { break } } }
                }
                .accessibilityIdentifier("git.problems.ignoreConfirm")
                Button(L("common.cancel"), role: .cancel) {}.accessibilityIdentifier("git.problems.ignoreCancel")
            } message: { paths in
                Text(String(format: L("git.problems.ignoreDetail"), paths.prefix(6).joined(separator: "\n")))
            }
            .sheet(item: $work.naming) { request in GitCommitNameSheet(repository: repository, request: request).themedSheet() }
            .sheet(isPresented: $work.organizing) { GitOrganizeSheet(repository: repository).themedSheet() }
            .sheet(isPresented: $work.syncingBranches) { GitBranchSyncSheet(repository: repository).themedSheet() }
            .sheet(isPresented: $work.resolving) { GitConflictSheet(repository: repository).themedSheet() }
            .sheet(isPresented: $work.identity) { GitIdentitySheet(repository: repository).themedSheet() }
    }
}

/// «Crear rama desde aquí…» (the current branch does not change) or «Etiquetar…».
struct GitCommitNameSheet: View {
    let repository: GitRepository
    let request: GitNameRequest
    @State private var name = ""
    @FocusState private var focused: Bool

    private var clean: String { name.trimmingCharacters(in: .whitespaces) }
    /// What Git refuses in a branch or tag name; the engine has the last word.
    private var valid: Bool {
        let taken = request.kind == .branch && repository.snapshot.branches.contains { $0.name == clean }
        return !clean.isEmpty && !clean.hasPrefix("-") && !clean.hasSuffix("/") && !clean.hasSuffix(".lock") && !clean.contains("..")
            && clean.rangeOfCharacter(from: CharacterSet(charactersIn: " ~^:?*[\\")) == nil && !taken
    }

    var body: some View {
        let branch = request.kind == .branch
        let short = String(request.commit.hash.prefix(7))
        SheetFrame(title: L(branch ? "git.history.branchTitle" : "git.history.tagTitle"), symbol: branch ? Symbols.gitNewBranch : Symbols.tags,
                   detail: String(format: L(branch ? "git.history.branchDetail" : "git.history.tagDetail"), short, request.commit.subject),
                   note: !clean.isEmpty && !valid ? L(branch ? "git.branch.invalidName" : "git.history.invalidTag") : nil, width: 440,
                   actionTitle: L(branch ? "git.branch.create" : "git.history.tagCreate"), actionID: "git.history.nameSave",
                   canAct: valid && !repository.busy, cancelID: "git.history.nameCancel") {
            await repository.perform(branch ? .createBranchAt : .createTag, value: "\(clean):\(request.commit.hash)")
        } content: {
            TextField(L(branch ? "git.branch.namePlaceholder" : "git.history.tagPlaceholder"), text: $name)
                .textFieldStyle(.roundedBorder).focused($focused)
                .accessibilityIdentifier("git.history.name")
        }
        .onAppear { focused = true }
    }
}
