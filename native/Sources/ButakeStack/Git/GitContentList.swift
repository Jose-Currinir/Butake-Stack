import SwiftUI

extension Symbols {
    /// The system's mark of a control that opens a choice (a pop-up button).
    static let gitSelector = "chevron.up.chevron.down"
}

/// The Git tool's content column. With a repository open: the repository selector on top and,
/// under it, the repository's sidebar (`GitSidebar`). With none: the list of
/// repositories itself, ready to open one.
struct GitContentList: View {
    @Bindable var tool: GitTool

    var body: some View {
        Group {
            if !tool.requirement.ready {
                Color.clear
            } else if let repository = tool.repository {
                VStack(spacing: 0) {
                    GitRepositoryPicker(tool: tool, repository: repository)
                    Divider()
                    GitSidebar(tool: tool, repository: repository).id(repository.root)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                GitRepositoryChooser(tool: tool) {}
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The header of the open repository, as a selector: its name, the branch and the folder under it,
/// and the system's selector mark. Pressing it lists the repositories to change to another.
struct GitRepositoryPicker: View {
    @Bindable var tool: GitTool
    let repository: GitRepository
    @State private var open = false

    private var subtitle: String {
        let folder = (repository.root as NSString).deletingLastPathComponent.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        return "\(repository.branchTitle) · \(folder)"
    }

    var body: some View {
        Button { open = true } label: {
            HStack(spacing: 8) {
                IconTile(symbol: Symbols.git, size: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(repository.snapshot.name).font(.uiHeadline).lineLimit(1).truncationMode(.middle)
                    Text(subtitle).font(.uiCaption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 4)
                Image(systemName: Symbols.gitSelector).font(.uiCaption.weight(.semibold)).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.quaternary.opacity(0.6)))
            .contentShape(Rectangle())
        }
        .buttonStyle(HighlightButtonStyle())
        .padding(.horizontal, 10).padding(.vertical, 8)
        .help(L("git.repo.changeHelp"))
        .accessibilityLabel(String(format: L("git.repo.changeLabel"), repository.snapshot.name))
        .accessibilityIdentifier("git.repo.picker")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            GitRepositoryChooser(tool: tool) { open = false }
                .frame(minWidth: 340, idealWidth: 380, minHeight: 300, idealHeight: 440)
        }
    }
}

/// The repositories the tool knows: Stack's projects with a repository, the ones added by hand and
/// the recent ones, with search and «Agregar repositorio…» at the foot. In the content column when
/// none is open, and in the selector's popover to change.
struct GitRepositoryChooser: View {
    @Bindable var tool: GitTool
    /// After choosing (closes the popover).
    let chosen: () -> Void
    @State private var search = ""

    private func matches(_ entry: GitRepositoryEntry) -> Bool {
        search.isEmpty || entry.name.localizedCaseInsensitiveContains(search) || entry.path.localizedCaseInsensitiveContains(search)
    }

    /// Opened lately and not already listed as a project or an added repository.
    private var recent: [GitRepositoryEntry] {
        let known = Set(tool.entries.map(\.path))
        return tool.list.recent.filter { !known.contains($0.path) }
            .map { GitRepositoryEntry(path: $0.path, name: $0.name, project: nil, missing: $0.missing) }
    }

    var body: some View {
        // A project of several parts gathers its repositories under its name; the rest as before.
        let all = tool.entries
        let composites = StackStore.shared.composites.map { ($0, tool.entries(of: $0, in: all).filter(matches)) }.filter { !$0.1.isEmpty }
        let grouped = Set(composites.flatMap { $0.1.map(\.path) })
        let projects = all.filter { $0.project != nil && matches($0) && !grouped.contains($0.path) }
        let added = all.filter { $0.project == nil && matches($0) && !grouped.contains($0.path) }
        let recents = recent.filter(matches)
        VStack(spacing: 0) {
            FilterField(text: $search, identifier: "git.repo.search", prompt: L("git.repo.search")).padding(10)
            List {
                ForEach(composites, id: \.0.id) { group, entries in
                    Section { ForEach(entries) { row($0) } } header: { GitCompositeHeader(tool: tool, group: group, entries: entries) }
                }
                if !projects.isEmpty { Section(L("git.repo.projects")) { ForEach(projects) { row($0) } } }
                if !added.isEmpty { Section(L("git.repo.added")) { ForEach(added) { row($0) } } }
                if !recents.isEmpty { Section(L("git.repo.recent")) { ForEach(recents) { row($0) } } }
            }
            .listStyle(.sidebar)
            .themedScroll()
            .overlay {
                if composites.isEmpty && projects.isEmpty && added.isEmpty && recents.isEmpty {
                    if search.isEmpty {
                        ContentUnavailableView(L("git.empty.title"), systemImage: Symbols.git, description: Text(L("git.repo.listEmpty")))
                    } else {
                        ContentUnavailableView.search(text: search)
                    }
                }
            }
            .accessibilityIdentifier("git.repo.list")
        }
        .task { await tool.loadList(); await tool.loadSummaries() }
    }

    private func row(_ entry: GitRepositoryEntry) -> some View {
        Button {
            chosen()
            Task { await tool.open(entry.path) }
        } label: {
            GitRepositoryRow(entry: entry, summary: tool.summary(of: entry), current: tool.repository?.root == entry.path)
                .contentShape(Rectangle())
        }
        .buttonStyle(HighlightButtonStyle())
        .disabled(entry.missing || tool.opening != nil)
        .contextMenu {
            Button { chosen(); Task { await tool.open(entry.path) } } label: { Label(L("common.open"), systemImage: Symbols.forward) }
                .disabled(entry.missing || tool.opening != nil)
                .accessibilityIdentifier("git.repo.openRow.\(entry.name)")
            Button { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: entry.path) } label: { Label(L("menu.showInFinder"), systemImage: Symbols.folder) }.accessibilityIdentifier("git.repo.showInFinder.\(entry.name)")
            Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(entry.path, forType: .string) } label: { Label(L("git.changes.copyPath"), systemImage: Symbols.copy) }
                .accessibilityIdentifier("git.repo.copyPath.\(entry.name)")
            let fromProject = entry.project == nil ? tool.composite(of: entry).flatMap { $0.repositories.contains(entry.path) ? $0 : nil } : nil
            let forgettable = entry.project == nil && tool.list.added.contains(where: { $0.path == entry.path })
            if fromProject != nil || forgettable {
                Divider()
                if let group = fromProject {
                    Button { StackStore.shared.removeRepository(entry.path, from: group.id) } label: {
                        Label(L("composite.git.remove"), systemImage: Symbols.remove)
                    }
                    .accessibilityIdentifier("git.repo.removeFromProject.\(entry.name)")
                }
                if forgettable {
                    Button { Task { await tool.forget(entry) } } label: { Label(L("git.repo.forget"), systemImage: Symbols.remove) }.accessibilityIdentifier("git.repo.forget.\(entry.name)")
                }
            }
        }
        .accessibilityIdentifier("git.repo.row.\(entry.name)")
    }
}

/// The title of a project of several parts in the repository list: its name and, when something
/// needs fixing in any of its repositories, the sum.
struct GitCompositeHeader: View {
    let tool: GitTool
    let group: ProjectGroup
    let entries: [GitRepositoryEntry]
    var body: some View {
        let problems = entries.compactMap { tool.summary(of: $0)?.attention }.reduce(0, +)
        HStack(spacing: 6) {
            Text(group.name).lineLimit(1)
            Spacer()
            if problems > 0 {
                Label(String(problems), systemImage: Symbols.warning).font(.uiCaption.monospacedDigit()).foregroundStyle(Brand.warningText)
                    .help(String(format: L("git.problems.count"), problems))
                    .accessibilityIdentifier("git.repo.composite.problems.\(group.id)")
            }
        }
        .accessibilityIdentifier("git.repo.composite.\(group.id)")
    }
}

/// A repository: name, branch, pending changes, ↓↑ and a mark when something needs attention.
struct GitRepositoryRow: View {
    let entry: GitRepositoryEntry
    let summary: GitRepositorySummary?
    let current: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: current ? Symbols.selected : Symbols.git)
                .foregroundStyle(current ? Brand.accent : .secondary).frame(width: 18).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name).font(.uiBody).lineLimit(1)
                Text(detail).font(.uiCaption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 4)
            if entry.missing {
                Image(systemName: Symbols.missingFolder).foregroundStyle(Brand.warning).help(L("git.repo.missing"))
            } else if let summary {
                if summary.problems > 0 {
                    Label(String(summary.problems), systemImage: Symbols.warning).font(.uiCaption.monospacedDigit()).foregroundStyle(Brand.warningText)
                        .help(String(format: L("git.problems.count"), summary.problems))
                } else if summary.unfinished {
                    Image(systemName: Symbols.warning).foregroundStyle(Brand.warning).help(L("git.repo.unfinished"))
                }
                if summary.behind > 0 { Text(String(format: L("git.repo.behind"), summary.behind)).font(.uiCaption.monospacedDigit()).foregroundStyle(.secondary) }
                if summary.ahead > 0 { Text(String(format: L("git.repo.ahead"), summary.ahead)).font(.uiCaption.monospacedDigit()).foregroundStyle(.secondary) }
            }
        }
        .padding(.vertical, 2)
        .help(entry.path)
        .accessibilityElement(children: .combine)
    }

    private var detail: String {
        guard !entry.missing else { return L("git.repo.missing") }
        guard let summary else { return entry.path.replacingOccurrences(of: NSHomeDirectory(), with: "~") }
        let branch = summary.branch.isEmpty ? L("git.detached") : summary.branch
        let changes = summary.changes == 0 ? L("git.clean") : String(format: L("git.changesCount"), summary.changes)
        return "\(branch) · \(changes)"
    }
}
