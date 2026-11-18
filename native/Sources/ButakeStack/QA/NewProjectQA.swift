#if DEBUG
import AppKit
import Foundation

/// Screenshots of «Nuevo proyecto» (`BUTAKE_QA_NEW=<kind>`) in what a click would reach:
/// BUTAKE_QA_NEW_SCROLL=end scrolls the form to its end; BUTAKE_QA_NEW_PHASE=creating|done shows
/// the progress or the finished view with made-up data, without creating anything on disk nor
/// calling the engine.
extension QAHooks {
    private static func newValue(_ name: String) -> String? {
        StackStore.qaWindow ? ProcessInfo.processInfo.environment[name] : nil
    }
    static var newPhase: String? { newValue("BUTAKE_QA_NEW_PHASE") }
    static var newScroll: String? { newValue("BUTAKE_QA_NEW_SCROLL") }
    /// "open": the sheet on «Abrir existente» instead of a kind.
    static var newKind: String? { newValue("BUTAKE_QA_NEW") }

    /// The sheet's form scrolled to its end: its widest scroll view on the right of the kinds list.
    @MainActor static func scrollNewProjectToEnd() {
        func scrolls(_ view: NSView) -> [NSScrollView] { ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(scrolls) }
        let sheet = NSApp.windows.first { $0.isVisible && $0.identifier?.rawValue.hasPrefix("main") == true }?.attachedSheet
        guard let content = sheet?.contentView,
              let scroll = scrolls(content).max(by: { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }),
              let document = scroll.documentView else { return }
        document.scroll(NSPoint(x: 0, y: document.isFlipped ? document.bounds.height : 0))
    }
}

extension NewProjectSheet {
    /// Applies the QA environment once the sheet is up.
    func qaNewProject() async {
        if QAHooks.newKind == "open" { selection = .open }
        if QAHooks.newKind == "clone" { selection = .clone }
        if QAHooks.newScroll == "end" {
            try? await Task.sleep(for: .seconds(0.8))
            QAHooks.scrollNewProjectToEnd()
        }
        guard let simulated = QAHooks.newPhase else { return }
        name = "tienda"
        started = Date().addingTimeInterval(-42)
        let commands = steps.prefix(max(1, steps.count / 2 + 1)).map { "$ \($0.marker)" }
        log = commands.flatMap { [$0, "  ✓ \($0.dropFirst(2))"] }
        switch simulated {
        case "creating":
            phase = .creating
        case "done":
            let json: [String: Any] = [
                "id": "tienda", "name": "tienda", "path": NSHomeDirectory() + "/Proyectos/tienda",
                "domains": ["tienda.test"], "https": info.proxied, "kind": kind, "runtime": ["php": "8.4", "node": "22"],
                "docroot": "public", "services": [], "databases": [], "processes": [], "enabled": false,
            ]
            let project = (try? JSONSerialization.data(withJSONObject: json)).flatMap { try? JSONDecoder().decode(Project.self, from: $0) }
            var created = CreatedProject(project: info.app ? nil : project, path: NSHomeDirectory() + "/Proyectos/tienda",
                                         notes: kind == "laravel" ? ["kit_uses_pest", "frontend_needs_node"] : [])
            created.seconds = 42
            phase = .done(created)
        default:
            break
        }
    }
}
#endif
