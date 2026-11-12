import AppKit
import WebKit

/// Thumbnails of each site, taken off-screen (the web view is never shown) and cached on disk so
/// the grid opens instantly. Refreshed on demand and once per app launch.
@MainActor @Observable final class SitePreviews: NSObject, WKNavigationDelegate {
    static let shared = SitePreviews()
    private(set) var images: [String: NSImage] = [:]
    private(set) var loading: Set<String> = []
    @ObservationIgnored private var queue: [(String, URL)] = []
    @ObservationIgnored private var current: (id: String, continuation: CheckedContinuation<Void, Never>)?
    @ObservationIgnored private var refreshed: Set<String> = []
    @ObservationIgnored private lazy var webView: WKWebView = {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800), configuration: configuration)
        view.navigationDelegate = self
        // WebKit only lays out and paints inside a window: host it in an invisible one, off screen.
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 1280, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.contentView = view
        window.orderBack(nil)
        host = window
        return view
    }()
    @ObservationIgnored private var host: NSWindow?

    private var folder: URL {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("cl.butake.stack/previews")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func image(for project: Project) -> NSImage? { images[project.id] }

    /// Shows the cached captures at once, then takes a fresh one of every site not refreshed yet
    /// in this launch.
    func refreshAll(_ projects: [Project]) {
        for project in projects where images[project.id] == nil {
            images[project.id] = NSImage(contentsOf: folder.appendingPathComponent("\(project.id).png"))
        }
        for project in projects where project.enabled && !refreshed.contains(project.id) { refresh(project) }
    }

    /// Forces a new capture (the refresh button), even if this launch already took one.
    func refresh(_ project: Project) {
        // An off site only shows the "site off" page: keep its last real capture.
        guard project.enabled, let url = project.url, !loading.contains(project.id) else { return }
        refreshed.insert(project.id)
        loading.insert(project.id)
        queue.append((project.id, url))
        if queue.count == 1 { Task { await drain() } }
    }

    private func drain() async {
        while let (id, url) = queue.first {
            await capture(id: id, url: url)
            queue.removeFirst()
            loading.remove(id)
        }
    }

    private func capture(id: String, url: URL) async {
        await withCheckedContinuation { continuation in
            current = (id, continuation)
            webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15))
        }
        // Wait until the document is complete and has painted something (client-side apps and
        // dev-server assets arrive after `didFinish`); give up after a few seconds.
        for _ in 0..<16 {
            try? await Task.sleep(for: .milliseconds(500))
            let ready = (try? await webView.evaluateJavaScript(
                "document.readyState === 'complete' && document.body && document.body.innerText.trim().length > 0 && document.fonts.status === 'loaded'"
            )) as? Bool ?? false
            if ready { break }
        }
        try? await Task.sleep(for: .milliseconds(600))
        let config = WKSnapshotConfiguration()
        config.snapshotWidth = 640
        guard let image = try? await webView.takeSnapshot(configuration: config), !Self.isBlank(image) else { return }
        images[id] = image
        if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: folder.appendingPathComponent("\(id).png"))
        }
    }

    /// A capture where every sampled pixel is the same color is a page that has not painted yet.
    private static func isBlank(_ image: NSImage) -> Bool {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return true }
        let first = rep.colorAt(x: 0, y: 0)
        for y in stride(from: 0, to: rep.pixelsHigh, by: max(rep.pixelsHigh / 24, 1)) {
            for x in stride(from: 0, to: rep.pixelsWide, by: max(rep.pixelsWide / 24, 1)) where rep.colorAt(x: x, y: y) != first {
                return false
            }
        }
        return true
    }

    private func finish() {
        current?.continuation.resume()
        current = nil
    }
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated { finish() }
    }
    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { finish() }
    }
    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { finish() }
    }
}
