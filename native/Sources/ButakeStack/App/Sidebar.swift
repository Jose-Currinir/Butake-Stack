import AppKit
import SwiftUI

struct Sidebar: View {
    @Bindable var store: StackStore
    #if DEBUG
    @State var search = QAHooks.sidebarSearch ?? ""
    #else
    @State var search = ""
    #endif
    @FocusState private var searchFocused: Bool
    @AppStorage("sidebar.closedSections") var closedSectionsRaw = ""
    // Live copy, saved right after each change. Folders keep theirs in the store, shared with Inicio.
    // Sections an older version let close (Servicios, Herramientas…) open again: they no longer close.
    @State var closedSections = SidebarLayout.migrateClosedSections(UserDefaults.standard.string(forKey: "sidebar.closedSections") ?? "")
    /// How far a folder's projects sit in from the folder, as one level of a Finder outline.
    static let indent: CGFloat = 14
    func matches(_ text: String) -> Bool { search.isEmpty || text.localizedCaseInsensitiveContains(search) }
    var body: some View {
        // Rows follow the sidebar size of macOS (System Settings › Appearance), not ⌘+ / ⌘−, like Finder and Mail.
        List(selection: selection) {
            if search.isEmpty {
                // A section without a title, like the first one of Finder's sidebar: the list leaves
                // the same space under the search field as before every other section.
                // Every row has its tile in the same column; Inicio carries the app's mark.
                Section {
                    Label { Text(L("route.home")) } icon: { BrandMark(size: 18) }
                        .tag(SidebarRow.home).accessibilityIdentifier("route.home")
                }
            }
            let sites = store.projects.filter { matches($0.title) || matches($0.domain) }
            // Always there while not searching: projects are dropped on its title to leave a folder.
            if !sites.isEmpty || search.isEmpty {
                Section(isExpanded: sectionOpen("sites")) {
                    // Folders are rows of the list, not an outline: an outline reserves a column for its
                    // disclosure triangles in every row, search field included, which then no longer lines up
                    // with the selection.
                    // Folders follow the disk: each one nested in the one it is in, as deep as the disk goes.
                    // A folder closed hides everything under it.
                    let shown = shownFolders
                    ForEach(store.folderTree) { entry in
                        let group = entry.group
                        let members = store.projects(in: group).filter { matches($0.title) || matches($0.domain) || matches(group.name) }
                        if shown.contains(group.id) && store.ancestors(of: group).allSatisfy({ expanded($0.id) }) {
                            let open = expanded(group.id)
                            if group.isProject {
                                // A project of several parts is a row of the list: it opens its page, and
                                // its chevron (a button at the end of the row) shows or hides its parts.
                                GroupRow(store: store, group: group, members: store.projects(in: group), open: open,
                                         toggle: { setExpanded(group.id, !open) }) { setExpanded(group.id, true) }
                                    .padding(.leading, CGFloat(entry.depth) * Self.indent)
                                    .tag(SidebarRow.composite(group.id))
                                    .accessibilityIdentifier("sidebar.group.\(group.id)")
                            } else {
                                Button { setExpanded(group.id, !open) } label: {
                                    GroupRow(store: store, group: group, members: store.projects(in: group), open: open) { setExpanded(group.id, true) }
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(HighlightButtonStyle())
                                .padding(.leading, CGFloat(entry.depth) * Self.indent)
                                .accessibilityHint(open ? L("groups.collapse") : L("groups.expand"))
                                .accessibilityIdentifier("sidebar.group.\(group.id)")
                                .selectionDisabled()
                            }
                            if open {
                                let inset = CGFloat(entry.depth + 1) * Self.indent
                                ForEach(members) { siteRow($0, in: group.id).padding(.leading, inset) }
                                if search.isEmpty {
                                    ForEach(store.newRepositories(in: group.id)) { newRepositoryRow($0).padding(.leading, inset) }
                                    if let suggestion = store.suggestion(for: group) { suggestionRow(suggestion, group: group).padding(.leading, inset) }
                                    if members.isEmpty && !store.groups.contains(where: { $0.parent == group.id }) && store.newRepositories(in: group.id).isEmpty {
                                        Text(L("groups.empty")).font(.caption).foregroundStyle(.tertiary)
                                            .padding(.leading, inset).selectionDisabled()
                                    }
                                }
                            }
                        }
                    }
                    ForEach(store.ungroupedProjects.filter { matches($0.title) || matches($0.domain) }) { siteRow($0, in: nil) }
                    if search.isEmpty { ForEach(store.newRepositories(in: nil)) { newRepositoryRow($0) } }
                } header: {
                    // Closed, the title says how many projects it holds: never an empty section.
                    SitesHeader(store: store, closed: !sectionOpen("sites").wrappedValue)
                }
            }
            // Herramientas: what is used, only the tools that are on, then Registros (base).
            let tools = SidebarLayout.toolRows(enabled: store.enabledPlugins.map(\.id)).filter { matches(Self.title(ofTool: $0)) }
            if !tools.isEmpty {
                Section {
                    ForEach(tools, id: \.self) { toolRow($0) }
                } header: { Text(L("sidebar.tools")) }
            }
            // Nube: the providers' accounts that are on; none, and the section is not there.
            let clouds = SidebarLayout.cloudRows(enabled: store.enabledPlugins.map(\.id)).filter { matches(Self.title(ofTool: $0)) }
            if !clouds.isEmpty {
                Section {
                    ForEach(clouds, id: \.self) { toolRow($0) }
                } header: { Text(L("sidebar.cloud")) }
            }
            // Componentes: what is installed on the Mac. Searching, the categories found are rows of their own.
            let components = Component.allCases.filter { matches($0.title) }
            let found = SidebarLayout.categories(matching: search)
            if !components.isEmpty || !found.isEmpty {
                Section {
                    ForEach(components, id: \.self) { component in
                        Label { Text(component.title) } icon: { TechLogo(tech: component.tech, size: 18) }
                            .tag(SidebarRow.component(component))
                            .accessibilityIdentifier("route.components.\(component.rawValue)")
                            .contextMenu { ComponentMenuItems(store: store, component: component) }
                    }
                    ForEach(found, id: \.self) { categoryRow($0) }
                } header: { Text(L("sidebar.components")) }
            }
        }
        .listStyle(.sidebar).themedScroll()
        // Proyecto › Quitar (⌘⌫) acts on the list only, never while typing in its search field.
        .focusedValue(\.sidebarProject, searchFocused ? nil : selectedProject)
        .background { if Brand.customBackgrounds { (Brand.theme.sidebar?.color ?? Brand.background).ignoresSafeArea() } }
        .searchable(text: $search, placement: .sidebar, prompt: L("menu.find"))
        .searchFocused($searchFocused)
        // The window opens on the list, not typing in the search field.
        .defaultFocus($searchFocused, false)
        // Retorno renames the selected project or folder, as in Finder; in the search field it does nothing here.
        .onKeyPress(.return) {
            guard !searchFocused, let target = SidebarRename.target(for: store.route, projects: store.projects, groups: store.groups) else { return .ignored }
            switch target {
            case .project(let project): store.renaming = RenameRequest(project: project)
            case .folder(let id): store.groupNaming = .rename(id)
            }
            return .handled
        }
        // Edición › Buscar (⌘F).
        .onChange(of: store.findRequests) { searchFocused = true }
        #if DEBUG
        .task {
            await QAHooks.sidebarCollapse { target, open in
                if target.hasPrefix("folder:") { setExpanded(String(target.dropFirst("folder:".count)), open) }
                else { sectionOpen(target).wrappedValue = open }
            }
        }
        #endif
    }
}

/// What Retorno renames in the sidebar: the project or the folder (a project of several parts) selected.
enum SidebarRename {
    enum Target: Equatable { case project(Project), folder(String) }

    static func target(for route: Route, projects: [Project], groups: [ProjectGroup]) -> Target? {
        switch route {
        case .site(let id): projects.first { $0.id == id }.map(Target.project)
        case .composite(let id): groups.contains { $0.id == id } ? .folder(id) : nil
        default: nil
        }
    }
}

extension Sidebar {
    /// The list's selection: the row of the page on screen. A page of Componentes selects its
    /// component, or the category itself while the search shows it as a row.
    var selection: Binding<SidebarRow?> {
        Binding(get: {
            if !search.isEmpty, SidebarLayout.categories(matching: search).contains(store.route) { return .category(store.route) }
            return SidebarRow.of(store.route)
        }, set: { row in
            switch row {
            case .home: store.route = .home
            case .site(let id): store.route = .site(id); store.selectedSite = id
            case .composite(let id): store.openComposite(id)
            case .tool(let id): store.route = .tool(id)
            // The component's row opens its last category seen, unless one of its pages is on screen.
            case .component(let component): if Component.of(store.route)?.component != component { store.route = component.lastRoute() }
            case .category(let route): store.route = route
            case nil: break
            }
        })
    }
    /// The name of a tool's row: the catalog's, or Registros.
    static func title(ofTool id: String) -> String { id == "logs" ? Tech.of("logs").title : L("plugin.\(id).title") }
    func toolRow(_ id: String) -> some View {
        Label {
            HStack {
                Text(Self.title(ofTool: id)).lineLimit(1)
                Spacer()
                if id == "mail", let count = store.mailStatus?.count, count > 0 {
                    Text("\(count)").font(.caption.weight(.bold)).foregroundStyle(.secondary).monospacedDigit()
                }
            }
        } icon: { TechLogo(tech: .of(id), size: 18) }
            .tag(SidebarRow.tool(id))
            .accessibilityIdentifier("route.tool.\(id)")
            .contextMenu { ToolMenuItems(store: store, id: id) }
    }
    /// A category found by the search, with the component that holds it.
    func categoryRow(_ route: Route) -> some View {
        let (component, category) = Component.of(route)!
        return Label {
            HStack {
                Text(component.tech(of: category).title).lineLimit(1)
                Spacer()
                Text(component.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        } icon: { TechLogo(tech: component.tech(of: category), size: 18) }
            .tag(SidebarRow.category(route))
            .accessibilityIdentifier("route.\(route.storageValue.replacingOccurrences(of: ":", with: "."))")
            .contextMenu {
                Button { store.route = route } label: { Label(L("common.open"), systemImage: Symbols.forward) }
                    .accessibilityIdentifier("sidebar.menu.open.\(category)")
            }
    }
    var selectedProject: Project? {
        if case .site(let id) = store.route { return store.projects.first { $0.id == id } }
        return nil
    }
    /// A site in the sidebar. Dropping another site on it puts that one right before it, in the same folder
    /// (or out of any folder).
    func siteRow(_ project: Project, in group: String?) -> some View {
        Label {
            HStack {
                Text(project.title).lineLimit(1).foregroundStyle(project.isMissing ? .secondary : .primary)
                Spacer()
                if project.isMissing {
                    // Said in words: a project whose folder is not there is never lost in silence.
                    Text(L("missing.badge")).font(.caption).foregroundStyle(Brand.warningText).lineLimit(1)
                        .help(L("missing.title")).accessibilityIdentifier("route.site.missing.\(project.id)")
                } else {
                    // Open to anyone on the internet while shared (temporary or fixed address).
                    if store.isPublic(project) {
                        Image(systemName: Symbols.share).foregroundStyle(Brand.warning).help(L("share.sidebar"))
                            .accessibilityLabel(L("share.sidebar")).accessibilityIdentifier("route.site.shared.\(project.id)")
                    }
                    // A project without a server is never on: no state to show.
                    if project.isServed { StatusRing(phase: store.sitePhase(project), size: 10) }
                }
            }
        } icon: { TechLogo(tech: project.tech, size: 18) }
            .tag(SidebarRow.site(project.id)).accessibilityIdentifier("route.site.\(project.id)")
            .contextMenu { ProjectMenuItems(store: store, project: project) }
            .draggable(project.id) {
                Label(project.title, systemImage: Symbols.project).padding(6).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
            }
            .dropDestination(for: String.self) { ids, _ in
                for id in ids where id != project.id && (store.projects.contains(where: { $0.id == id }) || id.hasPrefix(StackStore.folderDragPrefix)) {
                    store.move(id, to: group, before: group == nil ? nil : project.id)
                }
                return true
            }
    }
    /// A repository of the disk that is not a project yet: offered, never added by itself.
    func newRepositoryRow(_ repository: NewRepository) -> some View {
        Label {
            HStack(spacing: 6) {
                Text(repository.title).lineLimit(1).foregroundStyle(.secondary)
                Spacer()
                Text(L("groups.newRepo")).font(.caption.weight(.semibold)).foregroundStyle(Brand.infoText)
                    .accessibilityIdentifier("sidebar.new.badge.\(repository.title)")
                Button(L("groups.newRepoAdd")) { Task { await store.openFolder(repository.path) } }
                    .buttonStyle(.borderless).font(.caption).foregroundStyle(Brand.accent)
                    .help(L("groups.newRepoHelp")).accessibilityIdentifier("sidebar.new.add.\(repository.title)")
            }
        } icon: { IconTile(symbol: Symbols.newFolder, size: 18) }
            .selectionDisabled().accessibilityIdentifier("sidebar.new.\(repository.title)")
            .contextMenu {
                Button { Task { await store.openFolder(repository.path) } } label: { Label(L("groups.newRepoAdd"), systemImage: Symbols.add) }
                Button { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: repository.path) } label: { Label(L("menu.showInFinder"), systemImage: Symbols.folder) }
            }
    }
    /// A folder whose repositories share a prefix: it may be a project of several parts.
    func suggestionRow(_ suggestion: MultipartSuggestion, group: ProjectGroup) -> some View {
        HStack(spacing: 6) {
            Text(L("groups.suggest")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                .help(suggestion.parts.joined(separator: ", "))
            Spacer()
            Button(L("groups.suggestConvert")) { store.setKind(group.id, .project) }
                .buttonStyle(.borderless).font(.caption).foregroundStyle(Brand.accent)
                .accessibilityIdentifier("sidebar.suggest.convert.\(group.id)")
        }
        .selectionDisabled().accessibilityIdentifier("sidebar.suggest.\(group.id)")
    }
    /// The folders the sidebar draws: all, or while searching those with a match and the ones they are in.
    var shownFolders: Set<String> {
        guard !search.isEmpty else { return Set(store.groups.map(\.id)) }
        var ids = Set<String>()
        for group in store.groups where store.projects(in: group).contains(where: { matches($0.title) || matches($0.domain) || matches(group.name) }) {
            ids.insert(group.id)
            ids.formUnion(store.ancestors(of: group).map(\.id))
        }
        return ids
    }
    /// Folders open unless the user closed them (here or in Inicio); all open while searching.
    func expanded(_ id: String) -> Bool { !search.isEmpty || store.folderOpen(id) }
    func setExpanded(_ id: String, _ open: Bool) { store.setFolder(id, open: open) }
    /// Sidebar sections open unless the user closed them; all open while searching. The outline
    /// animates its own disclosure (and honors Reduce Motion): no SwiftUI animation on top.
    func sectionOpen(_ id: String) -> Binding<Bool> {
        Binding(get: { !search.isEmpty || !closedSections.contains(id) }, set: { open in
            if open { closedSections.remove(id) } else { closedSections.insert(id) }
            closedSectionsRaw = closedSections.sorted().joined(separator: ",")
        })
    }
}

private extension View {
    /// Makes a folder draggable (on the disk only); `nil` leaves the row as it is.
    @ViewBuilder func draggableFolder(_ payload: String?, title: String) -> some View {
        if let payload {
            draggable(payload) {
                Label(title, systemImage: Symbols.folder).padding(6).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
            }
        } else { self }
    }
}

/// The title of Proyectos: dropping a project here takes it out of its folder.
private struct SitesHeader: View {
    let store: StackStore
    let closed: Bool
    @State private var targeted = false
    var body: some View {
        HStack {
            Text(L("route.sites"))
            Spacer()
            if closed {
                Text("\(store.projects.count)").monospacedDigit()
                    .help(String(format: L("sidebar.closedCount"), store.projects.count))
                    .accessibilityIdentifier("sidebar.sites.count")
            }
        }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(targeted ? Brand.accent.opacity(0.15) : .clear).padding(.horizontal, -4))
            .contextMenu {
                Button { store.groupNaming = .new(sites: []) } label: { Label(L("menu.newFolder"), systemImage: Symbols.newFolder) }
                    .accessibilityIdentifier("sidebar.newFolder")
            }
            .dropDestination(for: String.self) { ids, _ in
                for id in ids { store.move(id, to: nil) }
                return true
            } isTargeted: { targeted = $0 }
            .animated(.easeOut(duration: 0.15), value: targeted)
    }
}

/// A folder in the sidebar: name, how many of its sites are on, and its actions. A project of
/// several parts has its own tile, and its row opens its page.
private struct GroupRow: View {
    let store: StackStore
    let group: ProjectGroup
    let members: [Project]
    let open: Bool
    /// Shows or hides a project's parts; nil for a folder, whose whole row does it.
    var toggle: (() -> Void)?
    /// After a drop: the folder opens to show where the project went.
    let dropped: () -> Void
    @State private var targeted = false
    /// Its count and its running ones take every project inside it, folders within folders too.
    var inside: [Project] { store.projects(inside: group) }
    var running: Int { inside.filter { store.sitePhase($0) == .running }.count }
    var body: some View {
        Label {
            HStack(spacing: 6) {
                Text(group.name).lineLimit(1)
                Spacer()
                if running > 0 {
                    // White on solid green: it reads the same on a plain row and over the selection's
                    // color (green on a faint green could not be read on the selected row).
                    Text("\(running)").font(.caption.weight(.bold)).foregroundStyle(.white)
                        .padding(.horizontal, 5).padding(.vertical, 1).background(Brand.success, in: Capsule())
                        .help(String(format: L("groups.running"), running))
                }
                Text("\(inside.count)").font(.subheadline.weight(.medium)).foregroundStyle(.secondary).monospacedDigit()
                if let toggle {
                    // A project's row opens its page: its chevron is a button of its own, at the end of the row.
                    Button(action: toggle) {
                        Label(open ? L("composite.hideParts") : L("composite.showParts"), systemImage: Symbols.disclosure)
                            .labelStyle(.iconOnly).font(.caption.weight(.semibold))
                            .rotationEffect(.degrees(open ? 90 : 0))
                    }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
                    .help(open ? L("composite.hideParts") : L("composite.showParts"))
                    .accessibilityIdentifier("sidebar.group.toggle.\(group.id)")
                } else {
                    // The sidebar's own disclosure chevron, as on its section titles: right when closed, down when open.
                    Image(systemName: Symbols.disclosure).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .accessibilityHidden(true)
                }
            }
        } icon: {
            // The same tile as every other row, in the folder's color (a project's has its own);
            // open or closed shows only in the chevron.
            IconTile(symbol: group.isProject ? Symbols.compositeProject : Symbols.folder, size: 18)
        }
        .padding(.vertical, 1)
        .background(RoundedRectangle(cornerRadius: 6).fill(targeted ? Brand.accent.opacity(0.18) : .clear).padding(.horizontal, -6))
        .animated(.easeOut(duration: 0.15), value: targeted)
        .dropDestination(for: String.self) { ids, _ in
            for id in ids { store.move(id, to: group.id) }
            dropped()
            return true
        } isTargeted: { targeted = $0 }
        .accessibilityValue(open ? L("groups.open") : L("groups.closed"))
        .contextMenu { GroupMenuItems(store: store, group: group) }
        // A folder moves on the disk when it is dragged into another.
        .draggableFolder(store.followsDisk ? StackStore.folderDragPrefix + group.id : nil, title: group.name)
    }
}
