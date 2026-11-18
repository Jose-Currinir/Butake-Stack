import SwiftUI

/// «Git del proyecto»: one row per repository of the project (its parts' and the ones added to
/// it) with branch, changes, ↓↑ and what needs fixing; «Actualizar todo» asks every remote,
/// «Bajar todo» brings what each one has, and «Abrir en Git» opens one in the tool. Committing and
/// sending stay one repository at a time, in the tool: nothing here commits or sends.
struct CompositeGitSection: View {
    @Bindable var store: StackStore
    let group: ProjectGroup
    @Bindable private var tool = GitTool.shared
    /// «Actualizar todo» or «Bajar todo» under way.
    @State private var working = false
    /// Why asking a remote failed, per repository, until the next try.
    @State private var failures: [String: GitFailure] = [:]

    private var entries: [GitRepositoryEntry] { tool.entries(of: group) }

    var body: some View {
        let entries = entries
        let branches = Set(entries.compactMap { tool.summary(of: $0)?.branch }.filter { !$0.isEmpty })
        Section {
            if branches.count > 1 {
                Notice(.warning, L("composite.git.branchesDiffer"), detail: branches.sorted().joined(separator: " · "), symbol: Symbols.git)
                    .accessibilityIdentifier("composite.git.branchesDiffer")
            }
            if entries.isEmpty {
                Text(L("composite.git.empty")).foregroundStyle(.secondary).accessibilityIdentifier("composite.git.empty")
            }
            ForEach(entries) { entry in
                row(entry)
            }
            LabeledContent {
                Button { store.chooseRepository(for: group.id) } label: { Label(L("composite.git.add"), systemImage: Symbols.add) }
                    .buttonStyle(.bordered).accessibilityIdentifier("composite.git.add")
            } label: {
                Text(L("composite.git.addDetail")).foregroundStyle(.secondary)
            }
        } header: {
            HStack {
                Text(L("composite.git"))
                Spacer()
                if working { ProgressView().controlSize(.small) }
                Button { Task { await run(pull: false) } } label: { Label(L("composite.git.updateAll"), systemImage: Symbols.reload) }
                    .buttonStyle(.bordered).controlSize(.small).disabled(working || entries.isEmpty)
                    .help(L("composite.git.updateAllHelp")).accessibilityIdentifier("composite.git.updateAll")
                Button { Task { await run(pull: true) } } label: { Label(L("composite.git.pullAll"), systemImage: Symbols.gitPull) }
                    .buttonStyle(.bordered).controlSize(.small).disabled(working || entries.isEmpty)
                    .help(L("composite.git.pullAllHelp")).accessibilityIdentifier("composite.git.pullAll")
            }
        } footer: {
            SettingsFooter(L("composite.git.footer"))
        }
        .task(id: group.repositories) { await tool.loadList(); await tool.loadSummaries() }
    }

    private func row(_ entry: GitRepositoryEntry) -> some View {
        let failure = failures[entry.path]
        let part = entry.project.flatMap { id in store.projects.first { $0.id == id } }
        return HStack(spacing: 8) {
            GitRepositoryRow(entry: entry, summary: tool.summary(of: entry), current: false)
            if let failure {
                Image(systemName: Symbols.warning).foregroundStyle(Brand.warning)
                    .help(failure.detail.isEmpty ? failure.title : failure.detail)
                    .accessibilityLabel(failure.title)
                    .accessibilityIdentifier("composite.git.failure.\(entry.name)")
            }
            // A part's repository already carries the part's name; one added by hand says so.
            if part == nil {
                Text(L("composite.git.addedByHand")).font(.uiCaption).foregroundStyle(.secondary).lineLimit(1)
                Button { store.removeRepository(entry.path, from: group.id) } label: { Label(L("composite.git.remove"), systemImage: Symbols.remove).labelStyle(.iconOnly) }
                    .buttonStyle(.borderless).help(L("composite.git.removeHelp"))
                    .accessibilityIdentifier("composite.git.remove.\(entry.name)")
            }
            Button { GitTool.shared.show(entry.path) } label: { Label(L("git.openHere"), systemImage: Symbols.forward).labelStyle(.iconOnly) }
                .buttonStyle(.borderless).disabled(entry.missing)
                .help(String(format: L("git.statusBoard.openHelp"), entry.name))
                .accessibilityIdentifier("composite.git.open.\(entry.name)")
        }
        .accessibilityIdentifier("composite.git.row.\(entry.name)")
    }

    /// «Actualizar todo» (`pull` false) or «Bajar todo»; then every row reads its state again.
    private func run(pull: Bool) async {
        guard !working else { return }
        working = true
        defer { working = false }
        failures = pull ? await CompositeGit.pullAll(entries, store: store) : await CompositeGit.fetchAll(entries, store: store)
        await tool.loadSummaries()
        await store.refreshGit()
        await tool.repository?.refresh()
    }
}
