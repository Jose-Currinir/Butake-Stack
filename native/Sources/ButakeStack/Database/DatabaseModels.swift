import Foundation

/// A database connection as the engine stores it (never with its password, which lives in the
/// Keychain: see `DatabaseVault`).
struct DBConnection: Codable, Identifiable, Hashable, Sendable {
    struct SSH: Codable, Hashable, Sendable {
        var host: String
        var port: Int = 22
        var user: String
        var identity: String?
        /// A key imported into Stack (by id); it wins over `identity`.
        var key: String?
    }
    var id: String
    var name: String
    var kind: String
    var host: String = ""
    var port: Int = 0
    var user: String = ""
    var database: String = ""
    var path: String?
    var tls: String = "prefer"
    var ssh: SSH?
    var builtin: Bool = false
    var hasPassword: Bool = false
    /// Stack's PostgreSQL that asks for a password: the engine supplies its superuser's, never the app.
    var stackPassword: Bool = false
    /// A production server: shown in red everywhere and every change asks for its name typed again.
    var production: Bool = false
    /// Only reads: the engine refuses every change and the server session is read-only.
    var readOnly: Bool = false

    init(id: String, name: String, kind: String, host: String = "", port: Int = 0, user: String = "", database: String = "", path: String? = nil,
         tls: String = "prefer", ssh: SSH? = nil, builtin: Bool = false, hasPassword: Bool = false, production: Bool = false, readOnly: Bool = false) {
        self.id = id; self.name = name; self.kind = kind; self.host = host; self.port = port; self.user = user; self.database = database
        self.path = path; self.tls = tls; self.ssh = ssh; self.builtin = builtin; self.hasPassword = hasPassword
        self.production = production; self.readOnly = readOnly
    }
    private enum CodingKeys: String, CodingKey { case id, name, kind, host, port, user, database, path, tls, ssh, builtin, hasPassword, stackPassword, production, readOnly }
    /// Missing flags (an older engine) read as false.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        kind = try c.decode(String.self, forKey: .kind)
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? ""
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 0
        user = try c.decodeIfPresent(String.self, forKey: .user) ?? ""
        database = try c.decodeIfPresent(String.self, forKey: .database) ?? ""
        path = try c.decodeIfPresent(String.self, forKey: .path)
        tls = try c.decodeIfPresent(String.self, forKey: .tls) ?? "prefer"
        ssh = try c.decodeIfPresent(SSH.self, forKey: .ssh)
        builtin = try c.decodeIfPresent(Bool.self, forKey: .builtin) ?? false
        hasPassword = try c.decodeIfPresent(Bool.self, forKey: .hasPassword) ?? false
        stackPassword = try c.decodeIfPresent(Bool.self, forKey: .stackPassword) ?? false
        production = try c.decodeIfPresent(Bool.self, forKey: .production) ?? false
        readOnly = try c.decodeIfPresent(Bool.self, forKey: .readOnly) ?? false
    }

    /// Changes (edits, structure, import, restore, users) are offered at all.
    var allowsWrites: Bool { !readOnly }
    var isRedis: Bool { kind == "redis" || kind == "valkey" }
    var isSQL: Bool { !isRedis }
    var tech: Tech { kind == "sqlite" ? Tech.of("database") : Tech.of(kind) }
    var title: String { builtin ? String(format: L("db.builtinName"), tech.title) : name }
    static func defaultPort(_ kind: String) -> Int {
        switch kind { case "postgres": 5432; case "redis", "valkey": 6379; case "mariadb": 3306; case "sqlite": 0; default: 3306 }
    }
    /// URL for apps and other clients, without the password.
    func url(database: String? = nil) -> String {
        let db = database ?? self.database
        switch kind {
        case "postgres": return "postgresql://\(user.urlEncoded)@\(host):\(port)/\(db.isEmpty ? "postgres" : db.urlEncoded)"
        case "redis", "valkey": return "redis://\(user.isEmpty ? "" : user.urlEncoded + "@")\(host):\(port)/\(db.isEmpty ? "0" : db)"
        case "sqlite": return "sqlite://\(path ?? "")"
        default: return "mysql://\(user.urlEncoded)@\(host):\(port)\(db.isEmpty ? "" : "/" + db.urlEncoded)"
        }
    }
}

extension String {
    var urlEncoded: String { addingPercentEncoding(withAllowedCharacters: .urlUserAllowed) ?? self }
}

struct DBDatabase: Codable, Identifiable, Hashable, Sendable {
    var name: String
    var size: Int?
    var tables: Int?
    var system: Bool
    var id: String { name }
}

struct DBObject: Codable, Identifiable, Hashable, Sendable {
    var schema: String?
    var name: String
    var view: Bool
    var rows: Int?
    var size: Int?
    var engine: String?
    var id: String { "\(schema ?? "").\(name)" }
}

struct DBColumn: Codable, Hashable, Sendable {
    var name: String
    var type: String?
    var nullable: Bool
    var `default`: String?
    var key: String?
    var extra: String?
    var comment: String?
}

struct DBRows: Codable, Sendable {
    var columns: [DBColumn]
    var rows: [[String?]]
    var total: Int?
    var page: Int
    var pageSize: Int
    var primaryKey: [String]
    var durationMs: Int?
    /// The total is the server's estimate (large table without filters) or stopped at the cap.
    var totalEstimated: Bool?
    var totalCapped: Bool?
}

struct DBResultSet: Codable, Hashable, Sendable {
    var columns: [String]
    var rows: [[String?]]
    var affected: Int?
    var statement: String
    var truncated: Bool
}

struct DBRunOutput: Codable, Sendable {
    var results: [DBResultSet]
    var error: String?
    var durationMs: Int
}

struct DBIndex: Codable, Hashable, Sendable { var name: String?; var unique: Bool; var columns: String?; var type: String? }
struct DBForeignKey: Codable, Hashable, Sendable { var name: String?; var columns: String?; var references: String? }
struct DBStructure: Codable, Sendable {
    var columns: [DBColumn]
    var indexes: [DBIndex]
    var foreignKeys: [DBForeignKey]
    var ddl: String
}

/// Tables, columns and foreign keys of a database (completion and the diagram).
struct DBSchema: Codable, Sendable {
    struct Column: Codable, Hashable, Sendable { var name: String?; var type: String?; var key: String? }
    struct Table: Codable, Hashable, Sendable, Identifiable {
        var schema: String?
        var name: String?
        var columns: [Column]
        var id: String { "\(schema ?? "").\(name ?? "")" }
    }
    struct ForeignKey: Codable, Hashable, Sendable {
        var name: String?
        var schema: String?
        var table: String?
        var columns: [String?]
        var refSchema: String?
        var refTable: String?
        var refColumns: [String?]
        var from: String { "\(schema ?? "").\(table ?? "")" }
        /// The referenced table in the same schema when the engine does not say (MySQL, SQLite).
        var to: String { "\((refSchema ?? "").isEmpty ? (schema ?? "") : (refSchema ?? "")).\(refTable ?? "")" }
    }
    var tables: [Table]
    var foreignKeys: [ForeignKey]
}

/// The plan of a statement as a tree of lines (or MariaDB's classic table).
struct DBPlan: Codable, Sendable {
    struct Line: Codable, Hashable, Sendable { var depth: Int; var text: String; var detail: Bool }
    struct Table: Codable, Sendable { var columns: [String]; var rows: [[String?]] }
    var lines: [Line]
    var table: Table?
    var raw: String
}

/// A tab of the SQL editor (kept per connection by the engine).
struct QueryTab: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var database: String
    var sql: String
}

struct DBUser: Codable, Identifiable, Hashable, Sendable {
    var name: String?
    var host: String?
    var locked: Bool
    var plugin: String?
    var grants: [String]
    var system: Bool
    var id: String { "\(name ?? "")@\(host ?? "")" }
}

struct DBProcess: Codable, Identifiable, Hashable, Sendable {
    var pid: String?
    var user: String?
    var host: String?
    var database: String?
    var state: String?
    var seconds: Int?
    var query: String?
    var id: String { "\(pid ?? "")·\(host ?? "")" }
    private enum CodingKeys: String, CodingKey { case pid = "id", user, host, database, state, seconds, query }
}

struct RedisKeys: Codable, Sendable {
    struct Database: Codable, Hashable, Sendable { var index: Int; var keys: Int }
    var keys: [String]
    var cursor: String
    var databases: [Database]
}

/// A request that changes something comes back first with what it would run; the app shows it
/// and repeats the request with `confirmed` only if the user agrees.
enum Confirmable<T: Decodable & Sendable>: Decodable, Sendable {
    case confirm([String])
    case done(T)
    private enum Keys: String, CodingKey { case needsConfirmation, statements }
    init(from decoder: Decoder) throws {
        if let keyed = try? decoder.container(keyedBy: Keys.self), (try? keyed.decode(Bool.self, forKey: .needsConfirmation)) == true {
            self = .confirm(try keyed.decode([String].self, forKey: .statements))
        } else {
            self = .done(try T(from: decoder))
        }
    }
}

/// Any JSON value (Redis replies have every shape).
enum RedisReply: Codable, Hashable, Sendable {
    case null, bool(Bool), number(Double), string(String), array([RedisReply]), object([String: RedisReply])
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([RedisReply].self) { self = .array(a) }
        else { self = .object(try c.decode([String: RedisReply].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
    /// Readable text: strings as they are, the rest as indented JSON.
    var text: String {
        switch self {
        case .null: "(nil)"
        case .string(let s): s
        case .number(let n): n == n.rounded() && abs(n) < 1e15 ? String(Int64(n)) : String(n)
        case .bool(let b): b ? "true" : "false"
        default:
            (try? String(decoding: { let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]; return try e.encode(self) }(), as: UTF8.self)) ?? ""
        }
    }
}

struct RedisValue: Codable, Sendable {
    var key: String
    var type: String
    var value: RedisReply
    var ttl: RedisReply
}

/// What the side list has selected.
struct DBSelection: Hashable, Sendable {
    var connection: String
    var database: String?
    var schema: String?
    var table: String?
    var isView = false
}
