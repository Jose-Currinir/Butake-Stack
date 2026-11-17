import AppKit
import SwiftUI

// Three real columns, like Mail and Xcode: a page with a list of its own (connections, hosts, the
// vault's items, messages…) puts it in the window's content column, between the sidebar and its
// detail, and every other page keeps two columns. The split view always has three columns: the
// content one is collapsed while the page has no list, so changing pages never rebuilds the
// sidebar (its selection, scroll, search and open sections). See docs/estandar-ui.md, rule 1.

extension Route {
    /// Whether the page brings a list to the window's content column. A page adopts the column with
    /// a case here and its list in `ContentColumn`; its own view is then only the detail.
    var hasContentColumn: Bool {
        switch self {
        case .tool("database-client"), .tool("mail"), .tool("dumps"), .tool("logs"), .tool("vault"), .tool("ssh-terminal"), .tool("aws"), .tool("gcp"), .tool("git"), .tool("skills"): true
        // Componentes: Servicios, Lenguajes and Utilidades list their categories (P-37).
        case .service, .language, .utilities: true
        default: false
        }
    }
}

/// The window's content column: the list of the page on screen (nothing while it has none). The
/// split view keeps the width the user gave it with the window (one width for every page).
struct ContentColumn: View {
    @Bindable var store: StackStore
    var body: some View {
        Group {
            switch store.route {
            case .tool("database-client") where store.canShow(store.route): DatabaseConnectionList(client: .shared)
            case .tool("mail") where store.canShow(store.route): MailList(store: store)
            case .tool("dumps") where store.canShow(store.route): DumpsList(store: store)
            case .tool("logs"): LogSourceList(store: store)
            case .tool("vault") where store.canShow(store.route) && VaultSession.shared.isUnlocked: VaultList()
            case .tool("ssh-terminal") where store.canShow(store.route): SSHHostList(terminal: .shared, workspace: .shared)
            case .tool("aws") where store.canShow(store.route): AWSProfileList(tool: .shared)
            case .tool("gcp") where store.canShow(store.route): GCPAccountList(tool: .shared)
            case .service, .language, .utilities: if let (component, _) = Component.of(store.route) { ComponentList(store: store, component: component) }
            case .tool("git") where store.canShow(store.route): GitContentList(tool: .shared)
            case .tool("skills") where store.canShow(store.route): SkillsGroupList(tool: .shared)
            default: Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Like the sidebar: the system's list material, or the theme's own color.
        .background { if Brand.customBackgrounds { (Brand.theme.sidebar?.color ?? Brand.background).ignoresSafeArea() } }
        .navigationSplitViewColumnWidth(min: 200, ideal: 260, max: 400)
    }
}

extension StackStore {
    /// The page on screen has its list beside the sidebar (a tool that is off has no page).
    /// Locked, the vault is one pane with «Desbloquear»; its apps and services only once it opens.
    var showsContentColumn: Bool { route.hasContentColumn && canShow(route) && (route != .tool("vault") || VaultSession.shared.isUnlocked) }
}

extension View {
    /// Shows the window's content column only while it holds the page's list (applied to the detail,
    /// which is always on screen).
    func contentColumn(shown: Bool) -> some View {
        background { ContentColumnCollapser(collapsed: !shown) }
    }
}

/// SwiftUI's column visibility has no "sidebar and detail" state for three columns: this collapses
/// the split view's content item instead, and keeps it so when the split view lays itself out again
/// (the sidebar's button, full screen). Collapsed, the item and its divider take no room.
private struct ContentColumnCollapser: NSViewRepresentable {
    let collapsed: Bool

    @MainActor final class Coordinator {
        var collapsed = false
        weak var item: NSSplitViewItem?
        var observer: NSObjectProtocol?

        func apply() {
            guard let item, item.isCollapsed != collapsed else { return }
            // While on screen the user can't drag it closed; only the page decides.
            if collapsed { item.canCollapse = true }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                context.allowsImplicitAnimation = false
                item.isCollapsed = collapsed
            }
            if !collapsed { item.canCollapse = false }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { NSView() }
    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.observer.map(NotificationCenter.default.removeObserver)
    }

    func updateNSView(_ view: NSView, context: Context) {
        let coordinator = context.coordinator
        coordinator.collapsed = collapsed
        // The split view is an ancestor once the view is in the window.
        DispatchQueue.main.async {
            if coordinator.item == nil, let controller = Self.controller(of: view) {
                coordinator.item = controller.splitViewItems[1]
                coordinator.observer = NotificationCenter.default.addObserver(
                    forName: NSSplitView.didResizeSubviewsNotification, object: controller.splitView, queue: .main) { _ in
                    MainActor.assumeIsolated { coordinator.apply() }
                }
            }
            coordinator.apply()
        }
    }

    private static func controller(of view: NSView) -> NSSplitViewController? {
        var current = view.superview
        while let next = current {
            if let split = next as? NSSplitView, let controller = split.delegate as? NSSplitViewController,
               controller.splitViewItems.count == 3 { return controller }
            current = next.superview
        }
        return nil
    }
}
