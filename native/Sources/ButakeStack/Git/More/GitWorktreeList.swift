import AppKit
import SwiftUI

/// «Más…» › Carpetas de trabajo: the repository's other working folders, each on its own branch, so
/// two branches can be open at once. Add one, open an assistant or Finder in it, take it out (asks
/// first; its branch and commits stay).
struct GitWorktreeList: View {
    let repository: GitRepository
    @State private var adding = false
    @State private var removing: GitWorktree?

    var body: some View {
        GitQueryList(repository: repository, arguments: ["worktree", "list", "--porcelain"], parse: GitWorktree.parse,
                     empty: (L("git.more.worktreesEmpty"), L("git.more.worktreesEmptyDetail"), Symbols.gitWorktree),
                     identifier: "git.more.worktreeList") { worktree in
            LabeledContent {
                HStack(spacing: 6) {
                    GitAssistantMenu(directory: worktree.path, suffix: worktree.branch.isEmpty ? worktree.id : worktree.branch)
                        .menuStyle(.button).buttonStyle(.bordered).fixedSize()
                    Button { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: worktree.path) } label: {
                        Label(L("menu.showInFinder"), systemImage: Symbols.folder)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("git.more.showWorktree.\(worktree.branch)")
                    if !worktree.main {
                        Button(role: .destructive) { removing = worktree } label: {
                            Label(L("git.more.removeWorktree"), systemImage: Symbols.remove).labelStyle(.iconOnly)
                        }
                        .buttonStyle(.borderless).disabled(repository.busy)
                        .help(L("git.more.removeWorktreeHelp"))
                        .accessibilityIdentifier("git.more.removeWorktree.\(worktree.branch)")
                    }
                }
            } label: {
                Label(worktree.branch.isEmpty ? L("git.detached") : worktree.branch,
                      systemImage: worktree.path == repository.root ? Symbols.selected : Symbols.gitWorktree)
                Text(worktree.main ? L("git.more.worktreeMain") : worktree.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .lineLimit(1).truncationMode(.middle).help(worktree.path)
            }
        } actions: {
            Button { adding = true } label: { Label(L("git.more.newWorktreeEllipsis"), systemImage: Symbols.add) }
                .buttonStyle(.bordered).disabled(repository.busy || repository.snapshot.headCommit == nil)
                .help(L("git.more.worktreesNote"))
                .accessibilityIdentifier("git.more.newWorktree")
        }
        .confirmationDialog(String(format: L("git.more.removeWorktreeTitle"), removing.map { ($0.path as NSString).lastPathComponent } ?? ""),
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), presenting: removing) { worktree in
            Button(L("git.more.removeWorktree"), role: .destructive) {
                Task { GitMoreRefresh.shared.after(await repository.perform(.removeWorktree, value: worktree.path)) }
            }
            .accessibilityIdentifier("git.more.removeWorktreeConfirm")
            Button(L("common.cancel"), role: .cancel) {}.accessibilityIdentifier("git.more.removeWorktreeCancel")
        } message: { worktree in
            Text(String(format: L("git.more.removeWorktreeDetail"), worktree.branch.isEmpty ? L("git.detached") : worktree.branch))
        }
        .sheet(isPresented: $adding) { GitAddWorktreeSheet(repository: repository).themedSheet() }
        #if DEBUG
        .task {
            if GitQA.worktreeAdding { GitQA.worktreeAdding = false; adding = true }
            if let branch = GitQA.worktreeRemoving {
                GitQA.worktreeRemoving = nil
                let listed = GitWorktree.parse((try? await repository.query(["worktree", "list", "--porcelain"])) ?? "")
                removing = listed.first { $0.branch == branch && !$0.main }
            }
        }
        #endif
    }
}

/// «Nueva carpeta de trabajo…»: a branch (an existing one or a new one from the current commit) and a
/// new folder beside the repository's.
private struct GitAddWorktreeSheet: View {
    let repository: GitRepository
    @State private var branch = ""
    @State private var name = ""
    @State private var parent: String
    @State private var nameEdited = false
    @FocusState private var focused: Bool

    init(repository: GitRepository) {
        self.repository = repository
        _parent = State(initialValue: (repository.root as NSString).deletingLastPathComponent)
    }

    private var cleanBranch: String { branch.trimmingCharacters(in: .whitespaces) }
    private var exists: Bool { repository.snapshot.branches.contains { $0.name == cleanBranch } }
    private var target: String { (parent as NSString).appendingPathComponent(name.trimmingCharacters(in: .whitespaces)) }
    private var taken: Bool { !name.isEmpty && FileManager.default.fileExists(atPath: target) }
    private var valid: Bool {
        !cleanBranch.isEmpty && !cleanBranch.hasPrefix("-") && cleanBranch.rangeOfCharacter(from: CharacterSet(charactersIn: " ~^:?*[\\")) == nil
            && GitRepositoryName.valid(name.trimmingCharacters(in: .whitespaces)) && !taken
    }
    /// «proyecto-feature-x»: the repository's folder and the branch, without slashes.
    private var suggestedName: String {
        let base = (repository.root as NSString).lastPathComponent
        let slug = cleanBranch.replacingOccurrences(of: "/", with: "-")
        return slug.isEmpty ? "" : "\(base)-\(slug)"
    }

    var body: some View {
        SheetFrame(title: L("git.more.newWorktreeTitle"), symbol: Symbols.gitWorktree, detail: L("git.more.newWorktreeDetail"),
                   note: taken ? String(format: L("git.clone.exists"), name) : nil, width: 500,
                   actionTitle: L("git.more.newWorktree"), actionSymbol: Symbols.add, actionID: "git.more.newWorktreeSave",
                   canAct: valid && !repository.busy, cancelID: "git.more.newWorktreeCancel") {
            let done = await repository.perform(.addWorktree, value: target + "\n" + cleanBranch)
            GitMoreRefresh.shared.after(done)
            return done
        } content: {
            Form {
                Section {
                    TextField(L("git.more.worktreeBranch"), text: $branch, prompt: Text(verbatim: "feature/…"))
                        .focused($focused)
                        .accessibilityIdentifier("git.more.worktreeBranch")
                    LabeledContent(L("git.more.worktreeBranchState"), value: cleanBranch.isEmpty ? "—" : L(exists ? "git.more.worktreeExisting" : "git.more.worktreeNew"))
                    TextField(L("git.repo.folderName"), text: Binding(get: { name }, set: { name = $0; nameEdited = true }))
                        .accessibilityIdentifier("git.more.worktreeName")
                    GitFolderRow(parent: $parent, identifier: "git.more.worktreeFolder")
                }
            }
            .formStyle(.grouped).scrollDisabled(true)
        }
        .onChange(of: branch) { if !nameEdited { name = suggestedName } }
        .onAppear { focused = true }
    }
}
