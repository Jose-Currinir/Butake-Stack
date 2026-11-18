import AppKit
import Testing
@testable import ButakeStack

/// Dock and menu bar while a window the user opened is there; the menu bar only otherwise.
@Test func activationFollowsTheVisibleWindows() {
    typealias Facts = ActivationRule.WindowFacts
    let main = Facts(visible: true)
    let closed = Facts(visible: false)
    let statusItem = Facts(visible: true, titled: false, floating: true)
    let menuBarPanel = Facts(visible: true, titled: false, panel: true, floating: true)
    let sheet = Facts(visible: true, sheet: true)
    let alert = Facts(visible: true, panel: true)

    // Launch at login: only the status item, no Dock.
    #expect(ActivationRule.policy(for: []) == .accessory)
    #expect(ActivationRule.policy(for: [statusItem]) == .accessory)
    // The menu bar panel, sheets and alerts are not windows of their own.
    #expect(ActivationRule.policy(for: [statusItem, menuBarPanel]) == .accessory)
    #expect(ActivationRule.policy(for: [statusItem, sheet, alert]) == .accessory)
    // The main window or Settings, minimized too.
    #expect(ActivationRule.policy(for: [statusItem, main]) == .regular)
    #expect(ActivationRule.policy(for: [statusItem, main, sheet, menuBarPanel]) == .regular)
    #expect(ActivationRule.policy(for: [Facts(visible: false, miniaturized: true)]) == .regular)
    // The last one closed.
    #expect(ActivationRule.policy(for: [statusItem, closed]) == .accessory)
}

/// The page saved with the window reads back as the same page.
@Test func routesSurviveTheirStorage() {
    let routes: [Route] = [.home, .site("a:b"), .service("database"), .language("php"), .tool("ssh-terminal"), .tool("vault"), .tool("logs")]
        + UtilityCatalog.groups.map { Route.utilities($0.id) }
    for route in routes { #expect(Route(storageValue: route.storageValue) == route) }
    #expect(Route(storageValue: "") == nil)
    #expect(Route(storageValue: "site:") == nil)
}

/// Pages saved by older versions: the tools read as tools, the pages that became Ajustes as nothing
/// (the window opens on Inicio).
@Test func olderSavedPagesStillRead() {
    #expect(Route(storageValue: "vault") == .tool("vault"))
    #expect(Route(storageValue: "service:mail") == .tool("mail"))
    #expect(Route(storageValue: "service:dumps") == .tool("dumps"))
    #expect(Route(storageValue: "service:logs") == .tool("logs"))
    #expect(Route(storageValue: "general") == nil)
    #expect(Route(storageValue: "plugins") == nil)
    #expect(Route(storageValue: "service:web") == nil)
    // Utilidades was one page: it opens on its first section, as does a section that no longer exists.
    #expect(Route(storageValue: "utilities") == .utilities("ai"))
    #expect(Route(storageValue: "utilities:gone") == .utilities("ai"))
}

/// Every link to Utilidades opens the section that holds the utility, or the first one.
@Test func utilitiesOpenOnTheirSection() {
    #expect(UtilityCatalog.route(for: "aws") == .utilities("cloud"))
    #expect(UtilityCatalog.route(for: "gh") == .utilities("repos"))
    #expect(UtilityCatalog.route(for: "codex") == .utilities("ai"))
    #expect(UtilityCatalog.route(for: "rustup") == .utilities("ai"))
    #expect(UtilityCatalog.route() == .utilities("ai"))
    #expect(UtilityCatalog.groups.map(\.id) == ["ai", "cloud", "repos"])
}
