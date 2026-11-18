import AppKit
import Foundation
import SwiftUI

// The sidebar follows the folders of the disk: the projects folder is the tree, a project of
// several parts is a folder marked as such, and what moves in Finder moves here. The engine draws
// the tree (`diskState`, `siteGroups`) and acts on the disk; this is what the app keeps of it.

/// What the engine says of the projects folder besides the folders themselves (`diskState`).
struct DiskState: Decodable, Equatable, Sendable {
    var enabled: Bool
    var root: String?
    var newRepos: [NewRepository] = []
    var suggestions: [MultipartSuggestion] = []
    var moves: [FollowedMove] = []
    /// The first comparison with `groups.json`, while the user has not decided.
    var migration: DiskPlan?
}

/// A repository in the projects folder that is not a project yet: offered, never added alone.
struct NewRepository: Decodable, Equatable, Hashable, Identifiable, Sendable {
    let path: String
    let name: String?
    /// The folder it is in; nil when it is directly in the projects folder.
    let folder: String?
    var id: String { path }
    var title: String { name ?? URL(fileURLWithPath: path).lastPathComponent }
}

/// A folder whose repositories share a prefix (`Salud`, `Salud-Web`): it may be a project of several parts.
struct MultipartSuggestion: Decodable, Equatable, Hashable, Identifiable, Sendable {
    let path: String
    let folder: String?
    let name: String
    let parts: [String]
    var id: String { path }
}

/// A project Stack followed to the folder it was moved to.
struct FollowedMove: Decodable, Equatable, Hashable, Sendable {
    let id: String
    let name: String
    let from: String
    let to: String
    let at: Int
}

struct DiskPlan: Decodable, Equatable, Sendable {
    var matches: [DiskPlanMatch] = []
    var proposals: [DiskProposal] = []
}
struct DiskPlanMatch: Decodable, Equatable, Hashable, Sendable {
    let group: String
    let name: String
    let path: String
}
struct DiskProposal: Decodable, Equatable, Hashable, Identifiable, Sendable {
    let group: String
    let name: String
    let path: String
    let moves: [DiskPlanMove]
    var id: String { group }
}
struct DiskPlanMove: Decodable, Equatable, Hashable, Identifiable, Sendable {
    let site: String
    let title: String
    let from: String
    let to: String
    let conflict: Bool
    var id: String { site }
}

/// The answer of a move on the disk: where the folder was and where it is.
struct DiskMoved: Decodable, Equatable, Sendable {
    let from: String
    let to: String
}
struct DiskCreated: Decodable, Sendable { let path: String }
struct DiskRevision: Decodable, Equatable, Sendable { let revision: Int }

/// A move of a folder or a project that waits for the user's yes.
struct DiskMoveRequest: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let from: String
    let into: String
    let intoName: String
}

/// A folder of the sidebar with how deep it is.
struct FolderEntry: Identifiable, Equatable {
    let group: ProjectGroup
    let depth: Int
    var id: String { group.id }
}

extension StackStore {
    /// What a drag of a folder carries (a project carries its id).
    static let folderDragPrefix = "folder:"
    private static let announcedKey = "disk.announcedMoveAt"

    var followsDisk: Bool { disk?.enabled == true }
    /// The projects folder as the engine reads it (the one the user chose, or `~/Stack/Projects`).
    var projectsRoot: String { disk?.root ?? Folder.projects }

    func folderPath(_ group: ProjectGroup) -> String? {
        group.path.map { (projectsRoot as NSString).appendingPathComponent($0) }
    }
    /// A path as the sidebar says it: inside the projects folder, relative to it.
    func relativeToProjects(_ path: String) -> String {
        let root = projectsRoot.hasSuffix("/") ? projectsRoot : projectsRoot + "/"
        return path.hasPrefix(root) ? String(path.dropFirst(root.count)) : path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    // MARK: The tree

    /// The folders in the order the sidebar draws them (parents before their folders), each with its depth.
    var folderTree: [FolderEntry] {
        let byId = Dictionary(groups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return groups.map { group in
            var depth = 0
            var parent = group.parent
            while let id = parent, let next = byId[id], depth < 12 { depth += 1; parent = next.parent }
            return FolderEntry(group: group, depth: depth)
        }
    }
    /// The folders a folder is in, from the nearest to the top.
    func ancestors(of group: ProjectGroup) -> [ProjectGroup] {
        var out: [ProjectGroup] = []
        var parent = group.parent
        while let id = parent, let next = groups.first(where: { $0.id == id }), out.count < 12 { out.append(next); parent = next.parent }
        return out
    }
    func newRepositories(in folder: String?) -> [NewRepository] {
        (disk?.newRepos ?? []).filter { $0.folder == folder }
    }
    func suggestion(for group: ProjectGroup) -> MultipartSuggestion? {
        group.isProject ? nil : disk?.suggestions.first { $0.folder == group.id }
    }

    // MARK: Reading the disk

    /// The state of the disk and the folders and projects as they are now. The engine also follows
    /// there what moved while the app was closed, and says so here.
    /// `root` only when the caller knows better than the user's setting (a test, an action on the folder it just read).
    func refreshDisk(root: String? = nil) async {
        guard let value: DiskState = try? await call(["method": "diskState", "root": root ?? projectsFolderOverride ?? Folder.projects]) else { return }
        if value != disk { disk = value }
        announce(value.moves)
        await refreshProjects()
    }

    /// A line for what the engine followed since the last one told: no project is lost in silence.
    private func announce(_ moves: [FollowedMove]) {
        let defaults = UserDefaults.standard
        guard let newest = moves.map(\.at).max() else { return }
        guard defaults.object(forKey: Self.announcedKey) != nil else { defaults.set(newest, forKey: Self.announcedKey); return }
        let seen = defaults.integer(forKey: Self.announcedKey)
        let fresh = moves.filter { $0.at > seen }
        guard !fresh.isEmpty else { return }
        defaults.set(newest, forKey: Self.announcedKey)
        if fresh.count == 1, let move = fresh.first {
            notify(String(format: L("groups.followedOne"), move.name, relativeToProjects(move.to)))
        } else {
            notify(String(format: L("groups.followedMany"), fresh.count))
        }
    }

    /// Listens to the daemon: a change of the projects folder reaches the sidebar at once.
    func startDiskWatch() {
        guard diskObserver == nil else { return }
        diskObserver = Task { [weak self] in
            while !Task.isCancelled, let self {
                do {
                    for try await _ in engine.diskStream() { await self.refreshDisk() }
                } catch { /* Retried below while the daemon is not there. */ }
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }
    func stopDiskWatch() {
        diskObserver?.cancel()
        diskObserver = nil
    }

    // MARK: Moving

    /// Asks to move a project or a folder (`folder:<id>`) into a folder (nil: the projects folder).
    func requestDiskMove(_ item: String, into group: String?) {
        let target = group.flatMap { id in groups.first { $0.id == id } }
        guard let into = target.flatMap(folderPath) ?? (group == nil ? projectsRoot : nil) else { return }
        diskMove(item, intoPath: into, intoName: target?.name ?? L("route.sites"), confirm: true)
    }

    func diskMove(_ item: String, intoPath: String, intoName: String, confirm: Bool) {
        let source: (title: String, path: String)
        if item.hasPrefix(Self.folderDragPrefix) {
            let id = String(item.dropFirst(Self.folderDragPrefix.count))
            guard let group = groups.first(where: { $0.id == id }), let path = folderPath(group) else { return }
            source = (group.name, path)
        } else {
            guard let project = projects.first(where: { $0.id == item }), !project.isMissing else { return }
            source = (project.title, project.path)
        }
        // Already there, or inside what moves: nothing to ask.
        let current = URL(fileURLWithPath: source.path).deletingLastPathComponent().standardizedFileURL.path
        guard current != URL(fileURLWithPath: intoPath).standardizedFileURL.path,
              !(intoPath + "/").hasPrefix(source.path + "/") else { return }
        let request = DiskMoveRequest(title: source.title, from: source.path, into: intoPath, intoName: intoName)
        if confirm { pendingDiskMove = request } else { Task { await performDiskMove(request) } }
    }

    func performDiskMove(_ request: DiskMoveRequest) async {
        var moved: DiskMoved?
        await run(L("busy.moving")) {
            moved = try await self.call(["method": "diskMove", "path": request.from, "into": request.into])
        }
        await refreshDisk(root: projectsRoot)
        if let moved { registerDiskUndo(moved, title: request.title) }
    }

    /// ⌘Z puts the folder back where it was (and ⇧⌘Z moves it again).
    private func registerDiskUndo(_ moved: DiskMoved, title: String) {
        let app: NSApplication? = NSApp
        guard let manager = app?.keyWindow?.undoManager ?? app?.mainWindow?.undoManager else { return }
        let back = URL(fileURLWithPath: moved.from).deletingLastPathComponent().path
        manager.registerUndo(withTarget: self) { store in
            Task { @MainActor in
                var undone: DiskMoved?
                await store.run(L("busy.moving")) {
                    undone = try await store.call(["method": "diskMove", "path": moved.to, "into": back])
                }
                await store.refreshDisk(root: store.projectsRoot)
                if let undone { store.registerDiskUndo(undone, title: title) }
            }
        }
        manager.setActionName(String(format: L("groups.undoMove"), title))
    }

    // MARK: Folders

    func createFolderOnDisk(named name: String, with sites: [String]) {
        let parent = newFolderParent.flatMap { id in groups.first { $0.id == id } }.flatMap(folderPath) ?? Folder.ensureProjects().path
        newFolderParent = nil
        Task {
            var created: DiskCreated?
            await run(L("busy.saving")) {
                created = try await self.call(["method": "diskCreateFolder", "parent": parent, "name": name])
            }
            if let created {
                // The user asked for this folder with these projects: no second question.
                for site in sites { diskMove(site, intoPath: created.path, intoName: name, confirm: false) }
            }
            await refreshDisk(root: projectsRoot)
        }
    }
    func renameFolderOnDisk(_ id: String, to name: String) {
        guard let path = groups.first(where: { $0.id == id }).flatMap(folderPath) else { return }
        Task {
            await run(L("busy.saving")) { let _: DiskMoved = try await self.call(["method": "diskRenameFolder", "path": path, "name": name]) }
            await refreshDisk(root: projectsRoot)
        }
    }
    /// A plain folder goes only when it is empty; a project of several parts goes back to a folder.
    func removeFolderOnDisk(_ id: String) {
        guard let group = groups.first(where: { $0.id == id }), let path = folderPath(group) else { return }
        if group.isProject { setMultipartOnDisk(id, false); return }
        Task {
            await run(L("busy.saving")) { let _: DiskCreated = try await self.call(["method": "diskRemoveFolder", "path": path]) }
            await refreshDisk(root: projectsRoot)
        }
    }
    func setMultipartOnDisk(_ id: String, _ on: Bool) {
        guard let rel = groups.first(where: { $0.id == id })?.path else { return }
        Task {
            await run(L("busy.saving")) { let _: [ProjectGroup] = try await self.call(["method": "diskMultipart", "path": rel, "on": on]) }
            await refreshDisk(root: projectsRoot)
            if on { openComposite(id) } else if route == .composite(id) { route = .home }
        }
    }
    func revealInFinder(_ group: ProjectGroup) {
        if let path = folderPath(group) { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path) }
    }

    // MARK: The first comparison with groups.json

    /// Converts what matches and, when the user accepts, moves the rest into folders of the disk.
    func migrateToDisk(accept: Bool) async {
        await run(L("busy.saving")) { let _: [String: DiskPlan] = try await self.call(["method": "diskMigrate", "accept": accept]) }
        await refreshDisk(root: projectsRoot)
    }
}
