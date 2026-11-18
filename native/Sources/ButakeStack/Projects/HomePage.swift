import AppKit
import SwiftUI

/// ⌘F in Inicio: which projects the text keeps. A pure rule, so it can be tested without a window.
enum HomeFilter {
    /// A project matches by its name, address, kind or folder on disk.
    static func admits(_ project: Project, query: String) -> Bool {
        let text = query.trimmingCharacters(in: .whitespaces)
        return text.isEmpty || [project.title, project.domain, project.tech.title, project.path].contains { $0.localizedCaseInsensitiveContains(text) }
    }
    /// The projects of a folder to show: all of them when the folder's own name matches, else the ones that match.
    static func shown(_ projects: [Project], folder: String?, query: String) -> [Project] {
        let text = query.trimmingCharacters(in: .whitespaces)
        if text.isEmpty || folder?.localizedCaseInsensitiveContains(text) == true { return projects }
        return projects.filter { admits($0, query: text) }
    }
}

/// Inicio: one line of summary, what needs doing (only when something does), the projects as a
/// list with columns grouped by folder, and the services in use. Stack's state itself is said by
/// the status bar.
struct HomePage: View {
    @Bindable var store: StackStore
    var services: [String] { Route.allEngines.filter { store.engineVersion($0) != nil } }
    /// How far a folder inside another is moved in, as in the sidebar.
    static let indent: CGFloat = 20
    /// What ⌘F types into: filters the projects and folders on this page as you write.
    #if DEBUG
    @State private var filter = QAHooks.homeFilter ?? ""
    #else
    @State private var filter = ""
    #endif
    @State private var filterRequests = 0
    @State private var selection: String?
    @State private var columns = HomeColumns()
    var query: String { filter.trimmingCharacters(in: .whitespaces) }
    var served: [Project] { store.projects.filter(\.isServed) }
    var online: Int { store.projects.filter { store.sitePhase($0) == .running }.count }

    var body: some View {
        Group {
            if store.projects.isEmpty { emptyPage } else { projectList }
        }
        .background(Brand.background)
        .focusedSceneValue(\.textFinder, store.projects.isEmpty ? nil : TextFinderRequest { filterRequests += 1 })
        .toolbar {
            if store.shownFolders.count > 1 {
                if #available(macOS 26, *) {
                    // Apart from the window's own «+» (new project).
                    ToolbarSpacer(.fixed, placement: .primaryAction)
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        FolderMenuItems(store: store)
                    } label: {
                        Label(L("home.more"), systemImage: Symbols.more).labelStyle(.iconOnly)
                    }
                    .help(L("home.more")).accessibilityIdentifier("home.more")
                }
            }
        }
    }

    /// No projects: the way to the first one, and the services if there are any.
    private var emptyPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                let state = store.stackState
                if state.needsAction { HomeHeader(store: store, state: state) }
                noProjects(prominent: !state.needsAction)
                if !services.isEmpty { HomeServices(store: store, names: services) }
            }
            .padding(28)
            .frame(maxWidth: 1680, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .rememberScroll("page.home")
    }

    private var summary: some View {
        let total = served.isEmpty ? store.projects.count : served.count
        let warnings = store.attentionOn.reduce(0) { $0 + $1.items.count }
        let count = services.count
        let parts = [count == 0 ? nil : count == 1 ? L("home.summary.service") : String(format: L("home.summary.services"), count),
                     warnings == 0 ? L("home.summary.noWarnings") : warnings == 1 ? L("home.summary.warning") : String(format: L("home.summary.warnings"), warnings)]
        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(String(format: L("home.summary.running"), online, total)).font(.uiTitle2.weight(.semibold))
            Text(parts.compactMap { $0 }.joined(separator: " · ")).font(.uiCallout).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            FilterField(text: $filter, identifier: "home.filter", prompt: L("home.filter"), focusRequests: filterRequests)
                .frame(maxWidth: 260)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home.summary")
    }

    /// One row of a folder's list: the project, draggable to a folder of the sidebar as before.
    private func row(_ project: Project, depth: Int) -> some View {
        HomeProjectRow(store: store, project: project, columns: columns)
            .tag(project.id)
            .draggable(project.id)
            .listRowInsets(EdgeInsets(top: 2, leading: 12 + CGFloat(depth) * HomePage.indent, bottom: 2, trailing: 12))
    }

    private var projectList: some View {
        let filtering = !query.isEmpty
        return List(selection: $selection) {
            let state = store.stackState
            if state.needsAction { HomeHeader(store: store, state: state).staticRow() }
            summary.staticRow()
            if !store.attentionOn.isEmpty { HomeAttention(store: store).staticRow() }
            HomeColumnHeader(columns: columns).staticRow(top: 6)
            // The folders as the sidebar draws them: each inside the one it is in, a folder closed hides
            // everything under it, and a folder counts every project inside it.
            ForEach(store.folderTree) { entry in
                let group = entry.group
                let inside = HomeFilter.shown(store.projects(inside: group), folder: group.name, query: query)
                if !inside.isEmpty && (filtering || store.ancestors(of: group).allSatisfy({ store.folderOpen($0.id) })) {
                    let members = HomeFilter.shown(store.projects(in: group), folder: group.name, query: query)
                    Section {
                        if filtering || store.folderOpen(group.id) { ForEach(members) { row($0, depth: entry.depth) } }
                    } header: {
                        // A project of several parts says so and leads to its page.
                        HStack(spacing: 4) {
                            HomeFolderHeader(store: store, id: group.id, title: group.name,
                                             symbol: group.isProject ? Symbols.compositeProject : Symbols.folder, members: inside)
                            if group.isProject {
                                Button { store.openComposite(group.id) } label: {
                                    Label(L("composite.open"), systemImage: Symbols.compositeProject).labelStyle(.iconOnly)
                                }
                                .buttonStyle(.borderless)
                                .help(L("composite.open"))
                                .accessibilityIdentifier("home.folder.\(group.id).open")
                            }
                        }
                        .padding(.leading, CGFloat(entry.depth) * HomePage.indent)
                    }
                }
            }
            let loose = HomeFilter.shown(store.ungroupedProjects, folder: nil, query: query)
            if filtering && loose.isEmpty && !store.folderTree.contains(where: { !HomeFilter.shown(store.projects(inside: $0.group), folder: $0.group.name, query: query).isEmpty }) {
                ContentUnavailableView.search(text: query).staticRow()
            }
            if !loose.isEmpty {
                // Named, and so closable, only next to folders that show projects.
                let named = store.groups.contains(where: { !store.projects(in: $0).isEmpty })
                Section {
                    if !named || filtering || store.folderOpen(StackStore.looseFolder) { ForEach(loose) { row($0, depth: 0) } }
                } header: {
                    if named {
                        HomeFolderHeader(store: store, id: StackStore.looseFolder, title: L("groups.loose"), symbol: Symbols.project, members: loose)
                    }
                }
            }
            if !services.isEmpty { HomeServices(store: store, names: services).staticRow(top: 18) }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first, let project = store.projects.first(where: { $0.id == id }) {
                ProjectMenuItems(store: store, project: project)
            }
        } primaryAction: { ids in
            if let id = ids.first { Motion.run(.smooth(duration: 0.3)) { store.openSite(id) } }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            var next = HomeColumns(width: width)
            // Without Git data for any project the column would be empty.
            if !store.projects.contains(where: { store.git[$0.id] != nil }) { next.branch = false }
            if next != columns { columns = next }
        }
        .rememberScroll("page.home")
        .accessibilityIdentifier("home.list")
    }

    /// No projects yet: the way to the first one. Its button is the main one unless the header has
    /// something more urgent.
    private func noProjects(prominent: Bool) -> some View {
        ContentUnavailableView {
            Label(L("home.empty"), systemImage: Symbols.project)
        } description: {
            Text(L("home.noSites"))
        } actions: {
            HStack {
                let create = Button { store.showNewProject = true } label: { Label(L("menu.newProject"), systemImage: Symbols.add) }
                    .accessibilityIdentifier("home.newProject")
                if prominent { create.buttonStyle(.borderedProminent) } else { create.buttonStyle(.bordered) }
                Button { store.chooseFolder() } label: { Label(L("menu.addExisting"), systemImage: Symbols.newFolder) }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("home.addExisting")
                Button { store.showClone = true } label: { Label(L("menu.cloneRepository"), systemImage: Symbols.gitClone) }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("home.clone")
            }
            .fixedSize()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }
}

private extension View {
    /// A row of the page that is not a project: no separator, no highlight, never selected.
    func staticRow(top: CGFloat = 4) -> some View {
        listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: top, leading: 12, bottom: 4, trailing: 12))
            .selectionDisabled()
    }
}

/// Plegar / Desplegar todas las carpetas: Inicio's «⋯» and Visualización.
struct FolderMenuItems: View {
    let store: StackStore
    var body: some View {
        let folders = store.shownFolders + store.groups.map(\.id)
        Button { store.setAllFolders(open: false) } label: { Label(L("groups.collapseAll"), systemImage: Symbols.collapseAll) }
            .disabled(folders.allSatisfy { !store.folderOpen($0) })
            .accessibilityIdentifier("groups.collapseAll")
        Button { store.setAllFolders(open: true) } label: { Label(L("groups.expandAll"), systemImage: Symbols.expandAll) }
            .disabled(folders.allSatisfy(store.folderOpen))
            .accessibilityIdentifier("groups.expandAll")
    }
}

/// The title of a folder in Inicio: a button that closes and opens its projects, with the sidebar's
/// chevron (right when closed, down when open). Closed, it says how many of them are running.
private struct HomeFolderHeader: View {
    @Bindable var store: StackStore
    let id: String
    let title: String
    let symbol: String
    let members: [Project]
    var body: some View {
        let open = store.folderOpen(id)
        let running = members.filter { store.sitePhase($0) == .running }.count
        // No animation of its own: the rows appear and leave at once (Reduce Motion or not).
        Button { store.setFolder(id, open: !open) } label: {
            HStack(spacing: 8) {
                Label { Text(title) } icon: { IconTile(symbol: symbol, size: TextScale.points(20)) }
                    .font(.uiHeadline).foregroundStyle(.secondary)
                Text("\(members.count)").font(.uiSubheadline.weight(.semibold)).foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 1).background(Color.primary.opacity(0.07), in: Capsule())
                if !open && running > 0 {
                    Text(String(format: L("groups.running"), running)).font(.uiCaption).foregroundStyle(.secondary)
                }
                Image(systemName: Symbols.disclosure).font(.uiCaption.weight(.semibold)).foregroundStyle(.secondary)
                    .rotationEffect(.degrees(open ? 90 : 0))
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 3).padding(.horizontal, 6)
        }
        .buttonStyle(HighlightButtonStyle())
        .padding(.horizontal, -6)
        .help(open ? L("groups.collapse") : L("groups.expand"))
        .accessibilityValue(open ? L("groups.open") : L("groups.closed"))
        .accessibilityHint(open ? L("groups.collapse") : L("groups.expand"))
        .accessibilityIdentifier("home.folder.\(id == StackStore.looseFolder ? "loose" : id).toggle")
    }
}

/// The header of Inicio, only while there is something to do: what is wrong in a line and the one
/// action that fixes it.
private struct HomeHeader: View {
    @Bindable var store: StackStore
    let state: StackState
    var body: some View {
        let setup = state == .setup
        HStack(spacing: 16) {
            IconTile(symbol: setup ? Symbols.setup : Symbols.server, color: setup ? TileColor.warning : TileColor.error, size: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(setup ? L("setup.pending") : L("home.stopped")).font(.uiTitle2.weight(.semibold))
                Text(setup ? L("home.setupDetail") : L("home.stoppedDetail")).font(.uiCallout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer(minLength: 12)
            if setup {
                Button { store.showSetup = true } label: { Label(L("menu.setup"), systemImage: Symbols.setup) }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .accessibilityIdentifier("home.setup")
            } else {
                Button { Task { await store.startDaemon() } } label: { Label(L("stackState.start"), systemImage: Symbols.start) }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(store.busy != nil)
                    .accessibilityIdentifier("home.start")
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .workSurface(radius: 18)  // radius 18: outside the Radius scale, kept as it was
        .accessibilityIdentifier("home.header")
    }
}

struct SectionHeading: View {
    let title: String
    var detail: String?
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(.uiTitle3.weight(.semibold))
            if let detail { Text(detail).font(.uiCaption).foregroundStyle(.secondary) }
        }
    }
}
