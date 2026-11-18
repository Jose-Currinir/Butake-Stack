import AppKit
import SwiftUI

/// The open repository: its snapshot, the changed files with their line counts, what is selected
/// and the operation running. Every view of the tool reads it from `GitTool.shared.repository`.
///
/// Reading: `snapshot` (branch, branches, remotes, history, operation in progress), `files` and
/// `changes` (the same files as the change tree wants them). Refreshing: the watcher calls
/// `scheduleRefresh`; after an action `refresh()` reads everything again. Nothing flickers: a
/// value is only replaced when it changed, and the selection is kept by path.
/// Writing: through `perform` (GitRepository+Work.swift), one operation at a time.
@MainActor @Observable final class GitRepository {
    let root: String
    @ObservationIgnored let store: StackStore

    private(set) var snapshot: GitSnapshot
    /// The changed files, observed apart from `snapshot` so a files-only refresh redraws only lists.
    private(set) var files: [GitFile]
    /// `files` with kind, line counts and inclusion, as `GitChangeTreeView` takes them.
    private(set) var changes: [GitChange] = []
    /// Line counts by "path|staged" (`gitStats`, the slowest read: loaded after the list).
    @ObservationIgnored private var stats: [String: GitLineStats] = [:]

    /// The file whose diff is shown, by path (kept across refreshes while the file is changed).
    var selectedFile: String? { didSet { if selectedFile != oldValue { showStaged = false; loadDiff(keepCurrent: false) } } }
    /// For a file with both parts, which one the diff shows.
    var showStaged = false { didSet { if showStaged != oldValue { loadDiff(keepCurrent: false) } } }
    /// The diff on screen; nil while the first one loads.
    private(set) var diff: GitDiffContent?
    /// The raw patch on screen (its block headers go to `gitStageHunk` as `expected`).
    @ObservationIgnored var diffText = ""
    /// The branch selected in Ramas.
    var selectedBranch: String?

    /// The operation running (title for the primary button, «Cancelar» for network transfers).
    var operation: GitOperation? { didSet { if operation == nil { releaseIdleWaiters() } } }
    /// When the remote was last asked (fetch or pull) in this session.
    var lastFetch: Date?
    /// An error to show now (an alert of the Git page).
    var failure: GitFailure?
    /// A pull that needs a decision: the assistant shows it.
    var pullProblem: GitFailure?
    /// The last failed pull or push, kept for «Problemas» (G-3) until the next success.
    var lastSyncFailure: GitFailure?
    /// «¿Subir directo a la rama principal?» is waiting for the user's answer.
    var confirmingPushMain = false
    /// Files waiting for «Descartar cambios» to be confirmed.
    var discarding: [GitFile]?
    /// How many commits of history the snapshot reads (Historial pages it, G-3).
    var historyLimit = 180
    /// Historial: search, selection, pages and the last reorganization (`History/GitHistory.swift`).
    @ObservationIgnored private(set) lazy var history = GitHistory(repository: self)
    /// What Problemas reads beyond the snapshot: identity and big files (`Problems/GitProblemChecks.swift`).
    @ObservationIgnored private(set) lazy var checks = GitProblemChecks(repository: self)

    @ObservationIgnored var watcher: GitRepositoryWatcher?
    /// Stops the network transfer in progress («Cancelar»).
    @ObservationIgnored var stopRunning: (() -> Void)?
    @ObservationIgnored var chain: Task<Void, Never>?
    @ObservationIgnored private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var refreshing = false
    @ObservationIgnored private var queued: Bool?
    @ObservationIgnored private var waiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var scheduled: Task<Void, Never>?
    @ObservationIgnored private var scheduledFull = false
    @ObservationIgnored private var statsTask: Task<Void, Never>?
    @ObservationIgnored private var diffGeneration = 0
    @ObservationIgnored private var lastRefreshFailure: String?

    init(snapshot: GitSnapshot, store: StackStore) {
        root = snapshot.root
        self.store = store
        self.snapshot = snapshot
        files = snapshot.files
        rebuildChanges()
        loadStats()
    }

    // MARK: Reading

    var file: GitFile? { selectedFile.flatMap { path in files.first { $0.path == path } } }
    var stagedFiles: [GitFile] { files.filter(\.hasStaged) }
    var conflicts: [GitFile] { files.filter(\.conflicted) }
    var busy: Bool { operation != nil }
    var syncState: GitSyncState { .of(snapshot, running: operation, lastFetch: lastFetch) }
    /// The title of «Confirmar en ‹rama›».
    var branchTitle: String { snapshot.detached ? L("git.detached") : snapshot.branch }

    func stats(_ file: GitFile) -> GitLineStats {
        let unstaged = stats["\(file.path)|0"], staged = stats["\(file.path)|1"]
        guard unstaged != nil || staged != nil else { return GitLineStats() }
        let additions = (unstaged?.additions ?? 0) + (staged?.additions ?? 0)
        let deletions = (unstaged?.deletions ?? 0) + (staged?.deletions ?? 0)
        if unstaged?.binary == true || staged?.binary == true { return GitLineStats() }
        // A new file in two parts: the net result is every line of the new file.
        if file.newInParts, unstaged != nil, staged != nil { return GitLineStats(additions: max(0, additions - deletions), deletions: 0) }
        return GitLineStats(additions: additions, deletions: deletions)
    }

    private func rebuildChanges() {
        let next = files.map { file in
            GitChange(path: file.path, kind: file.kind, originalPath: file.originalPath, stats: stats(file), inclusion: file.inclusion)
        }
        if next != changes { changes = next }
    }

    /// Returns once no operation is running: a checkbox applied during a pull or a commit would
    /// run a second Git process on the same index.
    func whenIdle() async {
        while operation != nil { await withCheckedContinuation { idleWaiters.append($0) } }
    }

    private func releaseIdleWaiters() {
        let waiting = idleWaiters
        idleWaiters = []
        for waiter in waiting { waiter.resume() }
    }

    // MARK: Refreshing

    /// Starts following the folder (called once the repository is on screen).
    func watch() {
        watcher = GitRepositoryWatcher(root: root) { [weak self] gitState in
            Task { @MainActor in self?.scheduleRefresh(full: gitState) }
        }
    }

    func stopWatching() {
        watcher = nil
        scheduled?.cancel(); scheduled = nil
        statsTask?.cancel()
    }

    /// Bursts of file events (an agent rewriting hundreds of files) become one refresh. Big lists
    /// refresh less often: redrawing thousands of rows has a cost.
    func scheduleRefresh(full: Bool) {
        if full { scheduledFull = true }
        guard scheduled == nil else { return }
        let delay = Duration.milliseconds(max(300, min(2_000, files.count * 2 / 5)))
        scheduled = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            self.scheduled = nil
            let full = self.scheduledFull
            self.scheduledFull = false
            await self.refresh(filesOnly: !full)
        }
    }

    /// Reads the repository again. Calls that arrive meanwhile share one more read afterwards.
    func refresh(filesOnly: Bool = false) async {
        if refreshing {
            queued = (queued ?? true) && filesOnly
            await withCheckedContinuation { waiters.append($0) }
            return
        }
        refreshing = true
        var onlyFiles = filesOnly
        repeat {
            queued = nil
            await refreshOnce(filesOnly: onlyFiles)
            onlyFiles = queued ?? true
        } while queued != nil
        refreshing = false
        let waiting = waiters
        waiters = []
        for waiter in waiting { waiter.resume() }
    }

    private func refreshOnce(filesOnly: Bool) async {
        do {
            if filesOnly {
                let next: [GitFile] = try await store.call(["method": "gitChanges", "path": root])
                apply(files: next)
            } else {
                let next: GitSnapshot = try await store.call(["method": "gitSnapshot", "path": root, "limit": historyLimit])
                if next != snapshot { snapshot = next }
                apply(files: next.files)
                checks.reload()
            }
            checks.reloadSizes()
            lastRefreshFailure = nil
        } catch {
            // A folder that went away fails on every event: say it once.
            let failure = GitFailure(error)
            guard !failure.cancelled else { return }
            if lastRefreshFailure != failure.detail { lastRefreshFailure = failure.detail; self.failure = failure }
        }
    }

    private func apply(files next: [GitFile]) {
        guard next != files else { return }
        files = next
        snapshot.files = next
        rebuildChanges()
        loadStats()
        // The selection stays while its file is still changed; its diff reloads in place.
        if let path = selectedFile {
            if next.contains(where: { $0.path == path }) { loadDiff(keepCurrent: true) } else { selectedFile = nil; diff = nil }
        }
    }

    /// Line counts after the list, at most one read at a time.
    private func loadStats() {
        statsTask?.cancel()
        guard !files.isEmpty else { stats = [:]; return }
        statsTask = Task { [weak self] in
            guard let self else { return }
            guard let entries: [GitFileStat] = try? await self.store.call(["method": "gitStats", "path": self.root]), !Task.isCancelled else { return }
            var next: [String: GitLineStats] = [:]
            next.reserveCapacity(entries.count)
            for entry in entries { next["\(entry.path)|\(entry.staged ? 1 : 0)"] = GitLineStats(additions: entry.additions, deletions: entry.deletions) }
            self.stats = next
            self.rebuildChanges()
        }
    }

    // MARK: Diff

    /// Whether the diff on screen is the staged part.
    var diffIsStaged: Bool {
        guard let file else { return false }
        return file.hasStaged && (showStaged || !file.hasUnstaged)
    }

    /// Loads the selected file's diff. With `keepCurrent` the old one stays until the new one
    /// arrives (a refresh); otherwise it clears only if the new one is slow (no blank flash).
    func loadDiff(keepCurrent: Bool) {
        diffGeneration += 1
        let generation = diffGeneration
        guard let file else { diff = nil; diffText = ""; return }
        let staged = diffIsStaged
        if !keepCurrent {
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(150))
                if let self, self.diffGeneration == generation, !keepCurrent { self.diff = nil }
            }
        }
        var request: [String: Any] = ["method": "gitDiff", "path": root, "file": file.path, "staged": staged]
        if file.newInParts && !staged { request["whole"] = true }
        Task { [weak self] in
            guard let self else { return }
            do {
                let text: String = try await self.store.call(request)
                guard generation == self.diffGeneration else { return }
                self.diffGeneration += 1
                let current = self.diffGeneration
                self.diffText = text
                // Reading an image can be slow: off the main actor.
                let root = self.root
                let content = await Task.detached { Self.content(text, file: file, root: root) }.value
                guard current == self.diffGeneration else { return }
                if content != self.diff { self.diff = content }
            } catch {
                guard generation == self.diffGeneration else { return }
                let failure = GitFailure(error)
                if !failure.cancelled { self.diff = .failed(failure) }
            }
        }
    }

    /// What the diff view draws for the engine's answer.
    nonisolated static func content(_ text: String, file: GitFile, root: String) -> GitDiffContent {
        if file.untracked {
            if text == "[Archivo binario]" {
                // The image must be inside the repository (a link out of it is not followed).
                let rootURL = URL(fileURLWithPath: root).resolvingSymlinksInPath()
                let url = rootURL.appendingPathComponent(file.path).resolvingSymlinksInPath()
                if url.path.hasPrefix(rootURL.path + "/"), let image = NSImage(contentsOf: url), image.isValid {
                    return .image(before: nil, after: image)
                }
                return .binary
            }
            if text.hasPrefix("[Archivo mayor a 1 MB") { return .tooLarge(lines: nil) }
        }
        if text.hasPrefix("Binary files ") || (text.contains("\nBinary files ") && !text.contains("\n@@ ")) { return .binary }
        return text.isEmpty ? .unchanged : .patch(text)
    }

    /// The header of block `index` of the diff on screen (`@@ … @@`).
    func hunkHeader(_ index: Int) -> String? {
        let headers = diffText.split(separator: "\n", omittingEmptySubsequences: false).filter { $0.hasPrefix("@@ ") }
        return headers.indices.contains(index) ? String(headers[index]) : nil
    }
}
