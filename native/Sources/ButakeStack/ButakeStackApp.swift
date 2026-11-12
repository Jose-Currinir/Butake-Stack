import AppKit
import SwiftUI

func L(_ key: String) -> String {
    Bundle.module.localizedString(forKey: key, value: key, table: "Localizable")
}

/// Work that needs NSApp: the theme's appearance is applied once the app has launched.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            ThemeStore.shared.applyAppearance()
            if StackStore.qaWindow {
                // QA and screenshots: a bare debug executable must still come to the front.
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)
            }
            #if DEBUG
            if StackStore.qaWindow, ProcessInfo.processInfo.environment["BUTAKE_QA_SETUP"] != nil {
                Task { try? await Task.sleep(for: .seconds(2)); StackStore.shared.showSetup = true }
            }
            if StackStore.qaWindow, let language = ProcessInfo.processInfo.environment["BUTAKE_QA_LANGUAGE"] {
                Task { try? await Task.sleep(for: .seconds(1)); StackStore.shared.route = .language(language) }
            }
            if StackStore.qaWindow, let folder = ProcessInfo.processInfo.environment["BUTAKE_QA_OPEN_FOLDER"] {
                Task { try? await Task.sleep(for: .seconds(2)); await StackStore.shared.openFolder(folder, scan: true) }
            }
            #endif
            // A new Mac: what is missing is asked for in "Preparar Butake Stack".
            Task { await StackStore.shared.checkSetupAtLaunch() }
        }
    }
}

@main struct ButakeStackApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var store = StackStore.shared
    @State private var themes = ThemeStore.shared
    @State private var text = TextScale.shared
    init() {
        ThemeStore.shared.customName = L("themeCustom")
        StackStore.shared.startPolling()
        UpdateService.shared.startAutomaticChecks()
    }
    var body: some Scene {
        // A menu bar app: no Dock icon (LSUIElement) and no window at launch; the panel is home.
        MenuBarExtra {
            MenuPanel(store: store).id(themes.theme.signature)
        } label: {
            Image(nsImage: MenuBarIcon.image)
        }
        .menuBarExtraStyle(.window)
        Window(L("app.name"), id: "main") {
            RootView(store: store)
                .frame(minWidth: 960, minHeight: 600)
                .background(FullScreenCapable())
                .tint(Brand.accent)
                .id(themes.theme.signature)
        }
        .defaultSize(width: 1180, height: 740)
        .defaultLaunchBehavior(StackStore.qaWindow ? .presented : .suppressed)
        // butakestack://site/<id> and butakestack://open?path=… (from Butake Git) open this window.
        .handlesExternalEvents(matching: ["butakestack"])
        .commands {
            CommandGroup(after: .appInfo) {
                Button(L("updateCheckMenu")) { Task { await UpdateService.shared.check(userInitiated: true) } }
            }
            CommandGroup(after: .newItem) {
                Button(L("palette.title")) { store.showPalette = true }.keyboardShortcut("k")
            }
            CommandGroup(after: .toolbar) {
                Button(L("text.bigger")) { text.increase() }.keyboardShortcut("+").disabled(!text.canIncrease)
                Button(L("text.smaller")) { text.decrease() }.keyboardShortcut("-").disabled(!text.canDecrease)
                Button(L("text.reset")) { text.reset() }.keyboardShortcut("0")
            }
        }
        Settings {
            SettingsView(store: store).frame(width: 560, height: 470).themedSheet().id(themes.theme.signature)
        }
    }
}

struct RootView: View {
    @Bindable var store: StackStore
    @Bindable var updates = UpdateService.shared
    var title: String {
        if case .site(let id) = store.route { return store.projects.first { $0.id == id }?.title ?? L("route.sites") }
        return store.route.title
    }
    /// Each page says something of its own; the overall counts live in the status bar only.
    var subtitle: String {
        switch store.route {
        case .site(let id):
            guard let project = store.projects.first(where: { $0.id == id }) else { return "" }
            let branch = store.git[id].map { $0.branch.isEmpty ? L("git.detached") : $0.branch }
            return ([project.tech.title] + [project.php.map { "PHP \($0)" }, branch].compactMap { $0 }).joined(separator: " · ")
        case .service(let category) where category != "web":
            let installed = Route.engines(in: category).filter { store.engineVersion($0) != nil }.count
            return String(format: L("category.installedCount"), installed, Route.engines(in: category).count)
        default: return ""
        }
    }
    var body: some View {
        NavigationSplitView {
            Sidebar(store: store).navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 300)
        } detail: {
            VStack(spacing: 0) {
                Group {
                    switch store.route {
                    case .home: HomePage(store: store)
                    case .site(let id):
                        if let project = store.projects.first(where: { $0.id == id }) { SiteView(store: store, project: project).id(id) }
                        else { HomePage(store: store) }
                    case .service("web"): WebPage(store: store)
                    case .service(let category): CategoryPage(store: store, category: category).id(category)
                    case .language(let name): LanguagePage(store: store, name: name).id(name)
                    case .general: GeneralPage(store: store)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity)
                StatusBar(store: store)
            }
            .background { if Brand.customBackgrounds { Brand.surface.ignoresSafeArea() } }
            .scaledText()
            .navigationTitle(title)
            .navigationSubtitle(subtitle)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { store.showNewProject = true } label: { Label(L("sites.addEllipsis"), systemImage: "plus") }
                        .help(L("sites.addHelp")).accessibilityIdentifier("toolbar.addSite")
                }
            }
            .overlay(alignment: .bottom) {
                if let toast = store.toast {
                    Label(toast, systemImage: "checkmark.circle.fill")
                        .font(.uiCallout.weight(.medium))
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .background(.regularMaterial, in: Capsule())
                        .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
                        .padding(.bottom, 46)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .accessibilityIdentifier("toast")
                }
            }
            .animation(.smooth(duration: 0.25), value: store.route)
            // Dropping a project folder on the window adds it as a site.
            .dropDestination(for: URL.self) { urls, _ in
                guard let folder = urls.first(where: { $0.hasDirectoryPath || (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }) else { return false }
                Task { await store.openFolder(folder.path) }
                return true
            }
            // Like Butake Git: no toolbar background, so toolbar groups render as glass capsules.
            .toolbarBackground(.hidden, for: .windowToolbar)
            .windowToolbarFullScreenVisibility(.onHover)
        }
        .sheet(item: Binding(get: { store.newSite.map { DetectionBox(detection: $0) } }, set: { if $0 == nil { store.newSite = nil } })) { box in
            SiteEditorSheet(store: store, project: box.detection.project, notes: box.detection.notes, isNew: true).themedSheet()
        }
        .sheet(isPresented: $store.showNewProject) { NewProjectSheet(store: store).themedSheet() }
        .sheet(item: $store.groupNaming) { naming in GroupNameSheet(store: store, naming: naming).themedSheet() }
        .sheet(item: $store.importScan) { scan in ImportFolderSheet(store: store, scan: scan).themedSheet() }
        .sheet(isPresented: $store.showPalette) { CommandPalette(store: store).themedSheet() }
        .sheet(isPresented: $updates.showingSheet) { UpdateSheet(updates: updates).themedSheet() }
        .sheet(isPresented: $store.showSetup) { SetupSheet(store: store).themedSheet() }
        .alert(L("error.title"), isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button(L("action.close"), role: .cancel) { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
        .task { await store.refresh(); await store.refreshRuntimes(); await store.refreshGit() }
        .onOpenURL { store.handle($0) }
    }
}

private struct DetectionBox: Identifiable {
    let detection: Detection
    var id: String { detection.project.id }
}

private struct Sidebar: View {
    @Bindable var store: StackStore
    @State var search = ""
    @AppStorage("sidebar.collapsedGroups") var collapsedRaw = ""
    @AppStorage("sidebar.closedSections") var closedSectionsRaw = ""
    // Live copies: changes to @State carry the animation (AppStorage writes don't); saved right after.
    @State var collapsed: Set<String> = Set((UserDefaults.standard.string(forKey: "sidebar.collapsedGroups") ?? "").split(separator: ",").map(String.init))
    @State var nudging: Set<String> = []
    @State var closedSections: Set<String> = Set((UserDefaults.standard.string(forKey: "sidebar.closedSections") ?? "").split(separator: ",").map(String.init))
    func matches(_ text: String) -> Bool { search.isEmpty || text.localizedCaseInsensitiveContains(search) }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 11) {
                BrandMark(size: 32)
                Text("Stack").font(.system(size: 21, weight: .bold, design: .rounded))
                Spacer(minLength: 0)
            }.padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 12)
            SidebarSearch(text: $search)
                .padding(.horizontal, 10).padding(.bottom, 8)
            List(selection: Binding(get: { store.route }, set: { if let route = $0 { store.route = route; if case .site(let id) = route { store.selectedSite = id } } })) {
                if search.isEmpty {
                    Label(L("route.home"), systemImage: "house").tag(Route.home).sidebarSelected(store.route == .home).accessibilityIdentifier("route.home")
                }
                let sites = store.projects.filter { matches($0.title) || matches($0.domain) }
                // Always there while not searching: its + is how sites are added.
                if !sites.isEmpty || search.isEmpty {
                    Section(isExpanded: sectionOpen("sites")) {
                        ForEach(store.groups) { group in
                            let members = store.projects(in: group).filter { matches($0.title) || matches($0.domain) || matches(group.name) }
                            if search.isEmpty || !members.isEmpty {
                                DisclosureGroup(isExpanded: expanded(group.id)) {
                                    ForEach(members) { siteRow($0, in: group.id) }
                                    if members.isEmpty && search.isEmpty {
                                        Text(L("groups.empty")).font(.uiCaption).foregroundStyle(.tertiary).selectionDisabled()
                                    }
                                } label: {
                                    // A real button over the whole row: in an optimized build a tap gesture on a list
                                    // row can lose the click to the list's own selection.
                                    Button { setExpanded(group.id, collapsed.contains(group.id)) } label: {
                                        GroupRow(store: store, group: group, members: store.projects(in: group), open: expanded(group.id).wrappedValue)
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityHint(expanded(group.id).wrappedValue ? L("groups.collapse") : L("groups.expand"))
                                    .dropDestination(for: String.self) { ids, _ in
                                            for id in ids where store.projects.contains(where: { $0.id == id }) { store.move(id, to: group.id) }
                                            setExpanded(group.id, true)
                                            return true
                                        }
                                }
                                .accessibilityIdentifier("sidebar.group.\(group.id)")
                            }
                        }
                        ForEach(store.ungroupedProjects.filter { matches($0.title) || matches($0.domain) }) { siteRow($0, in: nil) }
                    } header: {
                        SitesHeader(store: store, open: sectionOpen("sites"))
                    }
                }
                let services = Route.services.filter { matches(Tech.of($0).title) || Route.engines(in: $0).contains { matches(Tech.of($0).title) } }
                if !services.isEmpty {
                    Section(isExpanded: sectionOpen("services")) {
                        ForEach(services, id: \.self) { name in
                            // Only what is installed shows a state; the rest has nothing to report.
                            SidebarTech(tech: .of(name), phase: store.categoryInstalled(name) ? store.categoryPhase(name) : nil).tag(Route.service(name)).sidebarSelected(store.route == .service(name))
                                .accessibilityIdentifier("route.service.\(name)")
                        }
                    } header: { SectionToggle(title: L("sidebar.services"), open: sectionOpen("services")) }
                }
                let languages = Route.languages.filter { matches(Tech.of($0).title) }
                if !languages.isEmpty {
                    Section(isExpanded: sectionOpen("languages")) {
                        ForEach(languages, id: \.self) { name in
                            SidebarTech(tech: .of(name), phase: nil).tag(Route.language(name)).sidebarSelected(store.route == .language(name)).accessibilityIdentifier("route.language.\(name)")
                        }
                    } header: { SectionToggle(title: L("sidebar.languages"), open: sectionOpen("languages")) }
                }
                if search.isEmpty || matches(L("route.general")) {
                    Section(isExpanded: sectionOpen("system")) {
                        Label(L("route.general"), systemImage: "gearshape.2").tag(Route.general).sidebarSelected(store.route == .general).accessibilityIdentifier("route.general")
                    } header: { SectionToggle(title: L("sidebar.system"), open: sectionOpen("system")) }
                }
            }
            .listStyle(.sidebar).themedScroll()
            // A folder created while the list updates (an import) can be inserted closed by the outline view
            // even though it's open here: state it once more so the two agree.
            .onChange(of: store.groups.map(\.id)) { old, new in
                guard !old.isEmpty || !new.isEmpty else { return }
                let added = Set(new).subtracting(old).subtracting(collapsed)
                guard !added.isEmpty, !old.isEmpty || store.importScan != nil else { return }
                // Not the user's choice: nothing of this is saved (see setExpanded).
                nudging.formUnion(added)
                collapsed.formUnion(added)
                DispatchQueue.main.async {
                    withAnimation(.snappy(duration: 0.28)) { collapsed.subtract(added) }
                    DispatchQueue.main.async { nudging.subtract(added) }
                }
            }
            .background(PlainSidebarSelection())
            HStack(spacing: 12) {
                VersionBadge(updates: UpdateService.shared).lineLimit(1).fixedSize()
                Spacer()
                Button { store.groupNaming = .new(sites: []) } label: { Image(systemName: "folder.badge.plus").font(.ui(size: 13)) }
                    .buttonStyle(.borderless).help(L("groups.new")).accessibilityIdentifier("sidebar.newGroup")
                SettingsLink { Image(systemName: "gearshape").font(.ui(size: 13)) }.buttonStyle(.borderless).help(L("settings.title")).accessibilityIdentifier("sidebar.settings")
            }.padding(.horizontal, 16).padding(.vertical, 10)
        }
        .background { if Brand.customBackgrounds { (Brand.theme.sidebar?.color ?? Brand.background).ignoresSafeArea() } }
    }
}

extension Sidebar {
    /// A site in the sidebar. Dropping another site on it puts that one right before it, in the same folder
    /// (or out of any folder).
    func siteRow(_ project: Project, in group: String?) -> some View {
        Label {
            HStack { Text(project.title).lineLimit(1); Spacer(); StatusRing(phase: store.sitePhase(project), size: 10) }
        } icon: { TechLogo(tech: project.tech, size: 18) }
            .tag(Route.site(project.id)).sidebarSelected(store.route == .site(project.id)).accessibilityIdentifier("route.site.\(project.id)")
            .contextMenu { SiteMenuItems(store: store, project: project) }
            .draggable(project.id) {
                Label(project.title, systemImage: "globe").padding(6).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
            }
            .dropDestination(for: String.self) { ids, _ in
                for id in ids where id != project.id && store.projects.contains(where: { $0.id == id }) {
                    store.move(id, to: group, before: group == nil ? nil : project.id)
                }
                return true
            }
    }
    /// Folders open unless the user closed them; all open while searching.
    func expanded(_ id: String) -> Binding<Bool> {
        Binding(get: { !search.isEmpty || !collapsed.contains(id) }, set: { setExpanded(id, $0) })
    }
    func setExpanded(_ id: String, _ open: Bool) {
        guard !nudging.contains(id) else { return }
        withAnimation(.snappy(duration: 0.28)) {
            if open { collapsed.remove(id) } else { collapsed.insert(id) }
        }
        collapsedRaw = collapsed.sorted().joined(separator: ",")
    }
    /// Sidebar sections open unless the user closed them; all open while searching.
    func sectionOpen(_ id: String) -> Binding<Bool> {
        Binding(get: { !search.isEmpty || !closedSections.contains(id) }, set: { open in
            withAnimation(.snappy(duration: 0.28)) {
                if open { closedSections.remove(id) } else { closedSections.insert(id) }
            }
            closedSectionsRaw = closedSections.sorted().joined(separator: ",")
        })
    }
}

/// Search field aligned with the sidebar rows (the system one sits on its own inset). ⌘F focuses it,
/// Esc clears it.
private struct SidebarSearch: View {
    @Binding var text: String
    @FocusState private var focused: Bool
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.ui(size: 12, weight: .medium)).foregroundStyle(.secondary)
            TextField(L("sidebar.search"), text: $text)
                .textFieldStyle(.plain).font(.ui(size: 13))
                .focused($focused)
                .onExitCommand { text = ""; focused = false }
                .accessibilityIdentifier("sidebar.search")
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain).transition(.opacity.combined(with: .scale))
            }
        }
        .padding(.horizontal, 9).frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(focused ? Brand.accent.opacity(0.6) : .clear, lineWidth: 1.5))
        .animation(.easeOut(duration: 0.15), value: text.isEmpty)
        .animation(.easeOut(duration: 0.15), value: focused)
        .background { Button("") { focused = true }.keyboardShortcut("f").hidden() }
        // macOS hands the first text field of a new window the focus; the sidebar shouldn't start typing.
        .task { try? await Task.sleep(for: .milliseconds(250)); focused = false; NSApp.keyWindow?.makeFirstResponder(nil) }
    }
}

/// A sidebar section title that opens or closes the section when clicked anywhere, not only on its
/// chevron (the chevron still works).
private struct SectionToggle: View {
    let title: String
    @Binding var open: Bool
    var body: some View {
        Button { open.toggle() } label: {
            Text(title).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// "Sitios" with a button for a new folder; dropping a site here takes it out of its folder.
private struct SitesHeader: View {
    let store: StackStore
    @Binding var open: Bool
    @State private var targeted = false
    var body: some View {
        // The trailing edge belongs to the sidebar's own show/hide control.
        HStack(spacing: 6) {
            Button { open.toggle() } label: {
                Text(L("route.sites"))
                    .padding(.vertical, 2).padding(.horizontal, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Menu {
                Button { store.showNewProject = true } label: { Label(L("new.menu"), systemImage: "sparkles") }
                Button { store.chooseFolder() } label: { Label(L("sites.openProject"), systemImage: "folder") }
                Button { store.chooseFolder(scan: true) } label: { Label(L("sites.openFolder"), systemImage: "folder.badge.gearshape") }
                Divider()
                Button { store.groupNaming = .new(sites: []) } label: { Label(L("groups.new"), systemImage: "folder.badge.plus") }
            } label: {
                Image(systemName: "plus").font(.ui(size: 11, weight: .bold))
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help(L("sites.options")).accessibilityIdentifier("sidebar.sitesMenu")
        }
        // The trailing edge stays free for the sidebar's own show/hide chevron.
        .padding(.trailing, 20)
        .background(RoundedRectangle(cornerRadius: 6).fill(targeted ? Brand.accent.opacity(0.15) : .clear))
            .contextMenu { Button { store.groupNaming = .new(sites: []) } label: { Label(L("groups.new"), systemImage: "folder.badge.plus") } }
        .dropDestination(for: String.self) { ids, _ in
            for id in ids { store.move(id, to: nil) }
            return true
        } isTargeted: { targeted = $0 }
        .animation(.easeOut(duration: 0.15), value: targeted)
    }
}

/// A folder in the sidebar: name, how many of its sites are on, and its actions.
private struct GroupRow: View {
    let store: StackStore
    let group: SiteGroup
    let members: [Project]
    let open: Bool
    @State private var targeted = false
    var running: Int { members.filter { store.sitePhase($0) == .running }.count }
    var body: some View {
        Label {
            HStack(spacing: 6) {
                Text(group.name).lineLimit(1)
                Spacer()
                if running > 0 {
                    Text("\(running)").font(.ui(size: 10, weight: .bold)).foregroundStyle(Brand.success)
                        .padding(.horizontal, 5).padding(.vertical, 1).background(Brand.success.opacity(0.14), in: Capsule())
                        .help(String(format: L("groups.running"), running))
                }
                Text("\(members.count)").font(.ui(size: 11, weight: .medium)).foregroundStyle(.secondary).monospacedDigit()
            }
        } icon: {
            Image(systemName: open ? "folder.fill" : "folder").foregroundStyle(Brand.accent)
                .contentTransition(.symbolEffect(.replace))
        }
        .padding(.vertical, 1)
        .background(RoundedRectangle(cornerRadius: 6).fill(targeted ? Brand.accent.opacity(0.18) : .clear).padding(.horizontal, -6))
        .scaleEffect(targeted ? 1.02 : 1)
        .animation(.spring(duration: 0.25), value: targeted)
        .dropDestination(for: String.self) { ids, _ in
            for id in ids { store.move(id, to: group.id) }
            return true
        } isTargeted: { targeted = $0 }
        .contextMenu {
            Button { Task { for project in members where !project.enabled { await store.setSite(project, enabled: true) } } } label: {
                Label(L("groups.startAll"), systemImage: "power")
            }.disabled(members.allSatisfy(\.enabled))
            Button { Task { for project in members where project.enabled { await store.setSite(project, enabled: false) } } } label: {
                Label(L("groups.stopAll"), systemImage: "poweroff")
            }.disabled(!members.contains(where: \.enabled))
            Divider()
            Button { store.groupNaming = .rename(group.id) } label: { Label(L("groups.rename"), systemImage: "pencil") }
            Button(role: .destructive) { store.deleteGroup(group.id) } label: { Label(L("groups.delete"), systemImage: "folder.badge.minus") }
        }
    }
}

/// Name prompt for a new or renamed folder.
struct GroupNameSheet: View {
    let store: StackStore
    let naming: GroupNaming
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @FocusState private var focused: Bool
    var isNew: Bool { if case .new = naming { true } else { false } }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                IconTile(symbol: isNew ? "folder.badge.plus" : "folder", size: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text(isNew ? L("groups.new") : L("groups.rename")).font(.ui(size: 15, weight: .semibold))
                    Text(L("groups.hint")).font(.uiCaption).foregroundStyle(.secondary)
                }
            }
            TextField(L("groups.namePlaceholder"), text: $name)
                .textFieldStyle(.roundedBorder).focused($focused)
                .onSubmit(save)
                .accessibilityIdentifier("groups.name")
            HStack {
                Spacer()
                Button(L("action.cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isNew ? L("groups.create") : L("groups.save"), action: save)
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear {
            if case .rename(let id) = naming { name = store.groups.first { $0.id == id }?.name ?? "" }
            focused = true
        }
    }
    func save() {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        switch naming {
        case .new(let sites): store.createGroup(named: clean, with: sites)
        case .rename(let id): store.renameGroup(id, to: clean)
        }
        dismiss()
    }
}

private struct SidebarTech: View {
    let tech: Tech
    let phase: ProcessPhase?
    var body: some View {
        Label {
            HStack {
                Text(tech.title)
                Spacer()
                if let phase { StatusRing(phase: phase, size: 10) }
            }
        } icon: { TechLogo(tech: tech, size: 18) }
    }
}

private struct StatusBar: View {
    let store: StackStore
    var body: some View {
        HStack(spacing: 14) {
            Label(store.daemonRunning ? L("daemon.running") : L("daemon.stopped"), systemImage: store.daemonRunning ? "bolt.horizontal.circle.fill" : "bolt.horizontal.circle")
                .foregroundStyle(store.daemonRunning ? Brand.success : Brand.danger)
            if store.daemonRunning {
                Divider().frame(height: 10)
                Label(String(format: L("status.engines"), store.runningEngines, store.engineCount), systemImage: "cylinder.split.1x2")
                Divider().frame(height: 10)
                Label(String(format: L("status.processes"), store.runningSiteProcesses), systemImage: "gearshape.2")
            }
            if let busy = store.busy {
                Divider().frame(height: 10)
                ProgressView().controlSize(.mini)
                Text(busy).lineLimit(1)
            }
            Spacer()
            if store.agent?.loaded == true {
                Label(L("status.agent"), systemImage: "person.badge.clock").foregroundStyle(.secondary)
            } else if store.daemonRunning {
                Label(L("status.manual"), systemImage: "hand.raised").foregroundStyle(Brand.warning)
            } else {
                Button(L("daemon.start")) { Task { await store.startDaemon() } }.buttonStyle(.link).accessibilityIdentifier("status.startDaemon")
            }
        }
        .font(.ui(size: 10.5)).foregroundStyle(.secondary)
        .padding(.horizontal, 16).frame(height: 29)
        .background(Brand.bar)
        .overlay(alignment: .top) { Divider() }
        .animation(.snappy, value: store.busy)
    }
}

/// Settings, in tabs like every Mac app: General (text size, start at login) and Apariencia (theme).
struct SettingsView: View {
    @Bindable var store: StackStore
    var body: some View {
        TabView {
            Tab(L("settings.tab.general"), systemImage: "gearshape") { GeneralSettings(store: store) }
            Tab(L("settings.tab.appearance"), systemImage: "paintpalette") { AppearanceSettings() }
        }
        .scenePadding(.top)
    }
}

private struct GeneralSettings: View {
    @Bindable var store: StackStore
    @Bindable var text = TextScale.shared
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Form {
            Section(L("settings.text")) {
                LabeledContent(L("settings.textSize")) {
                    HStack {
                        Button { text.decrease() } label: { Image(systemName: "textformat.size.smaller") }.disabled(!text.canDecrease)
                        Text("\(Int(text.factor * 100)) %").monospacedDigit().frame(width: 48)
                        Button { text.increase() } label: { Image(systemName: "textformat.size.larger") }.disabled(!text.canIncrease)
                    }
                }
            }
            Section(L("settings.login")) {
                LabeledContent(L("activation.title")) {
                    Label(store.agent?.loaded == true ? L("settings.loginOn") : L("settings.loginOff"), systemImage: store.agent?.loaded == true ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(store.agent?.loaded == true ? Brand.success : .secondary)
                }
                HStack {
                    Text(L("settings.loginHelp")).font(.uiCaption).foregroundStyle(.secondary)
                    Spacer()
                    Button(L("settings.openGeneral")) {
                        store.route = .general
                        openWindow(id: "main"); NSApp.activate()
                    }.accessibilityIdentifier("settings.openGeneral")
                }
            }
            UpdateSettingsSection()
            if ButakeGit.installed {
                Section("Butake Git") {
                    Label(L("settings.gitLinked"), systemImage: "arrow.triangle.branch").foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped).themedScroll()
    }
}

private struct AppearanceSettings: View {
    @Bindable var themes = ThemeStore.shared
    var body: some View {
        Form {
            Section(L("settings.theme")) {
                Picker(L("settings.family"), selection: $themes.family) {
                    Text("Butake").tag(ThemeStore.Family.butake)
                    Text("Drácula").tag(ThemeStore.Family.dracula)
                    Text(L("themeCustom")).tag(ThemeStore.Family.custom)
                }.accessibilityIdentifier("settings.themeFamily")
                Picker(L("settings.mode"), selection: $themes.mode) {
                    Label(L("settings.system"), systemImage: "circle.lefthalf.filled").tag(ThemeStore.Mode.system)
                    Label(L("settings.light"), systemImage: "sun.max").tag(ThemeStore.Mode.light)
                    Label(L("settings.dark"), systemImage: "moon").tag(ThemeStore.Mode.dark)
                }.pickerStyle(.segmented).accessibilityIdentifier("settings.themeMode")
                ThemePreview(theme: themes.theme)
                if themes.family == .custom {
                    Picker(L("settings.base"), selection: $themes.customBase) {
                        Text("Butake").tag(ThemeStore.Family.butake); Text("Drácula").tag(ThemeStore.Family.dracula)
                    }
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 10) {
                        ForEach(ThemeStore.Slot.allCases) { slot in
                            ColorPicker(L("themeSlot.\(slot.rawValue)"), selection: Binding(get: { themes.color(for: slot).color }, set: { themes.set(slot, HexColor($0)) }), supportsOpacity: false)
                        }
                    }
                    Button(L("settings.resetCustom")) { themes.resetCustom() }
                } else {
                    Button(L("settings.customize")) { themes.customBase = themes.family; themes.family = .custom }
                }
            }
        }
        .formStyle(.grouped).themedScroll()
    }
}

/// What the theme touches in Stack: accent, state colors and surfaces.
private struct ThemePreview: View {
    let theme: Theme
    var body: some View {
        HStack(spacing: 8) {
            Text(theme.name).font(.ui(size: 12, weight: .semibold))
            Spacer()
            chip(L("state.running"), theme.addition)
            chip(L("state.starting"), theme.warning)
            chip(L("state.crashed"), theme.deletion)
            Text(L("activation.enable")).font(.ui(size: 11, weight: .semibold)).foregroundStyle(.white)
                .padding(.horizontal, 10).padding(.vertical, 4).background(theme.accent.color, in: Capsule())
        }
        .padding(12)
        .background(theme.background?.color ?? Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .environment(\.colorScheme, theme.isDark ? .dark : .light)
    }
    private func chip(_ text: String, _ color: HexColor) -> some View {
        Text(text).font(.ui(size: 9.5, weight: .semibold)).foregroundStyle(color.color)
            .padding(.horizontal, 6).padding(.vertical, 2).background(color.color.opacity(0.14), in: Capsule())
    }
}

/// A menu bar app's window isn't full-screen capable by default, so the green button only zooms.
/// This marks the main window as a primary full-screen window.
private struct FullScreenCapable: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ view: NSView, context: Context) { view.window.map(Probe.mark) }
    final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            apply(window)
            // SwiftUI sets the window's behavior after it appears; apply again once it has.
            DispatchQueue.main.async { [weak self] in self?.window.map(Self.mark) }
        }
        private func apply(_ window: NSWindow) { Self.mark(window) }
        static func mark(_ window: NSWindow) {
            window.collectionBehavior.remove(.fullScreenAuxiliary)
            window.collectionBehavior.remove(.fullScreenNone)
            window.collectionBehavior.insert(.fullScreenPrimary)
        }
    }
}

/// The sidebar selection in the theme's accent instead of the system's (blue by default): the system
/// highlight is turned off on the sidebar's outline view, keeping its keyboard navigation, and each
/// row draws its own tinted pill.
private struct PlainSidebarSelection: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ view: NSView, context: Context) { DispatchQueue.main.async { (view as? Probe)?.apply() } }
    final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in self?.apply() }
        }
        func apply() {
            guard let root = window?.contentView else { return }
            for outline in Self.outlines(in: root) where outline.selectionHighlightStyle != .none {
                outline.selectionHighlightStyle = .none
            }
        }
        static func outlines(in view: NSView) -> [NSOutlineView] {
            (view as? NSOutlineView).map { [$0] } ?? view.subviews.flatMap(outlines)
        }
    }
}

private struct SidebarSelected: ViewModifier {
    let selected: Bool
    func body(content: Content) -> some View {
        content
            .foregroundStyle(selected ? Brand.accent : .primary)
            .fontWeight(selected ? .semibold : .regular)
            .listRowBackground(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(selected ? Brand.accent.opacity(0.16) : .clear)
                    .padding(.horizontal, 10)
                    .animation(.easeOut(duration: 0.15), value: selected)
            )
    }
}

extension View {
    func sidebarSelected(_ selected: Bool) -> some View { modifier(SidebarSelected(selected: selected)) }
}
