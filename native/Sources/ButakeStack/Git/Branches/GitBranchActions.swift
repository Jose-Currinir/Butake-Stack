import SwiftUI

/// Branch actions waiting for the user (a confirmation or a name), wherever they were asked: the
/// toolbar's branch menu, Ramas' list or its detail. The Git page shows their dialogs and sheets
/// (`gitBranchDialogs`), so each one exists once.
@MainActor @Observable final class GitBranchActions {
    static let shared = GitBranchActions()
    /// Switching with changes on screen.
    var switching: String?
    var merging: String?
    var renaming: String?
    var deleting: String?
    /// A branch with commits nowhere else: deleting it needs a second, explicit yes.
    var forceDeleting: String?

    /// Switches at once, or asks first when there are changes (they travel to the other branch
    /// when they don't collide; Git refuses otherwise and says which files).
    func requestSwitch(_ name: String, in repository: GitRepository) {
        if repository.files.isEmpty { Task { await repository.switchTo(name) } } else { switching = name }
    }

    func delete(_ name: String, force: Bool, in repository: GitRepository) async {
        if await repository.deleteBranch(name, force: force) == .notMerged { forceDeleting = name }
    }
}

extension View {
    func gitBranchDialogs(repository: GitRepository) -> some View {
        modifier(GitBranchDialogs(repository: repository))
    }
}

private struct GitBranchDialogs: ViewModifier {
    let repository: GitRepository
    @Bindable var actions = GitBranchActions.shared
    @Bindable var tool = GitTool.shared

    private func shown(_ value: Binding<String?>) -> Binding<Bool> {
        Binding(get: { value.wrappedValue != nil }, set: { if !$0 { value.wrappedValue = nil } })
    }

    func body(content: Content) -> some View {
        content
            .confirmationDialog(String(format: L("git.branch.switchTitle"), actions.switching ?? ""), isPresented: shown($actions.switching), presenting: actions.switching) { name in
                Button(L("git.branch.switchAnyway")) { Task { await repository.switchTo(name) } }
                    .accessibilityIdentifier("git.branch.switchConfirm")
                Button(L("common.cancel"), role: .cancel) {}.accessibilityIdentifier("git.branch.switchCancel")
            } message: { _ in
                Text(String(format: L("git.branch.switchDetail"), repository.files.count))
            }
            .confirmationDialog(String(format: L("git.branch.mergeTitle"), actions.merging ?? "", repository.branchTitle), isPresented: shown($actions.merging), presenting: actions.merging) { name in
                Button(L("git.branch.merge")) { Task { await repository.merge(name) } }
                    .accessibilityIdentifier("git.branch.mergeConfirm")
                Button(L("common.cancel"), role: .cancel) {}.accessibilityIdentifier("git.branch.mergeCancel")
            } message: { name in
                Text(String(format: L("git.branch.mergeDetail"), name, repository.branchTitle))
            }
            .confirmationDialog(String(format: L("git.branch.deleteTitle"), actions.deleting ?? ""), isPresented: shown($actions.deleting), presenting: actions.deleting) { name in
                Button(L("common.delete"), role: .destructive) { Task { await actions.delete(name, force: false, in: repository) } }
                    .accessibilityIdentifier("git.branch.deleteConfirm")
                Button(L("common.cancel"), role: .cancel) {}.accessibilityIdentifier("git.branch.deleteCancel")
            } message: { _ in
                Text(L("git.branch.deleteDetail"))
            }
            .confirmationDialog(String(format: L("git.branch.forceDeleteTitle"), actions.forceDeleting ?? ""), isPresented: shown($actions.forceDeleting), presenting: actions.forceDeleting) { name in
                Button(L("git.branch.forceDelete"), role: .destructive) { Task { await actions.delete(name, force: true, in: repository) } }
                    .accessibilityIdentifier("git.branch.forceDeleteConfirm")
                Button(L("common.cancel"), role: .cancel) {}.accessibilityIdentifier("git.branch.forceDeleteCancel")
            } message: { name in
                Text(String(format: L("git.branch.forceDeleteDetail"), name))
            }
            .sheet(isPresented: $tool.creatingBranch) { GitBranchNameSheet(repository: repository, renaming: nil).themedSheet() }
            .sheet(item: Binding(get: { actions.renaming.map(GitBranchName.init) }, set: { actions.renaming = $0?.name })) { item in
                GitBranchNameSheet(repository: repository, renaming: item.name).themedSheet()
            }
    }
}

/// A branch name as a sheet's item.
private struct GitBranchName: Identifiable {
    let name: String
    var id: String { name }
}
