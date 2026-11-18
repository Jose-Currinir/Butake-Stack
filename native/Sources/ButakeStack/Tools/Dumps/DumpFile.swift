import AppKit
import UniformTypeIdentifiers

/// The file a dump says it was called from. The path comes in the body of the dump, which any local
/// process can send, so it is data: it opens only when it is a text or code file inside a folder of
/// a registered project, and only in an editor (never in the application macOS picks for it).
enum DumpFile {
    /// The canonical file to open, or nil when the path is not one of a project's text or code files.
    static func target(_ path: String, projectFolders: [String]) -> URL? {
        guard path.hasPrefix("/") else { return nil }
        let file = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
        let values = try? file.resourceValues(forKeys: [.isRegularFileKey])
        guard values?.isRegularFile == true else { return nil }
        guard let type = UTType(filenameExtension: file.pathExtension), type.conforms(to: .text) || type.conforms(to: .sourceCode) else { return nil }
        let inside = projectFolders.contains { folder in
            let root = URL(fileURLWithPath: folder).resolvingSymlinksInPath().standardizedFileURL.path
            return root != "/" && file.path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
        }
        return inside ? file : nil
    }

    /// Opens it in the first editor installed; without one it is shown in Finder, not opened.
    @MainActor static func open(_ path: String, store: StackStore) {
        guard let file = target(path, projectFolders: store.projects.map(\.path)) else { return }
        for id in Editor.candidates {
            if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                NSWorkspace.shared.open([file], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
                return
            }
        }
        NSWorkspace.shared.activateFileViewerSelecting([file])
    }
}
