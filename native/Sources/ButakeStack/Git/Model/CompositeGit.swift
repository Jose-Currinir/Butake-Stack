import Foundation

/// What a project of several parts does at once with its repositories (P-39): ask every remote and
/// bring down what each one has. Committing and sending stay one repository at a time, in the
/// tool: nothing here commits or sends.
@MainActor enum CompositeGit {
    /// «Actualizar todo»: asks each remote for new commits; changes nothing in the folders. The
    /// failure of each repository that could not ask.
    static func fetchAll(_ entries: [GitRepositoryEntry], store: StackStore) async -> [String: GitFailure] {
        var failures: [String: GitFailure] = [:]
        for entry in entries where !entry.missing {
            do {
                let _: String? = try await store.call(["method": "gitAction", "path": entry.path, "action": GitAction.fetch.rawValue, "value": ""])
            } catch {
                failures[entry.path] = GitFailure(error)
            }
        }
        return failures
    }

    /// «Bajar todo» after asking: one repository at a time, only those with something to bring
    /// and no operation left half done; each failure stays with its repository.
    static func pullAll(_ entries: [GitRepositoryEntry], store: StackStore) async -> [String: GitFailure] {
        var failures = await fetchAll(entries, store: store)
        for entry in entries where !entry.missing && failures[entry.path] == nil {
            do {
                let snapshot: GitSnapshot = try await store.call(["method": "gitSnapshot", "path": entry.path, "limit": 1])
                guard snapshot.behind > 0, snapshot.operation.isEmpty else { continue }
                let repository = GitRepository(snapshot: snapshot, store: store)
                if !(await repository.perform(.pull, notify: false)), let failure = repository.pullProblem ?? repository.failure {
                    failures[entry.path] = failure
                }
            } catch {
                failures[entry.path] = GitFailure(error)
            }
        }
        return failures
    }
}
