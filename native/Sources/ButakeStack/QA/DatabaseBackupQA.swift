#if DEBUG
import AppKit

/// The databases of «Exportar configuración» without its panels, against a QA store
/// (BUTAKE_QA_DB_BACKUP=<folder>: dump every database there and list them in qa-entries.json;
/// BUTAKE_QA_DB_LOAD=<folder>: load the ones listed there and write qa-loaded.txt). Quits when done.
extension QAHooks {
    /// These runs never read the Keychain (no password: a throwaway server).
    static var databaseBackupWithoutVault: Bool {
        let env = ProcessInfo.processInfo.environment
        return StackStore.qaWindow && (env["BUTAKE_QA_DB_BACKUP"] != nil || env["BUTAKE_QA_DB_LOAD"] != nil)
    }

    static func databaseBackup(dump: String?, load: String?) {
        Task {
            try? await Task.sleep(for: .seconds(2))
            let store = StackStore.shared
            if let dump {
                let folder = URL(fileURLWithPath: dump)
                do {
                    let entries = try await store.backupDatabases(into: folder)
                    try JSONEncoder().encode(entries).write(to: folder.appendingPathComponent("qa-entries.json"))
                } catch {
                    try? "ERROR \(error.localizedDescription)".write(to: folder.appendingPathComponent("qa-entries.json"), atomically: true, encoding: .utf8)
                }
            }
            if let load {
                let folder = URL(fileURLWithPath: load)
                let entries = (try? JSONDecoder().decode([DatabaseBackupEntry].self, from: Data(contentsOf: folder.appendingPathComponent("qa-entries.json")))) ?? []
                var lines: [String] = []
                for entry in entries {
                    lines.append("\(entry.id) \(await store.restoreDatabase(entry, from: folder))")
                }
                try? lines.joined(separator: "\n").write(to: folder.appendingPathComponent("qa-loaded.txt"), atomically: true, encoding: .utf8)
            }
            NSApp.terminate(nil)
        }
    }
}
#endif
