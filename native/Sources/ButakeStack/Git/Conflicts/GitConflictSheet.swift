import SwiftUI

/// «Resolver conflictos»: the files in conflict on the left; for the chosen one, «Tu versión» and
/// «Versión entrante» side by side, «Usar ambas» and the result, editable, that is saved as the
/// resolution. When none is left, «Continuar» finishes the operation; «Cancelar la operación…»
/// goes back to before it started.
struct GitConflictSheet: View {
    @Bindable var repository: GitRepository
    @State private var selection: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let conflicts = repository.conflicts
        VStack(spacing: 0) {
            header(conflicts.count)
            Divider()
            HSplitView {
                List(conflicts, selection: $selection) { file in
                    Label { Text(file.path).lineLimit(1).truncationMode(.middle).help(file.path) } icon: { FileTypeIcon(path: file.path, size: 16) }
                        .tag(file.path)
                        .accessibilityIdentifier("git.conflict.file.\(file.path)")
                }
                .listStyle(.sidebar)
                .themedScroll()
                .frame(minWidth: 200, idealWidth: 240, maxWidth: 320)
                .overlay {
                    if conflicts.isEmpty {
                        ContentUnavailableView(L("git.conflict.doneTitle"), systemImage: Symbols.success, description: Text(L("git.conflict.doneDetail")))
                    }
                }
                Group {
                    if let path = selection, conflicts.contains(where: { $0.path == path }) {
                        GitConflictResolver(repository: repository, path: path, rebasing: repository.snapshot.operation == "rebase") {
                            selection = repository.conflicts.first { $0.path != path }?.path
                        }
                        .id(path)
                    } else {
                        ContentUnavailableView(L("git.conflict.chooseTitle"), systemImage: Symbols.gitResolve, description: Text(L("git.conflict.chooseDetail")))
                    }
                }
                .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            footer(remaining: conflicts.count)
        }
        .frame(minWidth: 900, idealWidth: 1100, minHeight: 520, idealHeight: 760)
        .onAppear { if selection == nil { selection = conflicts.first?.path } }
        .accessibilityIdentifier("git.conflict.sheet")
    }

    private func header(_ count: Int) -> some View {
        HStack(spacing: 12) {
            IconTile(symbol: Symbols.gitResolve, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(L("git.conflict.title")).font(.uiTitle3.weight(.semibold))
                Text(count == 0 ? L("git.conflict.noneLeft") : String(format: L("git.conflict.remaining"), count))
                    .font(.uiCaption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(16)
    }

    private func footer(remaining: Int) -> some View {
        let operation = repository.snapshot.operation
        return HStack(spacing: 8) {
            if !operation.isEmpty {
                Button(role: .destructive) {
                    // The confirmation belongs to the page: it opens once this sheet is gone.
                    dismiss()
                    Task { try? await Task.sleep(for: .milliseconds(350)); GitWork.shared.aborting = true }
                } label: {
                    Label(L("git.problems.abortEllipsis"), systemImage: Symbols.gitAbort)
                }
                .buttonStyle(.bordered).disabled(repository.busy)
                .help(String(format: L("git.conflict.abortHelp"), L("git.operation.\(operation)")))
                .accessibilityIdentifier("git.conflict.abort")
            }
            Spacer()
            Button(L("common.close")) { dismiss() }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("git.conflict.close")
            Button {
                Task {
                    await repository.continueOperation()
                    if repository.snapshot.operation.isEmpty { dismiss() }
                }
            } label: {
                Label(L("git.problems.continue"), systemImage: Symbols.gitContinue)
            }
            .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            .disabled(remaining > 0 || operation.isEmpty || repository.busy)
            .help(L(remaining > 0 ? "git.conflict.continueBlocked" : "git.conflict.continueHelp"))
            .accessibilityIdentifier("git.conflict.continue")
        }
        .padding(16)
    }
}

/// The versions of a file in conflict (`gitConflict`).
struct GitConflictVersions: Decodable, Sendable {
    var base: String
    var ours: String
    var theirs: String
    var working: String
}

/// One file: both versions, the result and «Guardar resolución».
private struct GitConflictResolver: View {
    let repository: GitRepository
    let path: String
    /// In a reorganization Git's sides are swapped: «ours» is the branch underneath, «theirs» your commit.
    let rebasing: Bool
    let saved: () -> Void
    @State private var versions: GitConflictVersions?
    @State private var result = ""
    @State private var failure: String?
    @State private var saving = false

    private var mine: String { rebasing ? versions?.theirs ?? "" : versions?.ours ?? "" }
    private var incoming: String { rebasing ? versions?.ours ?? "" : versions?.theirs ?? "" }
    /// Opening or closing markers left (a lone `=======` can be real content).
    private var unresolved: Bool { result.components(separatedBy: "\n").contains { $0.hasPrefix("<<<<<<< ") || $0.hasPrefix(">>>>>>> ") } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if versions == nil {
                if let failure {
                    ContentUnavailableView(L("git.conflict.cantRead"), systemImage: Symbols.warning, description: Text(failure))
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                HStack(spacing: 10) {
                    side(L("git.conflict.mine"), text: mine, id: "mine")
                    side(L("git.conflict.incoming"), text: incoming, id: "incoming")
                }
                .frame(minHeight: 160, idealHeight: 220)
                HStack(spacing: 8) {
                    Text(L("git.conflict.result")).font(.uiHeadline)
                    Spacer()
                    if unresolved {
                        Label(L("git.conflict.markersLeft"), systemImage: Symbols.warning).font(.uiCaption).foregroundStyle(Brand.warningText)
                    }
                    Button { result = Self.both(mine, incoming) } label: { Label(L("git.conflict.useBoth"), systemImage: Symbols.gitCombine) }
                        .buttonStyle(.bordered).controlSize(.small)
                        .help(L("git.conflict.useBothHelp"))
                        .accessibilityIdentifier("git.conflict.useBoth")
                }
                CodeEditor(text: $result, path: path, editable: !saving)
                    .frame(minHeight: 160)
                    .overlay { RoundedRectangle(cornerRadius: Radius.small).strokeBorder(Color(nsColor: .separatorColor)) }
                    .accessibilityIdentifier("git.conflict.result")
                if let failure { Text(failure).font(.uiCaption).foregroundStyle(Brand.dangerText).textSelection(.enabled) }
                HStack {
                    Text(L("git.conflict.saveNote")).font(.uiCaption).foregroundStyle(.secondary)
                    Spacer()
                    Button { Task { await save() } } label: { Label(L("git.conflict.save"), systemImage: Symbols.success) }
                        .buttonStyle(.borderedProminent)
                        .disabled(unresolved || saving || repository.busy)
                        .help(L(unresolved ? "git.conflict.markersHelp" : "git.conflict.saveHelp"))
                        .accessibilityIdentifier("git.conflict.save")
                }
            }
        }
        .padding(14)
        .task { await load() }
    }

    private func side(_ title: String, text: String, id: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.uiCallout.weight(.semibold))
                Spacer()
                Button { result = text } label: { Label(L("git.conflict.useThis"), systemImage: Symbols.selected) }
                    .buttonStyle(.bordered).controlSize(.small)
                    .help(String(format: L("git.conflict.useThisHelp"), title))
                    .accessibilityIdentifier("git.conflict.use.\(id)")
            }
            CodeEditor(text: .constant(text), path: path, editable: false)
                .overlay { RoundedRectangle(cornerRadius: Radius.small).strokeBorder(Color(nsColor: .separatorColor)) }
        }
    }

    /// Both versions, one after the other.
    static func both(_ first: String, _ second: String) -> String {
        first.isEmpty || first.hasSuffix("\n") ? first + second : first + "\n" + second
    }

    private func load() async {
        do {
            let value: GitConflictVersions = try await repository.store.call(["method": "gitConflict", "path": repository.root, "file": path])
            versions = value
            result = value.working
        } catch {
            let failure = GitFailure(error)
            self.failure = failure.detail.isEmpty ? failure.title : failure.detail
        }
    }

    private func save() async {
        guard let versions else { return }
        saving = true
        defer { saving = false }
        let request: [String: Any] = ["method": "gitResolveConflict", "file": path, "content": result, "expected": versions.working, "confirmed": true]
        switch await repository.run(L("git.progress.resolve"), request, done: L("git.done.resolve"), as: String.self) {
        case .success: failure = nil; saved()
        case .failure(let error): failure = error.detail.isEmpty ? error.title : error.detail
        }
    }
}
