import AppKit

/// Butake Git, the ecosystem's Git client: opening a site's repository there, by its URL scheme
/// (`butakegit://open?path=`) or, for older builds, as a folder handed to the app.
@MainActor enum ButakeGit {
    static let bundleID = "cl.butake.git.native"
    static var appURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) }
    static var installed: Bool { appURL != nil }
    static func open(_ path: String) {
        guard let app = appURL else { return }
        var components = URLComponents()
        components.scheme = "butakegit"; components.host = "open"
        components.queryItems = [URLQueryItem(name: "path", value: path)]
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        if let url = components.url, NSWorkspace.shared.urlForApplication(toOpen: url) != nil {
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: configuration)
        } else {
            NSWorkspace.shared.open([URL(fileURLWithPath: path)], withApplicationAt: app, configuration: configuration)
        }
    }
}
