import Foundation

/// One database of Stack's own MySQL, MariaDB or PostgreSQL saved with «Exportar configuración»:
/// a gzip dump in `bases/<engine>/<database>.sql.gz`, next to the configuration file that lists it.
struct DatabaseBackupEntry: Codable, Sendable, Hashable, Identifiable {
    let engine: String
    let database: String
    /// Relative to the folder of the configuration file.
    let file: String
    let size: Int64?
    /// Views that no longer worked and were left out (`database.view`).
    var skippedViews: [String]? = nil
    var id: String { "\(engine)/\(database)" }
}

enum DatabaseBackupError: LocalizedError {
    case stopped(String, detail: String? = nil), failed(String, detail: String? = nil)
    var errorDescription: String? {
        let text: String, detail: String?
        switch self {
        case .stopped(let engine, let reason): (text, detail) = (String(format: L("backup.engineStopped"), Tech.of(engine).title), reason)
        case .failed(let database, let reason): (text, detail) = (String(format: L("backup.databaseFailed"), database), reason)
        }
        // The engine's own reason (wrong password, full disk) follows the generic sentence.
        guard let detail, !detail.isEmpty else { return text }
        return text + " " + detail
    }
}

extension StackStore {
    /// Engines whose databases travel with the configuration (their builtin connections).
    static let backupEngines = ["mysql", "mariadb", "postgres"]

    private struct BackupDatabase: Decodable { let name: String; let system: Bool? }
    private struct BackupConnection: Decodable { let id: String; let kind: String; let builtin: Bool? }
    private struct Dumped: Decodable { let size: Int64?; let skippedViews: [String]? }
    private struct Restored: Decodable { let bytes: Int64? }

    /// The builtin connections of the engines Stack installed here.
    func backupConnections() async -> [String] {
        let list: [BackupConnection] = (try? await call(["method": "dbConnections"])) ?? []
        return list.filter { $0.builtin == true && Self.backupEngines.contains($0.kind) }.map(\.kind)
    }

    private func backupRequest(_ engine: String, _ extra: [String: Any]) -> [String: Any] {
        var request = extra
        request["connection"] = "stack-\(engine)"
        #if DEBUG
        // QA against a throwaway server: the QA Keychain items belong to other tests.
        if QAHooks.databaseBackupWithoutVault { return request }
        #endif
        if let password = DatabaseVault.get("stack-\(engine)") { request["password"] = password }
        return request
    }

    /// Every user database of every installed engine, dumped into `folder/bases/`. An installed
    /// engine that is stopped stops the whole export (a backup that silently misses data is worse
    /// than none). The status bar follows each database and the bytes written.
    func backupDatabases(into folder: URL) async throws -> [DatabaseBackupEntry] {
        var work: [(engine: String, database: String)] = []
        for engine in await backupConnections() {
            let request = backupRequest(engine, ["method": "dbDatabases"])
            let databases: [BackupDatabase]
            do { databases = try await call(request) } catch {
                throw DatabaseBackupError.stopped(engine, detail: (error as? EngineFailure)?.errorDescription)
            }
            work += databases.filter { $0.system != true }.map { (engine, $0.name) }
        }
        let job = beginJob(L("backup.dumpingStart"))
        defer { endJob(job) }
        var entries: [DatabaseBackupEntry] = []
        for (index, item) in work.enumerated() {
            // A PostgreSQL name may hold «/» or «..»: the file stays inside `bases/<engine>/`.
            let safeName = item.database.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "..", with: "__")
            let relative = "bases/\(item.engine)/\(safeName).sql.gz"
            let url = folder.appendingPathComponent(relative)
            guard url.standardizedFileURL.path.hasPrefix(folder.standardizedFileURL.path + "/") else {
                throw DatabaseBackupError.failed(item.database)
            }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let label = String(format: L("backup.dumping"), Tech.of(item.engine).title, item.database, index + 1, work.count)
            let token = UUID().uuidString.lowercased()
            let poll = followProgress(token, job: job, label: label)
            defer { poll.cancel() }
            updateJob(job, label)
            let request = backupRequest(item.engine, ["method": "dbDump", "databases": [item.database], "path": url.path,
                                                      "compress": true, "progress": token, "skipBrokenViews": true])
            let dumped: Dumped
            do { dumped = try await call(request) } catch {
                throw DatabaseBackupError.failed(item.database, detail: (error as? EngineFailure)?.errorDescription)
            }
            entries.append(DatabaseBackupEntry(engine: item.engine, database: item.database, file: relative, size: dumped.size,
                                               skippedViews: dumped.skippedViews?.isEmpty == false ? dumped.skippedViews : nil))
        }
        return entries
    }

    /// Loads one saved database into the same engine here. Waits for the engine (the restore has
    /// just turned it on); a database that already holds data here is left as it is (`.kept`).
    func restoreDatabase(_ entry: DatabaseBackupEntry, from folder: URL) async -> RestoreOutcome {
        let source = folder.appendingPathComponent(entry.file).standardizedFileURL
        guard source.path.hasPrefix(folder.standardizedFileURL.path + "/"),
              FileManager.default.fileExists(atPath: source.path) else { return .failed }
        var existing: [BackupDatabaseTables]?
        for _ in 0..<60 {
            existing = try? await call(backupRequest(entry.engine, ["method": "dbDatabases"]))
            if existing != nil { break }
            try? await Task.sleep(for: .seconds(2))
        }
        guard let existing else { return .failed }
        // MySQL counts tables; PostgreSQL's list does not, so any database there other than the
        // default «postgres» (empty on a new Mac) counts as holding data.
        let holdsData = existing.contains { database in
            database.name == entry.database
                && ((database.tables ?? 0) > 0 || (entry.engine == "postgres" && database.name != "postgres"))
        }
        if holdsData { return .kept }
        let job = beginJob(String(format: L("backup.restoringDatabase"), entry.database, Tech.of(entry.engine).title))
        defer { endJob(job) }
        let request = backupRequest(entry.engine, ["method": "dbRestore", "database": entry.database, "path": source.path,
                                                   "create": true, "confirmed": true])
        let restored: Restored? = try? await call(request)
        return restored == nil ? .failed : .done
    }

    enum RestoreOutcome { case done, kept, failed }
    private struct BackupDatabaseTables: Decodable { let name: String; let tables: Int? }

    /// Shows the bytes a dump has written in the status bar label, from its progress file.
    private func followProgress(_ token: String, job: UUID, label: String) -> Task<Void, Never> {
        let path = Folder.baseURL.appendingPathComponent("run/progress-\(token).json")
        return Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                // The file is read off the main thread; only the number comes back.
                let done = await Task.detached { () -> Int? in
                    guard let data = try? Data(contentsOf: path),
                          let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
                    return value["done"] as? Int
                }.value
                if let done, done > 0 {
                    await self?.updateJob(job, "\(label) · \(Format.fileSizeText(Int64(done)))")
                }
            }
        }
    }
}
