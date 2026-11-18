import AppKit
import SwiftUI

struct RootView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Bindable var store: StackStore
    @Bindable var updates = UpdateService.shared
    /// The page on screen, kept with the window (state restoration).
    @SceneStorage("window.route") private var savedRoute = ""
    var title: String {
        if case .site(let id) = store.route { return store.projects.first { $0.id == id }?.title ?? L("route.sites") }
        if case .composite(let id) = store.route { return store.composite(id)?.name ?? L("composite.title") }
        // Short, so it fits over the content column; the connection › database › table path is in the detail.
        if store.route == .tool("database-client") { return L("db.title") }
        return store.route.title
    }
    /// Each page says something of its own; the overall counts live in the status bar only.
    var subtitle: String {
        switch store.route {
        case .site(let id):
            guard let project = store.projects.first(where: { $0.id == id }) else { return "" }
            let branch = store.git[id].map { $0.branch.isEmpty ? L("git.detached") : $0.branch }
            return ([project.tech.title] + [project.php.map { "PHP \($0)" }, branch].compactMap { $0 }).joined(separator: " · ")
        case .composite(let id):
            guard let group = store.composite(id) else { return "" }
            return String(format: L("composite.subtitle"), group.sites.count)
        case .service(let category) where !Route.engines(in: category).isEmpty:
            // Only what Stack installs counts; a type without such services has no subtitle.
            let engines = Route.engines(in: category)
            return String(format: L("category.installedCount"), engines.filter { store.engineVersion($0) != nil }.count, engines.count)
        default: return ""
        }
    }
    /// The project on screen, for the Proyecto menu.
    var currentProject: Project? {
        if case .site(let id) = store.route { return store.projects.first { $0.id == id } }
        return nil
    }
    var body: some View {
        NavigationSplitView {
            Sidebar(store: store).navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 300)
        } content: {
            ContentColumn(store: store)
        } detail: {
            VStack(spacing: 0) {
                Group {
                    switch store.route {
                    case .home: HomePage(store: store)
                    case .site(let id):
                        if let project = store.projects.first(where: { $0.id == id }) { ProjectPage(store: store, project: project).id(id) }
                        else { HomePage(store: store) }
                    case .composite(let id):
                        if let group = store.composite(id) { CompositeProjectPage(store: store, group: group).id(id) }
                        else { HomePage(store: store) }
                    case .service(let category): CategoryPage(store: store, category: category).id(category)
                    case .language(let name): LanguagePage(store: store, name: name).id(name)
                    case .utilities(let group): UtilitiesPage(store: store, group: group).id(group)
                    case .tool(let id):
                        // A tool that is off has no page: its switch is in Ajustes › Herramientas.
                        if store.canShow(.tool(id)) { ToolPage(store: store, id: id).id(id) } else { HomePage(store: store) }
                    }
                }
                // A minimum height of 0: a page taller than the window is cut, never makes the split
                // view taller than it (AppKit would center it and put every column under the title bar, P-15).
                .frame(minHeight: 0, maxHeight: .infinity)
                .frame(maxWidth: .infinity)
                .transition(.opacity)
                if let pending = store.watchedPending.first, store.importScan == nil {
                    WatchBanner(store: store, scan: pending)
                }
                StatusBar(store: store)
            }
            // The system's own background, unless the theme paints one.
            .background { if Brand.customBackgrounds { Brand.background.ignoresSafeArea(.container, edges: .vertical) } }
            .scaledText()
            .contentColumn(shown: store.showsContentColumn)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        // On the Terminal, its own additions first: one «+» per window.
                        if store.route == .tool("ssh-terminal") {
                            TerminalNewItems()
                            Divider()
                        }
                        if store.route == .tool("skills"), store.canShow(.tool("skills")) {
                            Button { SkillsTool.shared.sheet = .newSkill } label: { Label(L("skills.newEllipsis"), systemImage: Symbols.skill) }
                                .help(L("skills.newHelp")).accessibilityIdentifier("toolbar.add.newSkill")
                            Divider()
                        }
                        Button { store.showNewProject = true } label: { Label(L("menu.newProject"), systemImage: Symbols.project) }
                            .accessibilityIdentifier("toolbar.add.newProject")
                        Button { store.chooseFolder() } label: { Label(L("menu.addExisting"), systemImage: Symbols.folder) }
                            .accessibilityIdentifier("toolbar.add.existing")
                        Button { store.chooseFolder(scan: true) } label: { Label(L("menu.importFolder"), systemImage: Symbols.importFolder) }
                            .accessibilityIdentifier("toolbar.add.importFolder")
                        Divider()
                        Button { store.groupNaming = .new(sites: []) } label: { Label(L("menu.newFolder"), systemImage: Symbols.newFolder) }
                            .accessibilityIdentifier("toolbar.add.newFolder")
                    } label: {
                        Label(L("sites.options"), systemImage: Symbols.add).labelStyle(.iconOnly)
                    }
                    .help(L("sites.addHelp")).accessibilityIdentifier("toolbar.addSite")
                }
            }
            .overlay(alignment: .bottom) {
                if let toast = store.toast {
                    Label(toast, systemImage: Symbols.success)
                        .font(.uiCallout.weight(.medium))
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .chromeGlass()
                        .padding(.bottom, 46)
                        .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                        .accessibilityIdentifier("toast")
                }
            }
            .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: store.route)
            // Dropping a project folder on the window adds it as a site.
            .dropDestination(for: URL.self) { urls, _ in
                guard let folder = urls.first(where: { $0.hasDirectoryPath || (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }) else { return false }
                Task { await store.openFolder(folder.path) }
                return true
            }
            // The title area shares the content's background, so one divider runs from the top of the
            // window to the bottom; scrolled content fades under it with the system's edge effect.
            .toolbarBackgroundVisibility(reduceTransparency ? .visible : .hidden, for: .windowToolbar)
            .softTopEdge()
            .windowToolbarFullScreenVisibility(.onHover)
        }
        .navigationTitle(title)
        .navigationSubtitle(subtitle)
        .sheet(item: Binding(get: { store.newSite.map { DetectionBox(detection: $0) } }, set: { if $0 == nil { store.newSite = nil } })) { box in
            ProjectSettingsSheet(store: store, project: box.detection.project, notes: box.detection.notes, isNew: true).themedSheet()
        }
        .sheet(isPresented: $store.showNewProject) { NewProjectSheet(store: store).themedSheet() }
        .sheet(item: $store.groupNaming, onDismiss: { store.newFolderParent = nil }) { naming in GroupNameSheet(store: store, naming: naming).themedSheet() }
        .sheet(item: $store.importScan, onDismiss: { Task { await store.refreshWatched() } }) { scan in ImportFolderSheet(store: store, scan: scan).themedSheet() }
        .sheet(isPresented: $store.showPalette) { CommandPalette(store: store).themedSheet() }
        .sheet(isPresented: $updates.showingSheet) { UpdateSheet(updates: updates).themedSheet() }
        .sheet(isPresented: $store.showSetup) { SetupAssistantSheet(store: store).themedSheet() }
        .sheet(item: $store.restoreRequest) { request in RestoreSheet(store: store, request: request).themedSheet() }
        .sheet(item: $store.renaming) { request in ProjectRenameSheet(store: store, request: request).themedSheet() }
        .confirmationDialog(L("site.deleteConfirm"), isPresented: Binding(get: { store.removing != nil }, set: { if !$0 { store.removing = nil } }), presenting: store.removing) { project in
            Button(L("site.delete"), role: .destructive) { Task { await store.delete(project) } }
            Button(L("common.cancel"), role: .cancel) {}
        } message: { _ in Text(L("site.deleteDetail")) }
        .confirmationDialog(L("groups.moveConfirm"), isPresented: Binding(get: { store.pendingDiskMove != nil }, set: { if !$0 { store.pendingDiskMove = nil } }),
                            presenting: store.pendingDiskMove) { request in
            Button(L("groups.moveAction")) { Task { await store.performDiskMove(request) } }.accessibilityIdentifier("groups.move.confirm")
            Button(L("common.cancel"), role: .cancel) {}
        } message: { request in
            Text(String(format: L("groups.moveDetail"), request.title, request.intoName, store.relativeToProjects(request.from), store.relativeToProjects(request.into)))
        }
        .sheet(item: Binding(get: { store.migrationDeferred ? nil : store.disk?.migration.flatMap { $0.proposals.isEmpty ? nil : $0 }.map(MigrationBox.init) },
                                  set: { if $0 == nil { store.migrationDeferred = true } })) { box in
            DiskMigrationSheet(store: store, plan: box.plan).themedSheet()
        }
        .confirmationDialog(L("env.portRestartTitle"), isPresented: Binding(get: { store.portRestartOffer != nil }, set: { if !$0 { store.portRestartOffer = nil } }),
                            presenting: store.portRestartOffer) { offer in
            Button(L("env.restartProcesses")) { Task { for project in offer.projects { await store.restartProcesses(project) } } }
                .accessibilityIdentifier("env.portRestart")
            Button(L("common.cancel"), role: .cancel) {}
        } message: { offer in
            Text(String(format: L("env.portRestartDetail"), offer.changed, offer.projects.map(\.title).joined(separator: ", ")))
        }
        // ⌘K opens the palette too (Ir › Abrir rápidamente… is ⇧⌘O).
        .background { Button(L("menu.quickOpen")) { store.showPalette = true }.keyboardShortcut("k").hidden() }
        .focusedSceneValue(\.selectedProject, currentProject)
        // Edición › Buscar (⌘F); the SSH terminal keeps ⌘F for its own search.
        .focusedSceneValue(\.sidebarSearch, store.route == .tool("ssh-terminal") ? nil : SidebarSearchFocus { store.findRequests += 1 })
        .serviceStopConfirmation(store)
        .alert(L("error.title"), isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button(L("common.close"), role: .cancel) { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
        // Colors are read while drawing: a change of theme repaints in place, keeping page and scroll.
        .themedTint()
        .opensSettings()
        .task { await store.refreshVisibleProjects() }
        // Back to the front: what changed meanwhile outside the app (a project removed on the command line).
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await store.refreshDisk() }
        }
        .task {
            await store.bootstrap()
            store.restore(savedRoute)
        }
        .onChange(of: store.route) {
            savedRoute = store.route.storageValue
            // A row of Componentes opens again on the last category seen.
            Component.remember(store.route)
        }
        .onOpenURL { url in
            Task {
                await store.bootstrap()
                store.handle(url)
            }
        }
    }
}

private extension View {
    /// Lists and tables would draw a hard band under the toolbar (a lighter strip and a line that
    /// does not meet the sidebar's divider); every page fades softly instead, like Home.
    @ViewBuilder func softTopEdge() -> some View {
        if #available(macOS 26, *) { scrollEdgeEffectStyle(.soft, for: .top) } else { self }
    }
}

/// Edición › Buscar: focuses the sidebar's search field.
struct SidebarSearchFocus {
    let focus: @MainActor () -> Void
}

private struct DetectionBox: Identifiable {
    let detection: Detection
    var id: String { detection.project.id }
}
