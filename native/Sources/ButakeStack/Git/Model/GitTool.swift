import AppKit
import SwiftUI

/// The Git tool's state, shared by its content column (repository picker and the tab's list), its
/// detail and the «Git» row of a project: whether Git is usable, the repositories it knows and
/// the open one (`repository`, see `GitRepository`), and the tab on screen.
@MainActor @Observable final class GitTool {
    static let shared = GitTool()

    var requirement: GitRequirement = .checking
    var list = GitRepositoryList()
    var loaded = false
    /// The open repository; nil until one is chosen.
    private(set) var repository: GitRepository?
    /// A repository being opened (its path), for the picker's progress.
    private(set) var opening: String?
    var tab: GitTab = .changes
    /// «Nueva rama…» asked from the toolbar, Ramas or the Git menu.
    var creatingBranch = false
    /// «Diccionario de Git» on screen (Git and Ayuda menus, the repository chooser).
    var showingDictionary = false
    /// Branch and changes of each added repository, read when the picker opens.
    var summaries: [String: GitRepositorySummary] = [:]

    @ObservationIgnored private var store: StackStore { .shared }
    /// Whether the repositories added to a project of several parts exist on disk, read when the
    /// list loads (not on every evaluation of `entries`).
    @ObservationIgnored private var missingPaths: [String: Bool] = [:]
    /// The last repository open, reopened with the tool (a preference of this Mac; QA never writes it).
    private static let lastKey = "git.repository"

    // MARK: Loading

    /// Checks Git, reads the repositories and reopens the last one.
    func load() async {
        await checkRequirement()
        guard requirement.ready else { loaded = true; return }
        await loadList()
        loaded = true
        if repository == nil, let last = UserDefaults.standard.string(forKey: Self.lastKey), entries.contains(where: { $0.path == last && !$0.missing }) {
            await open(last)
        }
    }

    /// Without Apple's command line tools Git is not asked (its stub would open an installer).
    func checkRequirement() async {
        #if DEBUG
        if let forced = GitQA.requirement { requirement = forced; return }
        #endif
        await store.refreshAppleTools()
        guard store.appleTools else { requirement = .missing; return }
        do {
            let capabilities: GitCapabilities = try await store.call(["method": "gitCapabilities"])
            requirement = .of(version: capabilities.version)
        } catch {
            requirement = .missing
        }
    }

    func loadList() async {
        do {
            let next: GitRepositoryList = try await store.call(["method": "gitRepositories"])
            if next != list { list = next }
            let paths = store.composites.flatMap(\.repositories)
            missingPaths = await Task.detached { Dictionary(paths.map { ($0, !FileManager.default.fileExists(atPath: $0 + "/.git")) }, uniquingKeysWith: { first, _ in first }) }.value
        } catch {
            // A list left on screen stops its reading: that is not an error to show.
            let failure = GitFailure(error)
            if !failure.cancelled { repository?.failure = failure }
        }
    }

    /// Projects of Stack with a repository, then the ones added by hand (to the tool, or to a
    /// project of several parts).
    var entries: [GitRepositoryEntry] {
        let base = list.projects.map { GitRepositoryEntry(path: $0.path, name: $0.name, project: $0.id, missing: false) }
            + list.added.map { GitRepositoryEntry(path: $0.path, name: $0.name, project: nil, missing: $0.missing) }
        var known = Set(base.map(\.path))
        let extra = store.composites.flatMap(\.repositories).filter { known.insert($0).inserted }.map { path in
            GitRepositoryEntry(path: path, name: URL(fileURLWithPath: path).lastPathComponent, project: nil, missing: missing(path))
        }
        return base + extra
    }

    /// Whether a part's repository is gone: read once per list load, then remembered.
    private func missing(_ path: String) -> Bool {
        if let known = missingPaths[path] { return known }
        let value = !FileManager.default.fileExists(atPath: path + "/.git")
        missingPaths[path] = value
        return value
    }

    /// The project of several parts a repository belongs to: one of its parts', or added to it.
    func composite(of entry: GitRepositoryEntry) -> ProjectGroup? {
        store.composites.first { group in
            entry.project.map(group.sites.contains) == true || group.repositories.contains(entry.path)
        }
    }

    /// The repositories of a project of several parts: its parts' (in their order), then the ones
    /// added to it.
    func entries(of group: ProjectGroup, in all: [GitRepositoryEntry]? = nil) -> [GitRepositoryEntry] {
        let all = all ?? entries
        let parts = group.sites.compactMap { id in all.first { $0.project == id } }
        let added = group.repositories.compactMap { path in all.first { $0.path == path && $0.project == nil } }
        return parts + added
    }

    /// Branch, changes and ↓↑ of a row: a project's from the base (`gitStatus`), the open one live,
    /// an added one from its last read.
    func summary(of entry: GitRepositoryEntry) -> GitRepositorySummary? {
        if let repository, repository.root == entry.path {
            let snapshot = repository.snapshot
            return GitRepositorySummary(branch: snapshot.detached ? "" : snapshot.branch, changes: repository.files.count,
                                        ahead: snapshot.ahead, behind: snapshot.behind, unfinished: !snapshot.operation.isEmpty,
                                        problems: GitProblemSources.shared.problems(for: repository).count)
        }
        if let project = entry.project, let info = store.git[project] {
            return GitRepositorySummary(branch: info.branch, changes: info.changes, ahead: info.ahead, behind: info.behind, unfinished: false)
        }
        return summaries[entry.path]
    }

    /// Reads the state of the added repositories (the projects' comes from the base).
    func loadSummaries() async {
        await withTaskGroup(of: (String, GitRepositorySummary?).self) { group in
            for entry in entries where entry.project == nil && !entry.missing {
                let store = self.store
                group.addTask {
                    let snapshot: GitSnapshot? = try? await store.call(["method": "gitSnapshot", "path": entry.path, "limit": 1])
                    return (entry.path, snapshot.map {
                        GitRepositorySummary(branch: $0.detached ? "" : $0.branch, changes: $0.files.count, ahead: $0.ahead, behind: $0.behind,
                                             unfinished: !$0.operation.isEmpty)
                    })
                }
            }
            for await (path, summary) in group { summaries[path] = summary }
        }
    }

    // MARK: Opening

    /// Opens the repository that contains `path` (a project's folder, a repository's subfolder).
    func open(_ path: String) async {
        guard opening == nil else { return }
        if repository?.root == path { return }
        opening = path
        defer { opening = nil }
        do {
            let snapshot: GitSnapshot = try await store.call(["method": "gitOpen", "path": path])
            repository?.stopWatching()
            let next = GitRepository(snapshot: snapshot, store: store)
            next.watch()
            next.selectedFile = next.files.first(where: { !$0.conflicted })?.path
            repository = next
            #if DEBUG
            if !StackStore.qaWindow { UserDefaults.standard.set(snapshot.root, forKey: Self.lastKey) }
            #else
            UserDefaults.standard.set(snapshot.root, forKey: Self.lastKey)
            #endif
            await loadList()
        } catch {
            let failure = GitFailure(error)
            if let repository { repository.failure = failure } else { openFailure = failure }
        }
    }

    /// Why the last repository could not be opened while none is open.
    var openFailure: GitFailure?

    /// «Agregar repositorio…»: a folder inside a repository; the tool keeps its top folder.
    func chooseAndAdd() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = L("git.repo.addPrompt")
        panel.message = L("git.repo.addMessage")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await add(url.path) }
    }

    func add(_ path: String) async {
        // A repository cloned or added since the last list load is no longer missing.
        missingPaths = [:]
        do {
            let next: GitRepositoryList = try await store.call(["method": "gitRepositoryAdd", "path": path])
            list = next
            await open(path)
        } catch {
            openFailure = GitFailure(error)
        }
    }

    /// «Quitar de la lista»: the folder stays as it is.
    func forget(_ entry: GitRepositoryEntry) async {
        do {
            list = try await store.call(["method": "gitRepositoryForget", "path": entry.path])
            if repository?.root == entry.path { close() }
        } catch {
            openFailure = GitFailure(error)
        }
    }

    func close() {
        repository?.stopWatching()
        repository = nil
        #if DEBUG
        if !StackStore.qaWindow { UserDefaults.standard.removeObject(forKey: Self.lastKey) }
        #else
        UserDefaults.standard.removeObject(forKey: Self.lastKey)
        #endif
    }

    /// The tool was turned off: nothing keeps watching its folders. The last repository is still
    /// remembered and opens again when the tool comes back.
    func suspend() {
        repository?.stopWatching()
        repository = nil
        loaded = false
    }

    /// From a project's page or a link: the tool with that repository open.
    func show(_ path: String) {
        store.openTool("git")
        Task { await open(path) }
    }
}

/// A row of the repository picker.
struct GitRepositoryEntry: Identifiable, Hashable, Sendable {
    let path: String
    let name: String
    /// The Stack project it belongs to, when it is one.
    let project: String?
    let missing: Bool
    var id: String { path }
}

/// What a picker row says of a repository.
struct GitRepositorySummary: Hashable, Sendable {
    var branch: String
    var changes: Int
    var ahead: Int
    var behind: Int
    var unfinished: Bool
    /// What Problemas counts; only known for the open repository.
    var problems = 0

    /// What needs fixing, as a count: Problemas' for the open repository; for another one, an
    /// operation left half done.
    var attention: Int { problems > 0 ? problems : (unfinished ? 1 : 0) }
}
