import AppKit
import Foundation
import UniformTypeIdentifiers

/// The work done on an open connection: long runs with progress, the SQL history, query tabs,
/// the schema for completion and the diagram, manual transactions and exports.
extension DatabaseClient {
    // MARK: Long runs

    /// Runs a dump, restore or import while polling its progress file.
    func longRun<T: Decodable & Sendable>(_ title: String, _ method: String, _ connection: DBConnection, _ extra: [String: Any], confirm: Bool, as: T.Type = T.self) async -> T? {
        let token = UUID().uuidString.lowercased()
        var payload = extra
        payload["progress"] = token
        progress = Progress(title: title, token: token)
        let path = Self.progressFile(token)
        let poll = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(400))
                if let data = try? Data(contentsOf: path),
                   let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    progress?.done = value["done"] as? Int ?? 0
                    progress?.total = value["total"] as? Int ?? 0
                    progress?.unit = value["unit"] as? String ?? "bytes"
                }
            }
        }
        defer { poll.cancel(); progress = nil }
        if confirm { return await change(method, connection, payload, title: title) }
        do { return try await read(method, connection, payload) } catch { store.report(error); return nil }
    }

    /// A file that can be restored: a SQL script, plain or gzipped.
    nonisolated static func isSQLDump(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        return name.hasSuffix(".sql") || name.hasSuffix(".sql.gz")
    }

    /// Restores `url` into `database`. The engine asks first, and says which database it replaces.
    func restore(_ url: URL, into database: String, of connection: DBConnection, create: Bool = false) async {
        let request: [String: Any] = ["database": database, "path": url.path, "create": create]
        struct Restored: Decodable { let bytes: Int }
        if let _: Restored = await longRun(String(format: L("db.confirm.restore"), url.lastPathComponent, database, connection.title), "dbRestore", connection, request, confirm: true) {
            store.notify(L("db.restored"))
            await refresh(connection)
        }
    }

    /// «Restaurar un archivo…» from a database's menu: the file is chosen first.
    func chooseAndRestore(into database: String, of connection: DBConnection) async {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "sql") ?? .plainText, .gzip, .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        await restore(url, into: database, of: connection)
    }

    static func progressFile(_ token: String) -> URL {
        Folder.baseURL.appendingPathComponent("run/progress-\(token).json")
    }

    // MARK: SQL history (per connection and database, newest first, in a private file of the store;
    // the engine never keeps statements that carry a password)

    func history(_ connection: DBConnection, database: String) async -> [String] {
        (try? await store.call(["method": "dbHistory", "connection": connection.id, "database": database])) ?? []
    }
    func remember(_ sql: String, in connection: DBConnection, database: String) async {
        let _: Bool? = try? await store.call(["method": "dbHistoryAdd", "connection": connection.id, "database": database, "sql": sql])
    }
    func clearHistory(_ connection: DBConnection, database: String) async {
        let _: Bool? = try? await store.call(["method": "dbHistoryClear", "connection": connection.id, "database": database])
    }

    /// Earlier versions kept the history in UserDefaults ("db.history.<connection>/<database>"):
    /// it moves once to the store (through the same filter) and leaves the defaults.
    func migrateHistory() async {
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("db.history.") {
            let rest = String(key.dropFirst("db.history.".count))
            let parts = rest.split(separator: "/", maxSplits: 1).map(String.init)
            if let connection = parts.first, let list = defaults.stringArray(forKey: key) {
                for sql in list.reversed() {
                    let _: Bool? = try? await store.call(["method": "dbHistoryAdd", "connection": connection, "database": parts[safe: 1] ?? "", "sql": sql])
                }
            }
            defaults.removeObject(forKey: key)
        }
    }

    // MARK: Query tabs (per connection, kept by the engine)

    func queryTabs(_ connection: DBConnection) async -> [QueryTab] {
        (try? await store.call(["method": "dbQueryTabs", "connection": connection.id])) ?? []
    }
    func saveQueryTabs(_ tabs: [QueryTab], for connection: DBConnection) async {
        let encoded = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(tabs))) ?? []
        let _: [QueryTab]? = try? await store.call(["method": "dbSaveQueryTabs", "connection": connection.id, "tabs": encoded])
    }

    // MARK: Schema (completion and the diagram)

    func schema(_ connection: DBConnection, _ database: String, reload: Bool = false) async -> DBSchema? {
        let key = "\(connection.id)/\(database)"
        if !reload, let cached = schemas[key] { return cached }
        guard connection.isSQL, let value: DBSchema = try? await read("dbSchema", connection, ["database": database]) else { return nil }
        schemas[key] = value
        return value
    }

    // MARK: Manual transactions (per connection and database)

    func inTransaction(_ connection: DBConnection, _ database: String) -> Bool { transactions.contains("\(connection.id)/\(database)") }

    func beginTransaction(_ connection: DBConnection, _ database: String) async {
        do {
            let _: Bool = try await read("dbTxBegin", connection, ["database": database])
            transactions.insert("\(connection.id)/\(database)")
        } catch { store.report(error) }
    }

    /// COMMIT (asks for a production connection's name) or ROLLBACK. Either way the mode ends.
    @discardableResult
    func endTransaction(_ connection: DBConnection, _ database: String, commit: Bool) async -> Bool {
        if commit, !(await confirmProduction(connection, String(format: L("db.tx.confirmCommit"), connection.title))) { return false }
        defer { transactions.remove("\(connection.id)/\(database)") }
        do {
            let _: DBRunOutput = try await read(commit ? "dbTxCommit" : "dbTxRollback", connection, ["database": database])
            store.notify(L(commit ? "db.tx.committed" : "db.tx.rolledBack"))
            return true
        } catch {
            store.report(error)
            return false
        }
    }

    // MARK: Export

    /// Asks where to save and streams the rows there (CSV, JSON or SQL INSERTs).
    func export(_ connection: DBConnection, format: String, suggested: String, _ extra: [String: Any]) async {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(suggested).\(format)"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var request = extra
        request["format"] = format
        request["path"] = url.path
        struct Exported: Decodable { let rows: Int; let size: Int }
        if let done: Exported = await longRun(String(format: L("db.export.running"), url.lastPathComponent), "dbExport", connection, request, confirm: false) {
            store.notify(String(format: L("db.export.done"), done.rows, Format.fileSizeText(done.size)))
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
}
