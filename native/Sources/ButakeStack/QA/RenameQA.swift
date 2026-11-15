#if DEBUG
import Foundation

/// QA of renaming a project (P-41), only in a QA window with its own data folder:
/// - `BUTAKE_QA_RENAME=<id>[><nuevo>]` opens the rename sheet as `butakestack://project/rename` does;
/// - `BUTAKE_QA_RENAME_RUN=1` then renames as the sheet's button does, without clicks;
/// - `BUTAKE_QA_RENAME_REPORT=<archivo>` writes the Keychain accounts afterwards (never values).
/// The Keychain is a memory store with one invented item for the project: the real one is never used.
@MainActor enum RenameQA {
    private static var environment: [String: String] { ProcessInfo.processInfo.environment }
    private static var target: (from: String, to: String?)? {
        guard StackStore.qaWindow, environment["BUTAKE_STACK_HOME"] != nil, let value = environment["BUTAKE_QA_RENAME"] else { return nil }
        let parts = value.split(separator: ">").map(String.init)
        return (parts[0], parts.count > 1 ? parts[1] : nil)
    }

    static var secrets: EnvSecrets? {
        let environment = ProcessInfo.processInfo.environment
        return StackStore.qaWindow && environment["BUTAKE_STACK_HOME"] != nil && environment["BUTAKE_QA_RENAME"] != nil ? memory : nil
    }
    private static let items = MemoryKeychainItems()
    private static let memory = EnvSecrets(items: items)

    static func start() {
        guard let target else { return }
        try? memory.update(site: target.from, env: "local", set: ["TOKEN_QA": "valor-inventado"], remove: [])
        Task {
            try? await Task.sleep(for: .seconds(3))
            let store = StackStore.shared
            var link = URLComponents(string: "butakestack://project/rename")!
            link.queryItems = [URLQueryItem(name: "id", value: target.from)] + (target.to.map { [URLQueryItem(name: "newId", value: $0)] } ?? [])
            if let url = link.url { store.handle(url) }
            guard environment["BUTAKE_QA_RENAME_RUN"] != nil, let project = store.projects.first(where: { $0.id == target.from }), let to = target.to else { return }
            try? await Task.sleep(for: .seconds(1.5))
            store.renaming = nil
            await store.renameProject(project, to: to, name: project.name, domain: true)
            if let path = environment["BUTAKE_QA_RENAME_REPORT"] {
                try? (items.accounts.sorted().joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
            }
        }
    }
}
#endif
