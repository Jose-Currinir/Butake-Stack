import Foundation

/// The engine methods that are not a `gitAction` (copy commits, reorganize, resolve a conflict)
/// with the same rules as `perform`: one at a time, progress in the primary button, a refresh
/// afterwards and the error translated. Reads (`gitQuery`) go straight to the engine.
extension GitRepository {
    /// Runs `request` (its `path` is this repository) and refreshes. The caller decides what to do
    /// with a failure (`report` shows it as an alert).
    func run<T: Decodable & Sendable>(_ title: String, _ request: [String: Any], done: String? = nil,
                                       as type: T.Type = T.self) async -> Result<T, GitFailure> {
        guard operation == nil else { return .failure(GitFailure(code: "operation_in_progress", title: L("git.error.operation_in_progress"), detail: "")) }
        await chain?.value
        let current = GitOperation(title: title, cancellable: false)
        operation = current
        defer { if operation?.id == current.id { operation = nil } }
        var full = request
        full["path"] = root
        let result: Result<T, GitFailure>
        do { result = .success(try await store.call(full)) } catch { result = .failure(GitFailure(error)) }
        await refresh()
        if case .success = result, let done { store.notify(done) }
        return result
    }

    /// Shows a failure of `run` as the page's alert (a stop asked by the user says nothing).
    func report(_ failure: GitFailure) {
        if !failure.cancelled { self.failure = failure }
    }

    /// A read-only Git query of the engine's list (`log`, `show`, `grep`, `stash list`…).
    func query(_ arguments: [String]) async throws -> String {
        try await store.call(["method": "gitQuery", "path": root, "args": arguments])
    }
}

/// A failure travels in the `Result` of `run`.
extension GitFailure: Error {}
