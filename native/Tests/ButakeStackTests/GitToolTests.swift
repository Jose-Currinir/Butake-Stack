import Foundation
import Testing
@testable import ButakeStack

// The Git tool's rules without a window: the primary button's state, Git's version, errors in
// plain words, inclusion of a file, the watcher's filter and the texts every state needs.

private func snapshot(branch: String = "develop", ahead: Int = 0, behind: Int = 0, upstream: String = "origin/develop", gone: Bool = false,
                      operation: String = "", remotes: [String] = ["origin"], files: [GitFile] = [], mainProtected: Bool = false) -> GitSnapshot {
    GitSnapshot(root: "/tmp/repo", branch: branch, files: files, commits: [],
                branches: branch == "HEAD" ? [] : [GitBranch(name: branch, current: true, upstream: upstream, ahead: ahead, behind: behind, gone: gone, updated: 0)],
                operation: operation, ahead: ahead, behind: behind, remote: "", mainProtected: mainProtected, primaryBranch: "main",
                remoteBranches: [], remotes: remotes)
}

@Test func theSyncButtonFollowsTheRepositoryState() {
    let now = Date()
    #expect(GitSyncState.of(snapshot(remotes: []), running: nil, lastFetch: nil) == .publishRepository)
    #expect(GitSyncState.of(snapshot(upstream: ""), running: nil, lastFetch: nil) == .publishBranch)
    #expect(GitSyncState.of(snapshot(gone: true), running: nil, lastFetch: nil) == .publishBranch)
    #expect(GitSyncState.of(snapshot(behind: 3), running: nil, lastFetch: nil) == .pull(count: 3, thenPush: 0))
    #expect(GitSyncState.of(snapshot(ahead: 2, behind: 3), running: nil, lastFetch: nil) == .pull(count: 3, thenPush: 2))
    #expect(GitSyncState.of(snapshot(ahead: 2), running: nil, lastFetch: nil) == .push(count: 2))
    #expect(GitSyncState.of(snapshot(), running: nil, lastFetch: now) == .fetch(last: now))
    #expect(GitSyncState.of(snapshot(branch: "HEAD", upstream: ""), running: nil, lastFetch: nil) == .fetch(last: nil))
    #expect(GitSyncState.of(snapshot(ahead: 1, operation: "merge"), running: nil, lastFetch: nil) == .unfinished(operation: "merge"))
    let running = GitOperation(title: "Bajando cambios…", cancellable: true)
    #expect(GitSyncState.of(snapshot(operation: "merge"), running: running, lastFetch: nil) == .running(title: "Bajando cambios…", cancellable: true))
    // Every state has its title, its tooltip and an identifier of its own.
    let states: [GitSyncState] = [.publishRepository, .publishBranch, .pull(count: 3, thenPush: 0), .pull(count: 1, thenPush: 2), .push(count: 2),
                                  .fetch(last: nil), .fetch(last: now), .unfinished(operation: "rebase"), .running(title: "x", cancellable: false)]
    for state in states {
        #expect(!state.title.isEmpty && !state.help.isEmpty && state.identifier.hasPrefix("git.sync."))
    }
    #expect(GitSyncState.pull(count: 3, thenPush: 0).title == "Bajar cambios (3)")
    #expect(GitSyncState.push(count: 2).title == "Subir cambios (2)")
    #expect(Set(states.map(\.identifier)).count == 7)
}

@Test func gitVersionsBelowTheMinimumAreOutdated() {
    #expect(GitRequirement.of(version: "git version 2.39.5 (Apple Git-154)") == .ready(version: "2.39.5 (Apple Git-154)"))
    #expect(GitRequirement.of(version: "git version 2.25.0") == .ready(version: "2.25.0"))
    #expect(GitRequirement.of(version: "git version 3.0") == .ready(version: "3.0"))
    #expect(GitRequirement.of(version: "git version 2.24.3") == .outdated(version: "2.24.3"))
    #expect(GitRequirement.of(version: "git version 1.9.1") == .outdated(version: "1.9.1"))
    #expect(GitRequirement.of(version: "algo raro") == .outdated(version: "algo raro"))
}

@Test func aFileIsIncludedWholeInPartOrNot() {
    let staged = GitFile(path: "a.txt", index: "M", worktree: " ")
    let both = GitFile(path: "b.txt", index: "M", worktree: "M")
    let unstaged = GitFile(path: "c.txt", index: " ", worktree: "M")
    let untracked = GitFile(path: "d.txt", index: "?", worktree: "?")
    let conflict = GitFile(path: "e.txt", index: "U", worktree: "U")
    #expect(staged.inclusion == .full && both.inclusion == .partial && unstaged.inclusion == .none && untracked.inclusion == .none)
    #expect(untracked.kind == .added && untracked.hasUnstaged && !untracked.hasStaged)
    #expect(conflict.conflicted && conflict.kind == .conflict && !conflict.hasStaged && !conflict.hasUnstaged)
    #expect(GitFile(path: "f.txt", index: "A", worktree: "M").newInParts)
    let moved = GitFile(path: "g.txt", originalPath: "old.txt", index: "R", worktree: " ")
    #expect(moved.kind == .moved && moved.inclusion == .full)
}

@Test func gitErrorsReadInPlainWords() {
    let pull = GitFailure(EngineFailure(code: "pull_diverged", messageKey: "git.error.pull_diverged",
                                        detail: "Tu rama y la del remoto tienen commits distintos.\n\nDetalle de Git: fatal: Not possible to fast-forward"))
    #expect(pull.title == L("git.error.pull_diverged") && pull.needsPullAssistant)
    #expect(!pull.detail.contains("fatal"))
    let rejected = GitFailure(EngineFailure(code: "git_failed", messageKey: "git.error.git_failed", detail: " ! [rejected] develop -> develop (fetch first)"))
    #expect(rejected.detail == L("git.message.rejected") && !rejected.needsPullAssistant)
    let unknown = GitFailure(EngineFailure(code: "git_failed", messageKey: "git.error.git_failed", detail: "error: algo que Git dijo"))
    #expect(unknown.detail == "error: algo que Git dijo")
    #expect(GitFailure(EngineFailure(code: "cancelled", messageKey: "git.error.cancelled")).cancelled)
    #expect(GitFailure(CancellationError()).cancelled)
    // Another part of the engine (the tool turned off) keeps its own text.
    #expect(GitFailure(EngineFailure(code: "plugin_disabled", messageKey: "error.plugin_disabled")).title == L("error.plugin_disabled"))
    #expect(!GitFailure(EngineFailure(code: "pull_remote_unreachable", messageKey: "git.error.pull_remote_unreachable")).needsPullAssistant)
}

/// Every code of `engine/src/git` has its title: an error never shows a key.
@Test func everyEngineGitErrorHasItsTitle() throws {
    let engine = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("engine/src/git")
    let files = try #require(FileManager.default.enumerator(at: engine, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL })
    var codes: Set<String> = []
    let pattern = try NSRegularExpression(pattern: #"\berror\(\s*"([a-z_]+)"|\(\s*"(pull_[a-z_]+)""#)
    for file in files where file.pathExtension == "rs" && !file.path.contains("/tests/") {
        let text = try String(contentsOf: file, encoding: .utf8)
        for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            for group in 1...2 where match.range(at: group).location != NSNotFound {
                codes.insert((text as NSString).substring(with: match.range(at: group)))
            }
        }
    }
    #expect(codes.count > 40)
    for code in codes { #expect(localized("git.error.\(code)") != nil, "git.error.\(code)") }
}

/// The texts built at run time: tabs, progress and toasts of each action, and the name of an
/// operation left halfway.
@MainActor @Test func everyGitStateHasItsTexts() {
    for tab in GitTab.allCases { #expect(localized("git.tab.\(tab.rawValue)") != nil) }
    for action in GitAction.allCases {
        #expect(localized("git.progress.\(action.rawValue)") != nil, "git.progress.\(action.rawValue)")
        #expect(localized("git.done.\(action.rawValue)") != nil, "git.done.\(action.rawValue)")
    }
    for operation in ["rebase", "merge", "cherry-pick", "revert"] { #expect(localized("git.operation.\(operation)") != nil) }
    // Only network transfers can be stopped; only what the engine guards needs `confirmed`.
    #expect(GitAction.allCases.filter(\.network) == [.fetch, .pull, .push, .pullMerge, .pullRebase, .pullAutostash])
    #expect(!GitAction.commit.needsConfirmation && GitAction.push.needsConfirmation && GitAction.discard.needsConfirmation)
}

@Test func theWatcherIgnoresGitNoise() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("stack-git-watch-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let watcher = try #require(GitRepositoryWatcher(root: root.path) { _ in })
    let git = watcher.gitDirectories.first { $0.hasSuffix("/.git/") } ?? root.path + "/.git/"
    #expect(watcher.isRelevant(root.path + "/src/a.ts") && !watcher.isGitState(root.path + "/src/a.ts"))
    for inner in ["index", "HEAD", "refs/heads/develop", "packed-refs", "MERGE_HEAD", "rebase-merge/done", "CHERRY_PICK_HEAD"] {
        #expect(watcher.isRelevant(git + inner) && watcher.isGitState(git + inner), "\(inner)")
    }
    for inner in ["objects/ab/cdef", "logs/HEAD", "index.lock", "fsmonitor--daemon/cookies/1"] {
        #expect(!watcher.isRelevant(git + inner), "\(inner)")
    }
    // A linked worktree watches its own Git folder and the shared one.
    let linked = root.appendingPathComponent("linked")
    let own = root.appendingPathComponent(".git/worktrees/linked")
    try FileManager.default.createDirectory(at: linked, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: own, withIntermediateDirectories: true)
    try "gitdir: \(own.path)\n".write(to: linked.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
    try "../..\n".write(to: own.appendingPathComponent("commondir"), atomically: true, encoding: .utf8)
    let directories = GitRepositoryWatcher.gitDirectories(root: linked.path)
    #expect(directories.count == 2 && directories[0].hasSuffix("/.git/worktrees/linked") && directories[1].hasSuffix("/.git"))
}

/// A watcher whose owner lets it go while its callback runs ends on its own queue: it must not
/// wait for itself there (it trapped and closed the whole `swift test` with signal 5).
@Test func aWatcherReleasedFromItsOwnCallbackEnds() async throws {
    final class Holder: @unchecked Sendable {
        let lock = NSLock()
        var watcher: GitRepositoryWatcher?
        var ended = false
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("stack-git-watch-end-\(UUID().uuidString)").resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let holder = Holder()
    holder.watcher = GitRepositoryWatcher(root: root.path, latency: 0.05) { _ in
        holder.lock.lock()
        holder.watcher = nil
        holder.ended = true
        holder.lock.unlock()
    }
    try #require(holder.watcher != nil)
    for _ in 0..<100 {
        try "cambio \(UUID())".write(to: root.appendingPathComponent("archivo.txt"), atomically: true, encoding: .utf8)
        try await Task.sleep(for: .milliseconds(100))
        if holder.lock.withLock({ holder.ended }) { break }
    }
    #expect(holder.lock.withLock { holder.ended && holder.watcher == nil })
}

/// 1.500 changed files: the list the tree and the flat list receive is built in a few
/// milliseconds, and filtering it too.
@MainActor @Test func fifteenHundredChangesStayFluid() {
    let files = (0..<1_500).map { index in
        GitFile(path: "src/modulo\(index % 40)/sub\(index % 7)/archivo\(index).ts", index: index % 3 == 0 ? "M" : " ", worktree: index % 2 == 0 ? "M" : " ")
    }
    var big = snapshot(files: files)
    big.files = files
    let start = CFAbsoluteTimeGetCurrent()
    let repository = GitRepository(snapshot: big, store: StackStore(engine: StackEngine(executable: URL(fileURLWithPath: "/usr/bin/false"))))
    let built = CFAbsoluteTimeGetCurrent() - start
    #expect(repository.changes.count == 1_500)
    let filterStart = CFAbsoluteTimeGetCurrent()
    let filtered = repository.changes.filter { $0.path.localizedCaseInsensitiveContains("modulo7/") }
    let filteredIn = CFAbsoluteTimeGetCurrent() - filterStart
    print("Git 1500 cambios: modelo \(Int(built * 1000)) ms, filtro \(Int(filteredIn * 1000)) ms")
    #expect(!filtered.isEmpty)
    #expect(built < 0.5 && filteredIn < 0.2)
    repository.stopWatching()
}
