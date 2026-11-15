import Foundation

/// What Problemas needs beyond the snapshot, read in the background and kept until the next
/// refresh: whether Git knows who you are (name and email) and which changed files are too big
/// to send to a hosting service.
@MainActor @Observable final class GitProblemChecks {
    /// Weak: a check still running never keeps a closed repository alive.
    @ObservationIgnored private weak var repository: GitRepository?
    @ObservationIgnored private let store: StackStore
    @ObservationIgnored private let root: String
    /// Name or email missing for this repository (its configuration or the global one). Set by
    /// `reload`; settable so tests can show the problem under a configuration that has both.
    var identityMissing = false
    /// Changed files over `largeFileLimit`, by path.
    private(set) var largeFiles: [String] = []

    /// Hosting services refuse files over 100 MB and warn from 50 MB.
    nonisolated static let largeFileLimit: UInt64 = 50 * 1_024 * 1_024

    @ObservationIgnored private var sizesTask: Task<Void, Never>?
    @ObservationIgnored private var sizesKey = ""

    init(repository: GitRepository) {
        self.repository = repository
        store = repository.store
        root = repository.root
        reload()
        reloadSizes()
    }

    /// Reads the identity again (after a refresh of the whole repository).
    func reload() {
        Task { [weak self] in
            guard let self else { return }
            let name = (try? await self.query(["config", "--get", "user.name"]))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let email = (try? await self.query(["config", "--get", "user.email"]))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let missing = name.isEmpty || email.isEmpty
            if missing != self.identityMissing { self.identityMissing = missing }
        }
    }

    private func query(_ arguments: [String]) async throws -> String {
        try await store.call(["method": "gitQuery", "path": root, "args": arguments])
    }

    /// Measures the changed files again when the list changed (off the main thread).
    func reloadSizes() {
        guard let repository else { return }
        let files = repository.files.filter { $0.worktree != "D" && $0.index != "D" }.map(\.path)
        let key = files.joined(separator: "\n")
        guard key != sizesKey else { return }
        sizesKey = key
        sizesTask?.cancel()
        let root = self.root
        sizesTask = Task { [weak self] in
            let found = await Task.detached(priority: .utility) { Self.large(files, root: root) }.value
            guard let self, !Task.isCancelled else { return }
            if found != self.largeFiles { self.largeFiles = found }
        }
    }

    /// The files of `paths` (relative to `root`) bigger than the limit; at most 5.000 are measured.
    nonisolated static func large(_ paths: [String], root: String, limit: UInt64 = largeFileLimit) -> [String] {
        paths.prefix(5_000).filter { path in
            let full = (root as NSString).appendingPathComponent(path)
            let size = (try? FileManager.default.attributesOfItem(atPath: full)[.size] as? NSNumber)?.uint64Value ?? 0
            return size > limit
        }
    }
}
