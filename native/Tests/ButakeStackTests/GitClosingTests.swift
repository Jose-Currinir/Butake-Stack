import Foundation
import Testing
@testable import ButakeStack

// G-5: the history's rows, worktrees, the dictionary, the menu bar's summary and bringing the
// repositories of the former app. Every path, repository and preference here is made up.

// MARK: Historial

@Test func aWideGraphNarrowsItsLanesAndLeavesTheMessageItsRoom() {
    // A usual graph keeps its lanes; a wide one never takes more than `widest`.
    #expect(GitCommitGraphCell.laneWidth(lanes: 1) == GitCommitGraphCell.lane)
    #expect(GitCommitGraphCell.laneWidth(lanes: 4) == GitCommitGraphCell.lane)
    for lanes in [5, 6, 8] {
        let lane = GitCommitGraphCell.laneWidth(lanes: lanes)
        #expect(lane < GitCommitGraphCell.lane)
        #expect(GitCommitGraphCell.width(lanes: lanes, lane: lane) <= GitCommitGraphCell.widest)
    }
    // Past what fits, the lanes stop narrowing: they stay readable.
    #expect(GitCommitGraphCell.laneWidth(lanes: 40) == GitCommitGraphCell.narrowLane)
}

// MARK: «Más…» › Carpetas de trabajo

@Test func theRepositorysOwnFolderIsTheFirstWorktreeAndNeverRemoved() {
    let listed = "worktree /tmp/made-up/repo\nHEAD abc\nbranch refs/heads/develop\n\nworktree /tmp/made-up/repo-feature\nHEAD def\nbranch refs/heads/feature/x\n\nworktree /tmp/made-up/repo-old\nHEAD 123\ndetached\n"
    let folders = GitWorktree.parse(listed)
    #expect(folders.map(\.branch) == ["develop", "feature/x", ""])
    #expect(folders.map(\.main) == [true, false, false])
}

// MARK: Diccionario

@Test func theDictionaryHasEveryCommandOfTheEngineAndTheWords() throws {
    let dictionary = GitDictionary.load()
    #expect(dictionary.commands.count == 152)
    #expect(dictionary.concepts.count > 40)
    // The same commands, in the same order, as the engine's catalog.
    let engine = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("engine/src/git/commands.json")
    struct Catalog: Decodable { struct Entry: Decodable { var name: String }; var commands: [Entry] }
    let catalog = try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: engine))
    #expect(dictionary.commands.map(\.name) == catalog.commands.map(\.name))
    for command in dictionary.commands {
        #expect(!command.description.isEmpty, "\(command.name)")
        #expect(GitDictionary.categories.contains(command.category), "\(command.name)")
        #expect(command.documentationURL != nil, "\(command.name)")
    }
    for category in GitDictionary.categories + ["all"] { #expect(localized("git.dictionary.category.\(category)") != nil) }
    for mode in GitDictionarySheet.Mode.allCases { #expect(localized("git.dictionary.mode.\(mode.rawValue)") != nil) }
    // Search by name or by its explanation; a category narrows it.
    #expect(dictionary.commands(matching: "rebase", category: nil).contains { $0.name == "rebase" })
    #expect(dictionary.commands(matching: "", category: "everyday").allSatisfy { $0.category == "everyday" })
    #expect(!dictionary.concepts(matching: "rama").isEmpty)
}

// MARK: Barra de menús

@Test func theMenuBarListsOnlyWhatNeedsSomethingAndNeverPushesMainFromThere() {
    let entry = GitRepositoryEntry(path: "/tmp/made-up/app", name: "app", project: nil, missing: false)
    func row(_ branch: String, changes: Int = 0, ahead: Int = 0, behind: Int = 0, unfinished: Bool = false) -> GitStatusRow {
        GitStatusRow(entry: entry, summary: GitRepositorySummary(branch: branch, changes: changes, ahead: ahead, behind: behind, unfinished: unfinished))
    }
    #expect(!row("develop").needsAttention)
    let both = row("develop", changes: 2, ahead: 1, behind: 3)
    #expect(both.needsAttention && both.canPull && !both.canPush)
    #expect(both.detail.contains("develop"))
    let ahead = row("feature/x", ahead: 2)
    #expect(ahead.canPush && !ahead.canPull)
    let main = row("main", ahead: 2)
    #expect(main.needsAttention && !main.canPush)
    let halfway = row("develop", behind: 1, unfinished: true)
    #expect(halfway.needsAttention && !halfway.canPull)
}

// MARK: Traer de Butake Git

/// A made-up copy of the former app's preferences in a temporary home: what has an equivalent comes,
/// folders that are gone don't, and the file is only read.
@Test func theFormerAppsRepositoriesAndPreferencesAreReadFromAMadeUpHome() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("git-migration-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: home) }
    let first = home.appendingPathComponent("Code/first"), second = home.appendingPathComponent("Code/second")
    let notRepository = home.appendingPathComponent("Code/plain"), clones = home.appendingPathComponent("Clones")
    for folder in [first.appendingPathComponent(".git"), second.appendingPathComponent(".git"), notRepository, clones] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    #expect(GitMigrationSource.read(home: home.path) == nil)

    let preferences: [String: Any] = [
        "recentRepositories": [first.path, second.path + "/", first.path, notRepository.path, home.appendingPathComponent("gone").path, "relative/path"],
        "autoFetch": true,
        "cloneParent": clones.path,
        "notchEnabled": true,
        "repositoryBookmarks": ["x": Data([1, 2])],
    ]
    let file = GitMigrationSource.file(home: home.path)
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try PropertyListSerialization.data(fromPropertyList: preferences, format: .binary, options: 0).write(to: file)
    let before = try Data(contentsOf: file)

    let source = try #require(GitMigrationSource.read(home: home.path))
    #expect(source.repositories == [first.standardizedFileURL.path, second.standardizedFileURL.path])
    #expect(source.missing == 2)
    #expect(source.autoFetch == true)
    #expect(source.cloneParent == clones.path)
    #expect(!source.isEmpty)
    // Read only: the former app's file is as it was.
    #expect(try Data(contentsOf: file) == before)

    // Nothing with an equivalent: nothing to offer.
    #expect(GitMigrationSource.parse(["notchEnabled": true, "cloneParent": home.appendingPathComponent("gone").path]).isEmpty)
}

// MARK: Proyecto sin repositorio

@Test func aFolderInsideAnotherRepositoryGetsNoOfferToCreateOne() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("git-create-here-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: home) }
    let outer = home.appendingPathComponent("outer"), inner = outer.appendingPathComponent("packages/web")
    let alone = home.appendingPathComponent("alone")
    for folder in [outer.appendingPathComponent(".git"), inner, alone] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
    #expect(GitCreateHereSection.insideRepository(inner.path))
    #expect(GitCreateHereSection.insideRepository(outer.path))
    #expect(!GitCreateHereSection.insideRepository(alone.path))
}
