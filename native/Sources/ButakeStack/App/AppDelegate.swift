import AppKit
import SwiftUI

/// Work that needs NSApp: the theme's appearance and the activation policy, once the app has launched.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Quitting drops the table edits not yet saved in the database client: the user must agree.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let count = MainActor.assumeIsolated { DatabaseClient.shared.pendingTotal }
        guard count > 0 else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = String(format: L("db.confirm.quitEdits"), count)
        alert.addButton(withTitle: L("db.confirm.quitDiscard"))
        alert.addButton(withTitle: L("common.cancel"))
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Database tunnels and sessions must not outlive the app.
        DatabaseClient.disconnectAllNow()
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
