import AppKit
import SwiftUI

/// The pages the window has shown, for Atrás and Adelante (⌘[, ⌘], the toolbar's buttons and the
/// two-finger swipe). A page already shown is not added twice in a row; going to a new page
/// forgets the ones ahead, like a browser.
struct RouteHistory: Equatable {
    private(set) var back: [Route] = []
    private(set) var forward: [Route] = []
    private(set) var current: Route = .home
    static let limit = 50

    var canGoBack: Bool { !back.isEmpty }
    var canGoForward: Bool { !forward.isEmpty }

    /// The window shows `route` now.
    mutating func visit(_ route: Route) {
        guard route != current else { return }
        back.append(current)
        if back.count > Self.limit { back.removeFirst(back.count - Self.limit) }
        forward = []
        current = route
    }

    /// The page before the current one, now current; nil at the start.
    mutating func goBack() -> Route? {
        guard let route = back.popLast() else { return nil }
        forward.append(current)
        current = route
        return route
    }

    /// The page after the current one, now current; nil at the end.
    mutating func goForward() -> Route? {
        guard let route = forward.popLast() else { return nil }
        back.append(current)
        current = route
        return route
    }
}

extension StackStore {
    /// Goes to the closest earlier page that still exists (a deleted project's page is skipped).
    func goBack() { step { history.goBack() } }
    func goForward() { step { history.goForward() } }

    private func step(_ next: () -> Route?) {
        while let target = next() {
            guard canShow(target) else { continue }
            if case .site(let id) = target { selectedSite = id }
            route = target
            return
        }
        // Nothing left to show: the history keeps following what is on screen.
        history.visit(route)
    }
}

/// Two fingers swiping on the trackpad: right goes back and left goes forward, like Safari and Finder.
private struct SwipeNavigation: ViewModifier {
    let store: StackStore
    @State private var monitor: Any?
    func body(content: Content) -> some View {
        content
            .onAppear {
                guard monitor == nil else { return }
                monitor = NSEvent.addLocalMonitorForEvents(matching: .swipe) { event in
                    // Only the window that has the keyboard, and only a clear horizontal swipe.
                    guard event.window?.isKeyWindow == true, event.deltaX != 0, event.deltaY == 0 else { return event }
                    MainActor.assumeIsolated { if event.deltaX < 0 { store.goBack() } else { store.goForward() } }
                    return nil
                }
            }
            .onDisappear { monitor.map(NSEvent.removeMonitor); monitor = nil }
    }
}

extension View {
    func swipeNavigation(_ store: StackStore) -> some View { modifier(SwipeNavigation(store: store)) }
}
