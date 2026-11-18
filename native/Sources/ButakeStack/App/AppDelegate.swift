import AppKit
import SwiftUI

/// Opening Stack again while it runs (Finder, Spotlight, Launchpad) means «I want to see it». The
/// main window starts suppressed and the app has no Dock icon, so without this nothing would show.
enum ReopenRule {
    static let link = URL(string: "butakestack://home")!
    /// Only when no window is on screen; with one visible, macOS already brings it forward.
    static func showsMainWindow(hasVisibleWindows: Bool) -> Bool { !hasVisibleWindows }
}

/// Work that needs NSApp: the theme's appearance and the activation policy, once the app has launched.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        // Database tunnels and sessions must not outlive the app.
        DatabaseClient.disconnectAllNow()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard ReopenRule.showsMainWindow(hasVisibleWindows: flag) else { return true }
        // A minimized window does not count as visible: bring it back instead of opening another.
        let minimized = sender.windows.filter { $0.isMiniaturized && $0.styleMask.contains(.titled) }
        if minimized.isEmpty { NSWorkspace.shared.open(ReopenRule.link) } else { minimized.forEach { $0.deminiaturize(nil) } }
        return false
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Before any window exists: a text field that starts editing early keeps the colors of the
        // appearance it was created in (dark text on a dark search field).
        MainActor.assumeIsolated { ThemeStore.shared.applyAppearance() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            // Dock, ⌘Tab and menu bar while a window is open; the menu bar only otherwise.
            ActivationController.shared.start()
            #if DEBUG
            QAHooks.appDidLaunch()
            #endif
            // A new Mac: what is missing is asked for in the setup assistant.
            Task {
                await StackStore.shared.checkSetupAtLaunch()
                KeychainNotice.showIfNeeded()
            }
        }
    }
}
