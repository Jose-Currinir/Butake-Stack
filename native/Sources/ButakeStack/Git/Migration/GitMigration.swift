import Foundation
import SwiftUI

/// What the former Butake Git app left on this Mac that the Git tool can use: the repositories it
/// listed as recent and its equivalent preferences. Read from its preferences file
/// (`~/Library/Preferences/cl.butake.git.native.plist`), only read: nothing of it is changed or
/// deleted, and its accounts (in its own Keychain items) are never read; they are connected again
/// in Ajustes › Cuentas.
struct GitMigrationSource: Equatable, Sendable {
    /// The former app's bundle identifier, which names its preferences file.
    static let bundleID = "cl.butake.git.native"

    /// Repository folders that still exist, in the order the former app listed them.
    var repositories: [String]
    /// Recent repositories whose folder is gone (they are not brought).
    var missing: Int
    /// «Buscar cambios cada 5 minutos» was turned on there.
    var autoFetch: Bool?
    /// The folder it cloned into, when it still exists.
    var cloneParent: String?

    var isEmpty: Bool { repositories.isEmpty && autoFetch != true && cloneParent == nil }

    /// The preferences file of the former app under `home`.
    static func file(home: String) -> URL {
        URL(fileURLWithPath: home).appendingPathComponent("Library/Preferences/\(bundleID).plist")
    }

    /// Reads the former app's preferences under `home`; nil when there are none.
    static func read(home: String, fileManager: FileManager = .default) -> GitMigrationSource? {
        guard let data = try? Data(contentsOf: file(home: home)),
              let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        return parse(values, fileManager: fileManager)
    }

    /// The values of the preferences that have an equivalent in the tool.
    static func parse(_ values: [String: Any], fileManager: FileManager = .default) -> GitMigrationSource {
        var seen = Set<String>()
        var repositories: [String] = []
        var missing = 0
        for raw in values["recentRepositories"] as? [String] ?? [] {
            guard raw.hasPrefix("/") else { continue }
            let path = URL(fileURLWithPath: raw).standardizedFileURL.path
            guard seen.insert(path).inserted else { continue }
            if fileManager.fileExists(atPath: (path as NSString).appendingPathComponent(".git")) { repositories.append(path) } else { missing += 1 }
        }
        var isFolder: ObjCBool = false
        let parent = (values["cloneParent"] as? String).flatMap { path in
            path.hasPrefix("/") && fileManager.fileExists(atPath: path, isDirectory: &isFolder) && isFolder.boolValue ? path : nil
        }
        return GitMigrationSource(repositories: repositories, missing: missing, autoFetch: values["autoFetch"] as? Bool, cloneParent: parent)
    }
}

/// «Traer mis repositorios»: offered once the tool is on while the former app's preferences are on
/// this Mac and nothing was brought yet. It is always the user's explicit action.
@MainActor @Observable final class GitMigration {
    static let shared = GitMigration()

    /// Where the sheet is shown: the window that asked for it.
    enum Presenter { case settings, tool }

    /// What there is to bring; nil while unread or when there is nothing.
    private(set) var source: GitMigrationSource?
    /// The sheet on screen, and where.
    var presenter: Presenter?
    /// What the last run brought, for the sheet's summary.
    private(set) var result: GitMigrationResult?

    /// Brought once per Mac; QA never writes it.
    private static let doneKey = "git.migration.done"
    var done: Bool { UserDefaults.standard.bool(forKey: Self.doneKey) }

    /// The home whose former app is read: `HOME` when set (a test's or QA's folder), else the user's.
    nonisolated static var home: String { ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory() }

    /// Whether «Traer mis repositorios…» is offered.
    var offered: Bool { !done && result == nil && source.map { !$0.isEmpty } == true }

    /// Reads the former app's preferences again (cheap: one small file).
    func check() {
        let found = GitMigrationSource.read(home: Self.home)
        if found != source { source = found }
    }

    /// Right after the tool is turned on: the offer, in the window that turned it on.
    func offerAfterActivation(in presenter: Presenter) {
        check()
        if offered { self.presenter = presenter }
    }

    /// Adds every repository not listed yet (projects and added ones stay as they are) and sets the
    /// equivalent preferences. Reads the former app only; the accounts are not touched.
    func bring(tool: GitTool = .shared) async -> GitMigrationResult {
        check()
        guard let source else { return GitMigrationResult(added: 0, known: 0, missing: 0, failed: []) }
        await tool.loadList()
        let known = Set(tool.entries.map(\.path))
        var added = 0, already = 0
        var failed: [String] = []
        for path in source.repositories {
            if known.contains(path) { already += 1; continue }
            do {
                tool.list = try await StackStore.shared.call(["method": "gitRepositoryAdd", "path": path])
                added += 1
            } catch {
                failed.append((path as NSString).lastPathComponent)
            }
        }
        if source.autoFetch == true { GitStatusBoard.shared.autoFetch = true }
        if let parent = source.cloneParent, UserDefaults.standard.string(forKey: GitCloneSheet.parentKey) == nil {
            UserDefaults.standard.set(parent, forKey: GitCloneSheet.parentKey)
        }
        if !StackStore.qaWindow { UserDefaults.standard.set(true, forKey: Self.doneKey) }
        let result = GitMigrationResult(added: added, known: already, missing: source.missing, failed: failed)
        self.result = result
        return result
    }
}

/// What «Traer mis repositorios» did.
struct GitMigrationResult: Equatable, Sendable {
    var added: Int
    /// Already listed (a Stack project or added before).
    var known: Int
    /// Recent in the former app, but their folder is gone.
    var missing: Int
    /// Folders the tool could not add (not a repository any more, no access).
    var failed: [String]
}
