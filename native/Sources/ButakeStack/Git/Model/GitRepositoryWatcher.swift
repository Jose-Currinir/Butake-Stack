import CoreServices
import Foundation

/// Watches a working tree with FSEvents so edits made by editors or agents show up by themselves.
/// The engine does not watch: a change inside the Git folder (index, HEAD, refs, operations) asks
/// for a whole snapshot, a change of a working file only for the list of changes. Objects, logs,
/// lock files and the file system monitor are noise. Linked worktrees (`.git` is a file with
/// `gitdir:`) watch their own Git folder and the shared one (`commondir`).
final class GitRepositoryWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    /// `true` when Git's state changed; `false` for working files only.
    private let onChange: @Sendable (Bool) -> Void
    /// Git folders whose state matters, with a trailing "/", as given and with links resolved.
    let gitDirectories: [String]
    /// Serial: callbacks never overlap, and `deinit` waits for the one in flight.
    private let queue = DispatchQueue(label: "cl.butake.stack.git.watcher", qos: .utility)
    /// Marks `queue`, so `deinit` knows when it runs on it.
    private let onQueue = DispatchSpecificKey<Void>()

    init?(root: String, latency: CFTimeInterval = 0.25, onChange: @escaping @Sendable (Bool) -> Void) {
        self.onChange = onChange
        let directories = Self.gitDirectories(root: root)
        var prefixes: [String] = []
        for directory in directories {
            for path in [URL(fileURLWithPath: directory).resolvingSymlinksInPath().path, directory] where !prefixes.contains(path + "/") {
                prefixes.append(path + "/")
            }
        }
        gitDirectories = prefixes
        var context = FSEventStreamContext(version: 0, info: nil, retain: nil, release: nil, copyDescription: nil)
        context.info = Unmanaged.passUnretained(self).toOpaque()
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<GitRepositoryWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            let relevant = list.prefix(count).filter(watcher.isRelevant)
            if !relevant.isEmpty { watcher.onChange(relevant.contains(where: watcher.isGitState)) }
        }
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        let watched = [root] + directories.filter { !$0.hasPrefix(root + "/") }
        guard let stream = FSEventStreamCreate(nil, callback, &context, watched as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags) else { return nil }
        self.stream = stream
        queue.setSpecific(key: onQueue, value: ())
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    /// The Git folders of `root`: `.git`, or for a linked worktree its own folder and the shared one.
    static func gitDirectories(root: String) -> [String] {
        let dotGit = (root as NSString).appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGit, isDirectory: &isDirectory), !isDirectory.boolValue,
              let text = try? String(contentsOfFile: dotGit, encoding: .utf8),
              let line = text.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") }) else { return [dotGit] }
        let value = line.dropFirst(7).trimmingCharacters(in: .whitespaces)
        let gitDir = URL(fileURLWithPath: value, relativeTo: URL(fileURLWithPath: root, isDirectory: true)).standardizedFileURL.path
        var directories = [gitDir]
        if let common = try? String(contentsOfFile: (gitDir as NSString).appendingPathComponent("commondir"), encoding: .utf8) {
            directories.append(URL(fileURLWithPath: common.trimmingCharacters(in: .whitespacesAndNewlines),
                                   relativeTo: URL(fileURLWithPath: gitDir, isDirectory: true)).standardizedFileURL.path)
        }
        return directories
    }

    /// The path inside a watched Git folder, relative to it.
    private func gitRelative(_ path: String) -> String? {
        for directory in gitDirectories where path.hasPrefix(directory) { return String(path.dropFirst(directory.count)) }
        return nil
    }

    /// Working files always count; inside a Git folder only what changes the screen.
    func isRelevant(_ path: String) -> Bool {
        guard let inner = gitRelative(path) else { return true }
        if inner.hasSuffix(".lock") || inner.hasPrefix("objects/") || inner.hasPrefix("logs/") || inner.hasPrefix("fsmonitor") { return false }
        return inner == "index" || inner == "HEAD" || inner.hasPrefix("refs/") || inner == "packed-refs"
            || inner.hasPrefix("MERGE_") || inner.hasPrefix("rebase-") || inner == "CHERRY_PICK_HEAD" || inner == "REVERT_HEAD"
    }

    /// Inside a Git folder: it can move branches, history or operations.
    func isGitState(_ path: String) -> Bool { gitRelative(path) != nil }

    deinit {
        if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) }
        // Invalidation does not wait for a callback already running with an unretained `self`. When
        // that callback held the last reference (its owner let the watcher go meanwhile), `deinit`
        // runs on the queue itself at the callback's end: waiting there would never return (the
        // `swift test` that ended with signal 5), and nothing is in flight to wait for.
        if DispatchQueue.getSpecific(key: onQueue) == nil { queue.sync {} }
    }
}
