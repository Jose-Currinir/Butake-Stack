import AppKit
import SwiftUI

/// Cambios in the content column: the changed files, as a list or by folders, with a checkbox each
/// (goes into the commit or not) and a filter; the commit box at the bottom, always visible.
struct GitChangesList: View {
    @Bindable var repository: GitRepository
    @AppStorage("git.changes.folders") private var folders = false
    @State private var search = ""

    /// The filtered files; thousands are filtered off the work of each row.
    private var visible: [GitChange] {
        let query = search.trimmingCharacters(in: .whitespaces)
        return query.isEmpty ? repository.changes : repository.changes.filter { $0.path.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            let shown = visible
            Group {
                if folders {
                    GitChangeTreeView(changes: shown, selection: $repository.selectedFile,
                                      onInclude: { repository.include($0.map(\.path), $1) }) { change in
                        GitChangeMenu(repository: repository, paths: [change.path])
                    }
                } else {
                    GitChangeListView(repository: repository, changes: shown)
                }
            }
            .frame(maxHeight: .infinity)
            .overlay {
                if !search.isEmpty && shown.isEmpty && !repository.changes.isEmpty { ContentUnavailableView.search(text: search).background(.background) }
            }
            Divider()
            GitCommitBox(repository: repository)
        }
        .gitDiscardConfirmation(repository: repository)
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 6) {
            FilterField(text: $search, identifier: "git.changes.filter", prompt: L("git.changes.filter"))
            HStack {
                Picker(L("git.changes.viewLabel"), selection: $folders) {
                    Label(L("git.changes.asList"), systemImage: Symbols.gitListView).tag(false)
                    Label(L("git.changes.asFolders"), systemImage: Symbols.gitTreeView).tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .help(L("git.changes.viewHelp"))
                .accessibilityIdentifier("git.changes.view")
                Spacer()
                if repository.conflicts.count > 0 {
                    Label(String(format: L("git.changes.conflicts"), repository.conflicts.count), systemImage: Symbols.warning)
                        .font(.uiCaption).foregroundStyle(Brand.warningText)
                        .help(L("git.changes.conflictsHelp"))
                }
            }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
        }
    }
}

/// The changed files as a flat list: checkbox, icon, name and folder, kind and line counts. Like the
/// tree, a system `List`: only the rows on screen are built, so thousands of files stay fluid.
struct GitChangeListView: View {
    @Bindable var repository: GitRepository
    let changes: [GitChange]
    @State private var picked: Set<String> = []
    /// Checkbox clicks not yet confirmed by the next list: they show at once.
    @State private var pending: [String: Bool] = [:]

    private func include(_ targets: [GitChange], _ value: Bool) {
        let paths = targets.filter { !$0.isConflict }.map(\.path)
        guard !paths.isEmpty else { return }
        for path in paths { pending[path] = value }
        repository.include(paths, value)
    }

    private func state(_ targets: [GitChange]) -> GitInclusion { GitChangeTree.inclusion(of: targets, pending: pending) }

    var body: some View {
        let selectable = changes.filter { !$0.isConflict }
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                GitInclusionCheckbox(state: state(selectable), label: L("git.tree.includeAll")) { include(selectable, $0) }
                .disabled(selectable.isEmpty)
                .accessibilityIdentifier("git.changes.includeAll")
                Text(L("git.tree.title")).font(.uiCallout.weight(.semibold))
                let included = selectable.filter { state([$0]) != .none }.count
                Text("\(included)/\(selectable.count)").font(.uiCaption.monospacedDigit()).foregroundStyle(.secondary)
                    .accessibilityLabel(String(format: L("git.tree.countLabel"), included, selectable.count))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).frame(minHeight: 34)
            Divider()
            if changes.isEmpty {
                ContentUnavailableView {
                    Label(L("git.tree.emptyTitle"), systemImage: Symbols.noChanges)
                } description: {
                    Text(L("git.tree.emptyDetail"))
                }
                .frame(maxHeight: .infinity)
            } else {
                List(changes, selection: $picked) { change in
                    GitChangeRow(change: change, inclusion: state([change])) { include([change], $0) }
                        .tag(change.path)
                }
                .listStyle(.sidebar)
                .themedScroll()
                .accessibilityIdentifier("git.changes.list")
                .contextMenu(forSelectionType: String.self) { paths in
                    GitChangeMenu(repository: repository, paths: Array(paths))
                } primaryAction: { paths in
                    // Double click (or ↩): the file goes in or out of the commit.
                    let targets = changes.filter { paths.contains($0.path) && !$0.isConflict }
                    include(targets, state(targets) != .full)
                }
                .onKeyPress(.space) {
                    let targets = changes.filter { picked.contains($0.path) && !$0.isConflict }
                    guard !targets.isEmpty else { return .ignored }
                    include(targets, state(targets) != .full)
                    return .handled
                }
            }
        }
        // The next list replaces the marks it agrees with.
        .onChange(of: changes) {
            let byPath = Dictionary(changes.map { ($0.path, $0.inclusion) }, uniquingKeysWith: { first, _ in first })
            pending = pending.filter { path, value in byPath[path].map { value ? $0 != .full : $0 != .none } ?? false }
        }
        // The diff follows the last file picked; several picked files act together in the menu.
        .onChange(of: picked) { old, new in
            if let added = new.subtracting(old).first ?? (new.count == 1 ? new.first : nil) { repository.selectedFile = added }
        }
        .onChange(of: repository.selectedFile, initial: true) { _, path in
            if let path, !picked.contains(path) { picked = [path] }
        }
    }
}

/// A file of the flat list.
private struct GitChangeRow: View {
    let change: GitChange
    let inclusion: GitInclusion
    let include: (Bool) -> Void

    var body: some View {
        HStack(spacing: 7) {
            if change.isConflict {
                Image(systemName: Symbols.warning).foregroundStyle(GitChangeKind.conflict.color).accessibilityHidden(true)
            } else {
                GitInclusionCheckbox(state: inclusion, label: L(inclusion == .full ? "git.tree.leaveOut" : "git.tree.include"), action: include)
                    .accessibilityIdentifier("git.changes.check.\(change.path)")
            }
            FileTypeIcon(path: change.path, size: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(change.name).font(.uiBody).lineLimit(1).truncationMode(.middle)
                    .strikethrough(change.kind == .deleted, color: .secondary)
                if !change.directory.isEmpty {
                    Text(change.directory).font(.uiCaption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                }
            }
            .help(change.path)
            Spacer(minLength: 4)
            GitChangeKindBadge(kind: change.kind, compact: true)
            if !change.stats.isEmpty { GitStatsBadge(stats: change.stats) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("git.changes.row.\(change.path)")
        .accessibilityValue(L(inclusion == .full ? "git.tree.included" : inclusion == .partial ? "git.tree.partial" : "git.tree.leftOut"))
    }
}

/// The menu of one or more changed files: include or leave out, discard, show in Finder, copy path.
struct GitChangeMenu: View {
    let repository: GitRepository
    let paths: [String]

    var body: some View {
        let files = repository.files.filter { paths.contains($0.path) }
        let usable = files.filter { !$0.conflicted }
        Button { repository.include(usable.map(\.path), true) } label: { Label(L("git.tree.include"), systemImage: Symbols.add) }.accessibilityIdentifier("git.changes.menu.include")
            .disabled(usable.allSatisfy { $0.inclusion == .full })
        Button { repository.include(usable.map(\.path), false) } label: { Label(L("git.tree.leaveOut"), systemImage: Symbols.remove) }.accessibilityIdentifier("git.changes.menu.leaveOut")
            .disabled(usable.allSatisfy { $0.inclusion == .none })
        Divider()
        Button { repository.discarding = usable.filter(\.hasUnstaged) } label: {
            Label(L(usable.count > 1 ? "git.discard.manyEllipsis" : "git.discard.ellipsis"), systemImage: Symbols.gitDiscard)
        }
        .disabled(!usable.contains(where: \.hasUnstaged) || repository.busy)
        .accessibilityIdentifier("git.changes.menu.discard")
        Divider()
        Button {
            NSWorkspace.shared.activateFileViewerSelecting(files.map { URL(fileURLWithPath: (repository.root as NSString).appendingPathComponent($0.path)) })
        } label: { Label(L("menu.showInFinder"), systemImage: Symbols.folder) }
            .accessibilityIdentifier("git.changes.menu.showInFinder")
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
        } label: { Label(L("git.changes.copyPath"), systemImage: Symbols.copy) }
            .accessibilityIdentifier("git.changes.menu.copyPath")
    }
}
