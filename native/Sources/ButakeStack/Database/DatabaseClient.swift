import AppKit
import Foundation

/// A change the engine wants confirmed before it runs: what will run, where, and (for the worst
/// cases) a name the user must type again.
struct PendingConfirmation: Identifiable {
    let id = UUID()
    let title: String
    let statements: [String]
    var typedName: String?
    /// A production connection: its name must be typed too, whatever the change.
    var typedConnection: String?
    var destructive = true
    let resume: (Bool, String) -> Void
    /// What was typed for the connection's name (read by `ask` once the sheet answers).
    final class Typed: @unchecked Sendable { var connection = "" }
    var typed = Typed()
}

/// State of the database client: connections, the side tree, the selection and every request to
/// the engine (with the connection's password from the Keychain and the confirmation round trip).
@MainActor @Observable final class DatabaseClient {
    static let shared = DatabaseClient()
    let store = StackStore.shared

    var connections: [DBConnection] = []
    var databases: [String: [DBDatabase]] = [:]
    var objects: [String: [DBObject]] = [:]
    /// Schemas read for completion and the diagram, by "<connection>/<database>".
    var schemas: [String: DBSchema] = [:]
    /// Databases with a manual transaction open, by "<connection>/<database>".
    var transactions: Set<String> = []
    var expanded: Set<String> = []
    /// Selecting from a panel opens the matching branches of the tree.
    var selection: DBSelection? {
        didSet {
            guard let selection, let connection = connection(selection.connection), status[connection.id] != .disconnected else { return }
            if !expanded.contains(connection.id) {
                expanded.insert(connection.id)
                if databases[connection.id] == nil { Task { await loadDatabases(connection) } }
            }
            if let database = selection.database, connection.isSQL, selection.table != nil || oldValue?.database != database {
                let key = "\(connection.id)/\(database)"
                if !expanded.contains(key) {
                    expanded.insert(key)
                    if objects[key] == nil { Task { await loadObjects(connection, database) } }
                }
            }
        }
    }
    /// Unsaved table edits by `pendingKey` (they outlive the page that made them).
    var pendingEdits: [String: PendingEdits] = [:]
    var loading: Set<String> = []
    var errors: [String: DBProblem] = [:]
    /// Whether each connection answers (checked when it is opened).
    var status: [String: ConnectionState] = [:]
    enum ConnectionState: Equatable { case checking, ok(String), failed(DBProblem), disconnected }
    /// When each connection was last used (idle ones are disconnected after a while).
    private var lastUsed: [String: Date] = [:]
    private var idleWatch: Task<Void, Never>?
    static let idleLimit: TimeInterval = 15 * 60

    func isConnected(_ id: String) -> Bool { if case .ok = status[id] { return true } else { return false } }

    /// Closes the connection's tunnel and session and forgets what was loaded; passwords stay in
    /// the Keychain. The connection stays disconnected until the user connects again.
    func disconnect(_ connection: DBConnection) async {
        guard await confirmDiscardPending(connection: connection) else { return }
        discardPending(connection: connection.id)
        let _: Bool? = try? await store.call(["method": "dbDisconnect", "connection": connection.id])
        // Closing the sessions rolls back an open manual transaction.
        transactions = transactions.filter { !$0.hasPrefix("\(connection.id)/") }
        for key in schemas.keys where key.hasPrefix("\(connection.id)/") { schemas[key] = nil }
        status[connection.id] = .disconnected
        lastUsed[connection.id] = nil
        DatabaseVault.forget(connection.id)
        databases[connection.id] = nil
        errors[connection.id] = nil
        for key in objects.keys where key.hasPrefix("\(connection.id)/") { objects[key] = nil }
        expanded = expanded.filter { $0 != connection.id && !$0.hasPrefix("\(connection.id)/") }
        if let selection, selection.connection == connection.id { self.selection = DBSelection(connection: connection.id) }
    }

    func connect(_ connection: DBConnection) async {
        status[connection.id] = .checking
        await check(connection)
        if isConnected(connection.id) { await loadDatabases(connection) }
    }

    /// Every few minutes: connections unused for `idleLimit` are disconnected (tunnels and sessions
    /// would otherwise stay open on the server).
    func watchIdle() {
        guard idleWatch == nil else { return }
        idleWatch = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard let self else { return }
                let now = Date()
                for connection in self.connections where self.isConnected(connection.id) && !connection.builtin && self.pendingCount(connection: connection.id) == 0 {
                    if let used = self.lastUsed[connection.id], now.timeIntervalSince(used) > Self.idleLimit {
                        await self.disconnect(connection)
                    }
                }
            }
        }
    }

    /// On quit: closes every tunnel and session synchronously (the app is about to exit).
    nonisolated static func disconnectAllNow() {
        let process = Process()
        process.executableURL = StackEngine.executable
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return }
        try? input.fileHandleForWriting.write(contentsOf: Data(#"{"method":"dbDisconnectAll"}"#.utf8))
        try? input.fileHandleForWriting.close()
        let deadline = Date().addingTimeInterval(3)
        while process.isRunning && Date() < deadline { usleep(20_000) }
        if process.isRunning { process.terminate() }
    }
    var pending: PendingConfirmation?
    var editing: DBConnection?
    var hostCheck: HostCheck?
    /// Long runs (dump, restore, import) with their progress file.
    var progress: Progress?

    struct HostCheck: Identifiable {
        let id = UUID()
        let connection: DBConnection
        let fingerprints: [String]
    }
    struct Progress {
        let title: String
        let token: String
        var done: Int = 0
        var total: Int = 0
        /// "bytes" (dump, restore) or "rows" (export, CSV import).
        var unit = "bytes"
    }

    var connection: DBConnection? { selection.flatMap { s in connections.first { $0.id == s.connection } } }
    func connection(_ id: String) -> DBConnection? { connections.first { $0.id == id } }

    // MARK: Requests

    private func request(_ method: String, _ connection: DBConnection?, _ extra: [String: Any]) async -> [String: Any] {
        var payload = extra
        payload["method"] = method
        if let connection {
            lastUsed[connection.id] = Date()
            payload["connection"] = connection.id
            if let password = await DatabaseVault.password(connection.id) { payload["password"] = password }
        }
        return payload
    }

    /// A read: errors land next to what failed (the tree, a tab) instead of a global alert.
    func read<T: Decodable & Sendable>(_ method: String, _ connection: DBConnection?, _ extra: [String: Any] = [:], as: T.Type = T.self) async throws -> T {
        do {
            return try await store.call(await request(method, connection, extra))
        } catch let failure as EngineFailure where failure.code == "ssh_host_unknown" {
            if let connection, let ssh = connection.ssh { await checkHost(connection, ssh) }
            throw failure
        }
    }

    /// A change: the first answer may ask for confirmation; the request runs again only if the
    /// user accepts. Returns nil when cancelled or failed (the failure is reported).
    @discardableResult
    func change<T: Decodable & Sendable>(_ method: String, _ connection: DBConnection?, _ extra: [String: Any], title: String, typedName: String? = nil, as: T.Type = T.self) async -> T? {
        do {
            let first: Confirmable<T> = try await store.call(await request(method, connection, extra))
            switch first {
            case .done(let value): return value
            case .confirm(let statements):
                let production = connection?.production == true ? connection?.name : nil
                let (accepted, typed, typedConnection) = await askTyped(title, statements, typedName: typedName, typedConnection: production)
                guard accepted else { return nil }
                var again = extra
                again["confirmed"] = true
                if typedName != nil { again["typedName"] = typed }
                if production != nil { again["typedConnection"] = typedConnection }
                let second: Confirmable<T> = try await store.call(await request(method, connection, again))
                if case .done(let value) = second { return value }
                return nil
            }
        } catch {
            store.report(error)
            return nil
        }
    }

    // MARK: Connections and the tree

    func loadConnections() async {
        do {
            var list: [DBConnection] = try await store.call(["method": "dbConnections"])
            for i in list.indices { list[i].hasPassword = DatabaseVault.has(list[i].id) }
            connections = list
            #if DEBUG
            if selection == nil, let qa = QAHooks.databaseSelection() {
                if qa.disconnected { status[qa.selection.connection] = .disconnected }
                selection = qa.selection
            }
            #endif
            if selection == nil, let first = list.first { selection = DBSelection(connection: first.id) }
        } catch { store.report(error) }
    }

    /// Asks the server for its version: the detail shows the panels only when it answers.
    func check(_ connection: DBConnection) async {
        if status[connection.id] == nil { status[connection.id] = .checking }
        struct Version: Decodable { let version: String }
        do {
            let value: Version = try await read("dbTest", connection)
            // "PostgreSQL 18.7 on aarch64-apple-darwin…" → "PostgreSQL 18.7".
            let short = value.version.components(separatedBy: " on ").first?.components(separatedBy: " (").first ?? value.version
            status[connection.id] = .ok(short)
        } catch {
            status[connection.id] = .failed(DBProblem.connecting(error, to: connection))
        }
    }

    func toggle(_ key: String, load: @escaping () async -> Void) {
        if expanded.contains(key) { expanded.remove(key) } else { expanded.insert(key); Task { await load() } }
    }

    func loadDatabases(_ connection: DBConnection) async {
        let key = connection.id
        loading.insert(key); defer { loading.remove(key) }
        if connection.isRedis {
            do {
                let keys: RedisKeys = try await read("dbRedisKeys", connection, ["pattern": "*"])
                let list = keys.databases.isEmpty ? [RedisKeys.Database(index: 0, keys: 0)] : keys.databases
                databases[key] = list.map { DBDatabase(name: String($0.index), size: nil, tables: $0.keys, system: false) }
                errors[key] = nil
            } catch { errors[key] = DBProblem.connecting(error, to: connection) }
            return
        }
        do {
            databases[key] = try await read("dbDatabases", connection)
            errors[key] = nil
        } catch { errors[key] = DBProblem.connecting(error, to: connection) }
    }

    func loadObjects(_ connection: DBConnection, _ database: String) async {
        let key = "\(connection.id)/\(database)"
        loading.insert(key); defer { loading.remove(key) }
        do {
            objects[key] = try await read("dbObjects", connection, ["database": database])
            errors[key] = nil
        } catch { errors[key] = DBProblem.from(error) }
    }

    /// Bumped by Recargar: every panel on screen loads its own data again.
    var reloads = 0
    /// SQL the editor opens in a tab of its own («Abrir en SQL» from a table).
    var pendingSQL: String?

    /// Recargar (⌘R): the tree of the connection and the panel on screen.
    func reload(_ connection: DBConnection) async {
        reloads += 1
        guard isConnected(connection.id) else { return }
        await refresh(connection)
    }

    func refresh(_ connection: DBConnection) async {
        await loadDatabases(connection)
        for key in expanded where key.hasPrefix("\(connection.id)/") {
            await loadObjects(connection, String(key.dropFirst(connection.id.count + 1)))
        }
    }

    func newConnection() {
        editing = DBConnection(id: "", name: "", kind: "mysql", host: "127.0.0.1", port: 3306, user: "root")
    }

    func save(_ connection: DBConnection, password: String?) async -> Bool {
        do {
            let saved: DBConnection = try await store.call(["method": "dbSaveConnection", "connection": try JSONSerialization.jsonObject(with: JSONEncoder().encode(connection))])
            if let password {
                let kept = password.isEmpty ? DatabaseVault.delete(saved.id) : DatabaseVault.set(password, for: saved.id, label: saved.name)
                // The connection is saved; the password is not, so the editor says so instead of closing as if all went well.
                if !kept {
                    await loadConnections()
                    store.notify(L("db.keychainSaveFailed"))
                    return false
                }
            }
            databases[saved.id] = nil
            status[saved.id] = nil
            await loadConnections()
            selection = DBSelection(connection: saved.id)
            return true
        } catch {
            store.report(error)
            return false
        }
    }

    func delete(_ connection: DBConnection) async {
        guard await confirmSimple(String(format: L("db.deleteConnectionConfirm"), connection.name)) else { return }
        do {
            let _: Bool = try await store.call(["method": "dbDeleteConnection", "connection": connection.id])
            DatabaseVault.deleteAll(connection: connection.id)
            discardPending(connection: connection.id)
            if selection?.connection == connection.id { selection = nil }
            await loadConnections()
        } catch { store.report(error) }
    }

    /// A confirmation without statements (app-only actions).
    func confirmSimple(_ title: String) async -> Bool {
        await ask(title, []).0
    }

    /// Shows the confirmation sheet and waits for the answer (answered once, however the sheet closes).
    func ask(_ title: String, _ statements: [String], typedName: String? = nil) async -> (Bool, String) {
        let (ok, typed, _) = await askTyped(title, statements, typedName: typedName, typedConnection: nil)
        return (ok, typed)
    }

    /// The confirmation, also asking for a production connection's name when there is one.
    func askTyped(_ title: String, _ statements: [String], typedName: String?, typedConnection: String?) async -> (Bool, String, String) {
        guard pending == nil else {
            store.notify(L("db.confirm.busy"))
            return (false, "", "")
        }
        final class Once: @unchecked Sendable { var done = false }
        let once = Once()
        let typed = PendingConfirmation.Typed()
        let answer = await withCheckedContinuation { (continuation: CheckedContinuation<(Bool, String), Never>) in
            var request = PendingConfirmation(title: title, statements: statements, typedName: typedName, typedConnection: typedConnection) { ok, value in
                guard !once.done else { return }
                once.done = true
                continuation.resume(returning: (ok, value))
            }
            request.typed = typed
            pending = request
        }
        pending = nil
        return (answer.0, answer.1, typed.connection)
    }

    /// Asks only for a production connection's name (actions that are not one engine request, such
    /// as COMMIT). True right away elsewhere.
    func confirmProduction(_ connection: DBConnection, _ title: String) async -> Bool {
        guard connection.production else { return true }
        let (ok, _, typed) = await askTyped(title, [], typedName: nil, typedConnection: connection.name)
        return ok && typed == connection.name
    }

    /// An unknown SSH host: show the fingerprints so the user can compare them with the server's.
    func checkHost(_ connection: DBConnection, _ ssh: DBConnection.SSH) async {
        guard let prints: [String] = try? await store.call(["method": "dbSshFingerprints", "host": ssh.host, "port": ssh.port]) else { return }
        hostCheck = HostCheck(connection: connection, fingerprints: prints)
    }

    func trust(_ check: HostCheck) async {
        guard let ssh = check.connection.ssh else { return }
        do {
            let _: Bool = try await store.call(["method": "dbSshTrust", "host": ssh.host, "port": ssh.port, "fingerprints": check.fingerprints, "confirmed": true])
            hostCheck = nil
            await loadDatabases(check.connection)
        } catch { store.report(error) }
    }

    func openTerminal(_ connection: DBConnection, database: String? = nil) async {
        do {
            let _: Bool = try await read("dbTerminal", connection, ["database": database ?? ""])
        } catch { store.report(error) }
    }

    func copyURL(_ connection: DBConnection, database: String? = nil) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(connection.url(database: database), forType: .string)
        store.notify(L("db.urlCopied"))
    }
}
