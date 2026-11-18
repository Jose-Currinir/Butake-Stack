import AppKit
import SwiftUI

/// Inicio: what needs doing (only when something does), the projects and the services installed.
/// Stack's state itself is said by the status bar.
struct HomePage: View {
    @Bindable var store: StackStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var services: [String] { Route.allEngines.filter { store.engineVersion($0) != nil } }
    var online: Int { store.projects.filter { store.sitePhase($0) == .running }.count }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                let state = store.stackState
                if state.needsAction { HomeHeader(store: store, state: state) }
                if !store.attentionOn.isEmpty { HomeAttention(store: store) }
                if store.projects.isEmpty { noProjects(prominent: !state.needsAction) } else { projects }
                if !services.isEmpty { servicesSection }
            }
            .padding(28)
            .frame(maxWidth: 1680, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Brand.background)
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

    /// Cards share the row: as many columns as fit, each stretching to fill; wide enough for a name
    /// and its kind beside the switch.
    private func grid<Item: Identifiable, Card: View>(_ items: [Item], @ViewBuilder card: @escaping (Item) -> Card) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: TextScale.points(290)), spacing: 12)], spacing: 12) {
            ForEach(items) { card($0) }
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.3), value: items.map(\.id))
    }

    private var projects: some View {
        VStack(alignment: .leading, spacing: 18) {
            SectionHeading(title: L("route.sites"), detail: String(format: L("sites.online"), online))
            // Each folder as its own group of cards, closed or open as in the sidebar (one state for
            // both); projects without a folder after them.
            ForEach(store.groups) { group in
                let members = store.projects(in: group)
                if !members.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        // A project of several parts says so and leads to its page.
                        HStack(spacing: 4) {
                            HomeFolderHeader(store: store, id: group.id, title: group.name,
                                             symbol: group.isProject ? Symbols.compositeProject : Symbols.folder, members: members)
                            if group.isProject {
                                Button { store.openComposite(group.id) } label: {
                                    Label(L("composite.open"), systemImage: Symbols.compositeProject).labelStyle(.iconOnly)
                                }
                                .buttonStyle(.borderless)
                                .help(L("composite.open"))
                                .accessibilityIdentifier("home.folder.\(group.id).open")
                            }
                        }
                        if store.folderOpen(group.id) { grid(members) { HomeProjectCard(store: store, project: $0).draggable($0.id) } }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            let loose = store.ungroupedProjects
            if !loose.isEmpty {
                // Named, and so closable, only next to folders that show cards.
                let named = store.groups.contains(where: { !store.projects(in: $0).isEmpty })
                VStack(alignment: .leading, spacing: 10) {
                    if named {
                        HomeFolderHeader(store: store, id: StackStore.looseFolder, title: L("groups.loose"), symbol: Symbols.project, members: loose)
                    }
                    if !named || store.folderOpen(StackStore.looseFolder) {
                        grid(loose) { HomeProjectCard(store: store, project: $0).draggable($0.id) }
                    }
                }
            }
        }
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

    private var servicesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeading(title: L("sidebar.services"), detail: String(format: L("status.engines"), store.runningEngines, store.engineCount))
            grid(services.map(ServiceID.init)) { HomeServiceCard(store: store, name: $0.id) }
        }
    }
}

private struct ServiceID: Identifiable { let id: String }

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

/// The title of a folder in Inicio: a button that closes and opens its cards, with the sidebar's
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
        // No animation of its own: the cards appear and leave at once (Reduce Motion or not).
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
        .workSurface(radius: 18)
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

/// A compact card: logo, name and detail open its page; the state and the switch sit on top so
/// they never trigger the card.
private struct HomeCard<Trailing: View>: View {
    let tech: Tech
    let title: String
    let detail: String
    /// The detail with the kind's short name, used before the detail is cut.
    var shortDetail: String?
    let identifier: String
    let open: () -> Void
    @ViewBuilder let trailing: Trailing
    /// What the state and the switch take, measured: the text gets the rest of the card.
    @State private var trailingWidth: CGFloat = 0
    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                TechLogo(tech: tech, size: 32).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.uiHeadline).lineLimit(1)
                    ViewThatFits(in: .horizontal) {
                        Text(detail).lineLimit(1)
                        if let shortDetail { Text(shortDetail).lineLimit(1) }
                        Text(shortDetail ?? detail).lineLimit(1).truncationMode(.tail)
                    }
                    .font(.uiCaption).foregroundStyle(.secondary)
                }
                .layoutPriority(1)
                Spacer(minLength: trailingWidth + 12)
            }
            .padding(12)
            .workSurface()
        }
        .buttonStyle(HighlightButtonStyle(radius: 16))
        .overlay(alignment: .trailing) {
            HStack(spacing: 10) { trailing }
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { trailingWidth = $0 }
                .padding(.trailing, 12)
        }
        .help(title)
        .accessibilityIdentifier(identifier)
    }
}

private struct HomeProjectCard: View {
    @Bindable var store: StackStore
    let project: Project
    var detail: String { detail(kind: project.tech.title) }
    func detail(kind: String) -> String {
        if project.isMissing { return L("missing.title") }
        let branch = store.git[project.id].map { $0.branch.isEmpty ? L("git.detached") : $0.branch }
        let unserved = project.isServed || project.technology == nil ? nil : L("kind.unserved")
        return ([kind] + [unserved, project.php.map { "PHP \($0)" }, branch].compactMap { $0 }).joined(separator: " · ")
    }
    var body: some View {
        let phase = store.sitePhase(project)
        HomeCard(tech: project.tech, title: project.title, detail: detail,
                 shortDetail: project.tech.shortTitle == project.tech.title ? nil : detail(kind: project.tech.shortTitle), identifier: "home.site.\(project.id)",
                 open: { withAnimation(.smooth(duration: 0.3)) { store.openSite(project.id) } }) {
            // Something it needs (P-42): the first cause on hover, the rest on its page.
            if !project.isMissing, let first = store.attention[project.id]?.first {
                Image(systemName: Symbols.warning).foregroundStyle(Brand.warning).help(store.attentionText(first))
                    .accessibilityLabel(L("attention.title"))
                    .accessibilityIdentifier("home.site.attention.\(project.id)")
            }
            if project.isMissing {
                // Without its folder it cannot start: its page finds the folder or removes the project.
                Image(systemName: Symbols.missingFolder).foregroundStyle(Brand.warning).help(L("missing.title"))
                    .accessibilityIdentifier("home.site.missing.\(project.id)")
            } else if project.isServed {
                // A project that is off says so with its switch alone.
                if project.enabled { StatusRing(phase: phase) }
                Toggle(String(format: L("site.powerFor"), project.title), isOn: Binding(get: { project.enabled }, set: { on in Task { await store.setSite(project, enabled: on) } }))
                    .toggleStyle(.switch).controlSize(.small).labelsHidden()
                    .accessibilityIdentifier("home.site.toggle.\(project.id)")
            }
        }
        .contextMenu { ProjectMenuItems(store: store, project: project) }
        .accessibilityLabel(project.title)
        .accessibilityValue(project.isMissing ? L("missing.title") : project.enabled ? L("state.\(phase.rawValue)") : L("site.off"))
    }
}

private struct HomeServiceCard: View {
    @Bindable var store: StackStore
    let name: String
    func open() { store.route = .service(Route.category(of: name)) }

    var body: some View {
        let tech = Tech.of(name)
        let enabled = store.engineEnabled(name)
        HomeCard(tech: tech, title: tech.title, detail: [store.engineVersion(name), store.enginePort(name).map(String.init)].compactMap { $0 }.joined(separator: " · "),
                 identifier: "home.service.\(name)", open: open) {
            if enabled { StatusRing(phase: store.phase("stack.\(name)")) }
            Toggle(tech.title, isOn: Binding(get: { enabled }, set: { on in Task { await store.setEngine(name, enabled: on) } }))
                .toggleStyle(.switch).controlSize(.small).labelsHidden()
                .accessibilityIdentifier("home.service.toggle.\(name)")
        }
        .contextMenu {
            Button { Task { await store.setEngine(name, enabled: !enabled) } } label: {
                Label(enabled ? L("palette.stop") : L("palette.start"), systemImage: enabled ? Symbols.stop : Symbols.start)
            }
            .accessibilityIdentifier("home.service.menu.toggle.\(name)")
            Button { open() } label: {
                Label(L("palette.openPage"), systemImage: Symbols.forward)
            }
            .accessibilityIdentifier("home.service.menu.open.\(name)")
        }
    }
}
