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
                    Menu {
                        Button { store.showNewProject = true } label: { Label(L("new.menu"), systemImage: "sparkles") }
                        Button { store.chooseFolder() } label: { Label(L("sites.addExisting"), systemImage: "folder.badge.plus") }
                    } label: { Label(L("sites.addEllipsis"), systemImage: "plus") } primaryAction: { store.showNewProject = true }
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
                Task { await store.detect(folder.path) }
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
    @State private var search = ""
    func matches(_ text: String) -> Bool { search.isEmpty || text.localizedCaseInsensitiveContains(search) }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 11) {
                BrandMark(size: 32)
                Text("Stack").font(.system(size: 21, weight: .bold, design: .rounded))
                Spacer(minLength: 0)
            }.padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 10)
            List(selection: Binding(get: { store.route }, set: { if let route = $0 { store.route = route; if case .site(let id) = route { store.selectedSite = id } } })) {
                if search.isEmpty {
                    Label(L("route.home"), systemImage: "house").tag(Route.home).accessibilityIdentifier("route.home")
                }
                let sites = store.projects.filter { matches($0.title) || matches($0.domain) }
                if !sites.isEmpty {
                    Section(L("route.sites")) {
                        ForEach(sites) { project in
                            Label {
                                HStack { Text(project.title).lineLimit(1); Spacer(); StatusRing(phase: store.sitePhase(project), size: 10) }
                            } icon: { TechLogo(tech: project.tech, size: 18) }
                                .tag(Route.site(project.id)).accessibilityIdentifier("route.site.\(project.id)")
                                .contextMenu { SiteMenuItems(store: store, project: project) }
                        }
                    }
                }
                let services = Route.services.filter { matches(Tech.of($0).title) || Route.engines(in: $0).contains { matches(Tech.of($0).title) } }
                if !services.isEmpty {
                    Section(L("sidebar.services")) {
                        ForEach(services, id: \.self) { name in
                            // Only what is installed shows a state; the rest has nothing to report.
                            SidebarTech(tech: .of(name), phase: store.categoryInstalled(name) ? store.categoryPhase(name) : nil).tag(Route.service(name))
                                .accessibilityIdentifier("route.service.\(name)")
                        }
                    }
                }
                let languages = Route.languages.filter { matches(Tech.of($0).title) }
                if !languages.isEmpty {
                    Section(L("sidebar.languages")) {
                        ForEach(languages, id: \.self) { name in
                            SidebarTech(tech: .of(name), phase: nil).tag(Route.language(name)).accessibilityIdentifier("route.language.\(name)")
                        }
                    }
                }
                if search.isEmpty || matches(L("route.general")) {
                    Section(L("sidebar.system")) {
                        Label(L("route.general"), systemImage: "gearshape.2").tag(Route.general).accessibilityIdentifier("route.general")
                    }
                }
            }
            .listStyle(.sidebar).themedScroll()
            .searchable(text: $search, placement: .sidebar, prompt: L("sidebar.search"))
            HStack {
                VersionBadge(updates: UpdateService.shared)
                Spacer()
                SettingsLink { Image(systemName: "gearshape").font(.ui(size: 13)) }.buttonStyle(.borderless).help(L("settings.title")).accessibilityIdentifier("sidebar.settings")
            }.padding(.horizontal, 16).padding(.vertical, 10)
        }
        .background { if Brand.customBackgrounds { (Brand.theme.sidebar?.color ?? Brand.background).ignoresSafeArea() } }
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
