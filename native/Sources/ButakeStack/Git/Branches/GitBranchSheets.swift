import SwiftUI

/// «Nueva rama…» (from the current one, and switches to it) or «Renombrar rama…».
struct GitBranchNameSheet: View {
    let repository: GitRepository
    /// The branch being renamed; nil for a new one.
    let renaming: String?
    @State private var name = ""
    @FocusState private var focused: Bool

    private var clean: String { name.trimmingCharacters(in: .whitespaces) }
    /// Spaces and the characters Git refuses in a branch name; the engine has the last word.
    private var valid: Bool {
        !clean.isEmpty && !clean.hasPrefix("-") && !clean.hasSuffix("/") && !clean.hasSuffix(".lock") && !clean.contains("..")
            && clean.rangeOfCharacter(from: CharacterSet(charactersIn: " ~^:?*[\\")) == nil && clean != renaming
            && !repository.snapshot.branches.contains { $0.name == clean }
    }

    var body: some View {
        SheetFrame(title: L(renaming == nil ? "git.branch.newTitle" : "git.branch.renameTitle"), symbol: Symbols.git,
                   detail: renaming.map { String(format: L("git.branch.renameDetail"), $0) } ?? String(format: L("git.branch.newDetail"), repository.branchTitle),
                   note: !clean.isEmpty && !valid ? L("git.branch.invalidName") : nil, width: 420,
                   actionTitle: L(renaming == nil ? "git.branch.create" : "git.branch.rename"), actionID: "git.branch.sheet.save",
                   canAct: valid && !repository.busy, cancelID: "git.branch.sheet.cancel") {
            if let renaming { return await repository.renameBranch(renaming, to: clean) }
            return await repository.createBranch(clean)
        } content: {
            TextField(L("git.branch.namePlaceholder"), text: $name)
                .textFieldStyle(.roundedBorder).focused($focused)
                .accessibilityIdentifier("git.branch.sheet.name")
        }
        .onAppear {
            name = renaming ?? ""
            focused = true
        }
    }
}

/// «Buscar rama…»: every branch, local and remote, filtered as you type; choosing one switches.
struct GitBranchFinderSheet: View {
    let repository: GitRepository
    let choose: (String) -> Void
    @State private var search = ""
    @State private var selection: String?
    @Environment(\.dismiss) private var dismiss

    private var names: [String] {
        let all = repository.localBranches.map(\.name) + repository.remoteOnlyBranches.map(\.name)
        return search.isEmpty ? all : all.filter { $0.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        SheetFrame(title: L("git.branch.findTitle"), symbol: Symbols.search, width: 420, height: 420,
                   actionTitle: L("git.branch.switch"), actionID: "git.branch.find.switch",
                   canAct: selection != nil && selection != repository.snapshot.branch, cancelID: "git.branch.find.cancel") {
            if let selection { choose(selection) }
            return true
        } content: {
            VStack(spacing: 8) {
                FilterField(text: $search, identifier: "git.branch.find.search", prompt: L("git.branch.search"))
                List(names, id: \.self, selection: $selection) { name in
                    Label(name, systemImage: name == repository.snapshot.branch ? Symbols.selected : Symbols.git)
                        .lineLimit(1).truncationMode(.middle)
                }
                .listStyle(.bordered)
                .overlay { if names.isEmpty { ContentUnavailableView.search(text: search) } }
            }
        }
    }
}
