import SwiftUI

/// Changed files as a folder tree. Each checkbox says whether the file goes into the commit; a
/// folder's checkbox includes or leaves out everything inside it. Clicks show at once: the caller's
/// next list (after Git confirms) replaces them.
///
/// The list is a system `List` (an `NSTableView` underneath): only the rows on screen are built, so
/// thousands of files scroll smoothly. ↑/↓ move, space includes or leaves out, a double click on a
/// file does the same and on a folder opens or closes it.
struct GitChangeTreeView<RowMenu: View>: View {
    let changes: [GitChange]
    /// Path of the file shown in the diff.
    @Binding var selection: String?
    /// Include (true) or leave out (false) these files; folders send all their files at once.
    let onInclude: ([GitChange], Bool) -> Void
    /// «Resolver…» of a file in conflict; without it the button is not shown.
    var onResolve: ((GitChange) -> Void)?
    /// The menu of a file row.
    @ViewBuilder var rowMenu: (GitChange) -> RowMenu

    @State private var nodes: [GitChangeNode] = []
    @State private var built = false
    @State private var collapsed: Set<String> = []
    @State private var focused: String?
    /// Checkbox clicks not yet confirmed by the caller's list.
    @State private var pending: [String: Bool] = [:]
    /// Bumped on every click: restarts the cleanup so it never erases marks that were just set.
    @State private var pendingStamp = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let rows = GitChangeTree.flatten(nodes, collapsed: collapsed)
        VStack(spacing: 0) {
            header
            Divider()
            if changes.isEmpty {
                ContentUnavailableView {
                    Label(L("git.tree.emptyTitle"), systemImage: Symbols.noChanges)
                } description: {
                    Text(L("git.tree.emptyDetail"))
                }
            } else if !built {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(rows, selection: $focused) { row in
                    rowView(row)
                }
                .listStyle(.sidebar)
                .themedScroll()
                .accessibilityIdentifier("git.tree.list")
                .contextMenu(forSelectionType: String.self) { ids in
                    if let id = ids.first, let change = changes.first(where: { $0.path == id }) { rowMenu(change) }
                } primaryAction: { ids in
                    guard let id = ids.first, let row = rows.first(where: { $0.id == id }) else { return }
                    if row.node.isFolder { toggleFolder(id) } else { include(row.node.changes) }
                }
                .onKeyPress(.space) {
                    guard let id = focused, let row = rows.first(where: { $0.id == id }) else { return .ignored }
                    include(row.node.changes)
                    return .handled
                }
            }
        }
        .task(id: changes) {
            let input = changes
            // Thousands of paths are sorted off the main thread; a few hundred take under a millisecond.
            nodes = input.count > 1_500 ? await Task.detached(priority: .userInitiated) { GitChangeTree.build(input) }.value : GitChangeTree.build(input)
            built = true
            // Drop the marks the new list already agrees with.
            pending = pending.filter { path, included in
                guard let change = input.first(where: { $0.path == path }) else { return false }
                return included ? change.inclusion != .full : change.inclusion != .none
            }
        }
        .task(id: pendingStamp) {
            guard !pending.isEmpty else { return }
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { pending = [:] }
        }
        .onChange(of: focused) { _, id in
            if let id, !id.hasSuffix("/") { selection = id }
        }
        .onChange(of: selection, initial: true) { _, path in
            if focused != path { focused = path }
        }
    }

    // MARK: Header

    private var header: some View {
        let total = changes.filter { !$0.isConflict }
        let included = total.filter { GitChangeTree.inclusion(of: [$0], pending: pending) != .none }.count
        return HStack(spacing: 8) {
            GitInclusionCheckbox(state: GitChangeTree.inclusion(of: changes, pending: pending), label: L("git.tree.includeAll")) { include(total, $0) }
                .disabled(total.isEmpty)
                .accessibilityIdentifier("git.tree.includeAll")
            Text(L("git.tree.title")).font(.uiCallout.weight(.semibold))
            Text("\(included)/\(total.count)").font(.uiCaption.monospacedDigit()).foregroundStyle(.secondary)
                .accessibilityLabel(String(format: L("git.tree.countLabel"), included, total.count))
            Spacer(minLength: 0)
            Menu {
                Button { setCollapsed([]) } label: { Label(L("git.tree.expandAll"), systemImage: Symbols.expandAll) }.accessibilityIdentifier("git.tree.expandAll")
                Button { setCollapsed(GitChangeTree.folderIDs(nodes)) } label: { Label(L("git.tree.collapseAll"), systemImage: Symbols.collapseAll) }.accessibilityIdentifier("git.tree.collapseAll")
            } label: {
                Label(L("git.tree.more"), systemImage: Symbols.more).labelStyle(.iconOnly)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(L("git.tree.more"))
            .accessibilityIdentifier("git.tree.more")
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 34)
    }

    // MARK: Rows

    private func rowView(_ row: GitChangeTree.Row) -> some View {
        let node = row.node
        let state = GitChangeTree.inclusion(of: node.changes, pending: pending)
        return GitChangeTreeRow(
            id: node.id, name: node.name, change: node.change, depth: row.depth, collapsed: collapsed.contains(node.id), state: state,
            includedCount: node.isFolder ? node.changes.filter { GitChangeTree.inclusion(of: [$0], pending: pending) != .none }.count : 0,
            fileCount: node.changes.count, stats: GitLineStats(additions: node.additions, deletions: node.deletions),
            onToggleFolder: { toggleFolder(node.id) }, onInclude: { include(node.changes, $0) },
            onResolve: onResolve.flatMap { resolve in node.change.map { change in { resolve(change) } } })
        .tag(node.id)
        .accessibilityIdentifier("git.tree.row.\(node.id)")
    }

    private func toggleFolder(_ id: String) {
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) {
            if collapsed.contains(id) { collapsed.remove(id) } else { collapsed.insert(id) }
        }
    }

    private func setCollapsed(_ ids: Set<String>) {
        withAnimation(reduceMotion ? nil : .snappy) { collapsed = ids }
    }

    /// Everything in the commit → leave it out; otherwise put the rest in.
    private func include(_ files: [GitChange]) {
        include(files, GitChangeTree.inclusion(of: files, pending: pending) != .full)
    }

    private func include(_ files: [GitChange], _ value: Bool) {
        let candidates = files.filter { !$0.isConflict }
        guard !candidates.isEmpty else { return }
        for file in candidates { pending[file.path] = value }
        pendingStamp &+= 1
        onInclude(candidates, value)
    }
}

extension GitChangeTreeView where RowMenu == EmptyView {
    init(changes: [GitChange], selection: Binding<String?>, onInclude: @escaping ([GitChange], Bool) -> Void, onResolve: ((GitChange) -> Void)? = nil) {
        self.init(changes: changes, selection: selection, onInclude: onInclude, onResolve: onResolve) { _ in EmptyView() }
    }
}

/// A system checkbox with the mixed state of a folder that is partly in the commit.
struct GitInclusionCheckbox: View {
    let state: GitInclusion
    let label: String
    let action: (Bool) -> Void

    var body: some View {
        // Two sources, «all in» and «some in»: equal they read on or off, different they read mixed.
        // A click sets both; only the first one acts.
        let sources = [Binding(get: { state == .full }, set: { action($0) }), Binding(get: { state != .none }, set: { _ in })]
        Toggle(sources: sources, isOn: \.self) { Text(label) }
            .toggleStyle(.checkbox)
            .labelsHidden()
            .help(label)
    }
}

/// One row of the tree: a folder with its counts, or a file with its icon, kind and line counts.
private struct GitChangeTreeRow: View {
    let id: String
    let name: String
    let change: GitChange?
    let depth: Int
    let collapsed: Bool
    let state: GitInclusion
    let includedCount: Int
    let fileCount: Int
    let stats: GitLineStats
    let onToggleFolder: () -> Void
    let onInclude: (Bool) -> Void
    let onResolve: (() -> Void)?

    var body: some View {
        HStack(spacing: 7) {
            Group {
                if change == nil {
                    Button(action: onToggleFolder) {
                        Label(L(collapsed ? "git.tree.expand" : "git.tree.collapse"), systemImage: Symbols.disclosure).labelStyle(.iconOnly)
                            .font(.uiCaption.weight(.bold)).foregroundStyle(.secondary)
                            .rotationEffect(.degrees(collapsed ? 0 : 90))
                    }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("git.tree.disclosure.\(id)")
                } else {
                    Color.clear
                }
            }
            .frame(width: 12)
            if let change, change.isConflict {
                Image(systemName: Symbols.warning).foregroundStyle(GitChangeKind.conflict.color).accessibilityHidden(true)
            } else {
                GitInclusionCheckbox(state: state, label: L(state == .full ? "git.tree.leaveOut" : "git.tree.include"), action: onInclude)
                    .accessibilityIdentifier("git.tree.check.\(id)")
            }
            if let change {
                FileTypeIcon(path: change.path, size: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).font(.uiBody).lineLimit(1).truncationMode(.middle)
                        .strikethrough(change.kind == .deleted, color: .secondary)
                    if let original = change.originalPath {
                        Text(String(format: L("git.diff.movedFrom"), original)).font(.uiCaption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.head)
                    }
                }
                .help(change.path)
                Spacer(minLength: 4)
                if change.isConflict, let onResolve {
                    Button(action: onResolve) { Label(L("git.tree.resolve"), systemImage: Symbols.warning) }
                        .buttonStyle(.bordered).controlSize(.small)
                        .accessibilityIdentifier("git.tree.resolve.\(change.path)")
                }
                GitChangeKindBadge(kind: change.kind, compact: true)
            } else {
                Image(systemName: Symbols.folder).foregroundStyle(.secondary).accessibilityHidden(true)
                Text(name).font(.uiBody.weight(.medium)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                Text("\(includedCount)/\(fileCount)").font(.uiCaption.monospacedDigit()).foregroundStyle(.secondary)
                    .accessibilityLabel(String(format: L("git.tree.countLabel"), includedCount, fileCount))
            }
            if !stats.isEmpty { GitStatsBadge(stats: stats) }
        }
        .padding(.leading, CGFloat(depth) * 16)
        .accessibilityElement(children: .contain)
        .accessibilityValue(change == nil ? L(collapsed ? "git.diff.collapsed" : "git.diff.expanded")
                            : L(state == .full ? "git.tree.included" : state == .partial ? "git.tree.partial" : "git.tree.leftOut"))
        .accessibilityAction(named: L(state == .full ? "git.tree.leaveOut" : "git.tree.include")) { onInclude(state != .full) }
    }
}
