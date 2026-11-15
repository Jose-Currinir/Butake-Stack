import AppKit
import SwiftUI

@main struct ButakeStackApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var store = StackStore.shared
    @State private var text = TextScale.shared
    init() {
        ThemeStore.shared.customName = L("themeCustom")
        StackStore.shared.startPolling()
        UpdateService.shared.startAutomaticChecks()
        // Kept-alive SSH forwards are restarted even while the SSH page is closed.
        SSHTerminal.shared.startKeepAlive()
    }
    var body: some Scene {
        // A menu bar app: no Dock icon (LSUIElement) and no window at launch; the panel is home.
        MenuBarExtra {
            MenuPanel(store: store).opensSettings()
        } label: {
            Image(nsImage: MenuBarIcon.image)
        }
        .menuBarExtraStyle(.window)
        Window(L("app.name"), id: "main") {
            RootView(store: store)
                .frame(minWidth: 960, minHeight: 600)
                .background(FullScreenCapable())
        }
        .defaultSize(width: 1180, height: 740)
        .defaultLaunchBehavior(StackStore.qaWindow ? .presented : .suppressed)
        // butakestack://site/<id> and butakestack://open?path=… (from Butake Git) open this window.
        .handlesExternalEvents(matching: ["butakestack"])
        .commands {
            AppCommands(store: store, text: text, hasProjects: !store.projects.isEmpty,
                        toolsRoute: .tool(SidebarLayout.toolRows(enabled: store.enabledPlugins.map(\.id))[0]),
                        cloudRoute: SidebarLayout.cloudRows(enabled: store.enabledPlugins.map(\.id)).first.map(Route.tool),
                        gitEnabled: store.pluginEnabled("git"))
        }
        Settings {
            SettingsWindow(store: store)
        }
        // Each tab brings its own minimum and ideal size; the window follows it.
        .windowResizability(.contentSize)
    }
}

/// Settings with the theme's colors, read in a view so a change of theme repaints it in place.
private struct SettingsWindow: View {
    let store: StackStore
    var body: some View {
        SettingsView(store: store).themedSheet()
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
