import AppKit

/// A menu bar app that behaves like a normal app while one of its windows is open: Dock icon,
/// ⌘Tab and menu bar. With no window left it goes back to the menu bar only. LSUIElement keeps
/// the launch at login silent (no window, no Dock).
enum ActivationRule {
    /// What the rule needs to know of a window.
    struct WindowFacts: Equatable {
        var visible: Bool
        var miniaturized = false
        var titled = true
        /// Panels (the menu bar panel, alerts, open and save panels) never count.
        var panel = false
        /// A sheet belongs to its window: opening one changes nothing.
        var sheet = false
        /// Above the normal level: the status item and the menu bar panel.
        var floating = false
    }

    /// A window the user opened: the main window, Settings or the QA window.
    static func counts(_ window: WindowFacts) -> Bool {
        (window.visible || window.miniaturized) && window.titled && !window.panel && !window.sheet && !window.floating
    }

    static func policy(for windows: [WindowFacts]) -> NSApplication.ActivationPolicy {
        windows.contains(where: counts) ? .regular : .accessory
    }
}

extension ActivationRule.WindowFacts {
    @MainActor init(_ window: NSWindow) {
        self.init(visible: window.isVisible, miniaturized: window.isMiniaturized, titled: window.styleMask.contains(.titled),
                  panel: window is NSPanel, sheet: window.sheetParent != nil, floating: window.level != .normal)
    }
}

/// Applies `ActivationRule` whenever a window appears, is minimized or closes.
@MainActor final class ActivationController {
    static let shared = ActivationController()
    private var observers: [NSObjectProtocol] = []
    /// Windows that announced they close: still drawn while they fade out, they no longer count.
    private var closing: Set<ObjectIdentifier> = []

    func start() {
        guard observers.isEmpty else { return }
        let names: [Notification.Name] = [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification,
                                          NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                                          NSWindow.didDeminiaturizeNotification]
        for name in names {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { note in
                let window = note.object as? NSWindow
                let reopened = note.name != NSWindow.didChangeOcclusionStateNotification
                MainActor.assumeIsolated { ActivationController.shared.update(front: window, reopened: reopened) }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
            let window = note.object as? NSWindow
            MainActor.assumeIsolated {
                if let window { ActivationController.shared.closing.insert(ObjectIdentifier(window)) }
                ActivationController.shared.update(front: nil)
            }
        })
        update(front: nil)
    }

    /// `front`: the window that changed, brought forward when the app becomes a regular one;
    /// `reopened`: it became key or main again, so it counts even if it had closed before.
    func update(front: NSWindow?, reopened: Bool = false) {
        if reopened, let front { closing.remove(ObjectIdentifier(front)) }
        // Once it is gone from the screen it is forgotten: if it shows again, it counts again.
        let shown = Set(NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init))
        closing.formIntersection(shown)
        let windows = NSApp.windows.filter { !closing.contains(ObjectIdentifier($0)) && ActivationRule.counts(.init($0)) }
        let policy = ActivationRule.policy(for: windows.map(ActivationRule.WindowFacts.init))
        guard policy != NSApp.activationPolicy() else { return }
        NSApp.setActivationPolicy(policy)
        #if DEBUG
        QAHooks.activationChanged(policy)
        #endif
        guard policy == .regular, let window = front.flatMap({ windows.contains($0) ? $0 : nil }) ?? windows.first else { return }
        // The menu bar of an app that was an accessory shows only once it is activated after the change.
        DispatchQueue.main.async {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
        }
    }
}
