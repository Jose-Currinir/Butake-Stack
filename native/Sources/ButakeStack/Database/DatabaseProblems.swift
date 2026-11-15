import SwiftUI

/// A failure explained for people: what happened, what to do, and the server's own text folded
/// away as a technical detail.
struct DBProblem: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case needsPassword, wrongPassword, offline, unknownDatabase, tls, ssh, clientMissing, syntax, permission, readOnly, other }
    var kind: Kind
    var title: String
    var message: String
    var detail: String?

    /// Codes the engine writes where the server said nothing (they have messages of their own).
    static let engineCodes: Set<String> = ["client_failed", "result_too_large", "query_failed", "dump_failed", "restore_failed", "export_failed",
                                           "session_failed", "session_timeout"]

    static func from(_ error: Error) -> DBProblem {
        if let failure = error as? EngineFailure {
            if let detail = failure.detail { return from(text: detail) }
            switch failure.code {
            case let code where code.hasPrefix("ssh_") || code == "invalid_ssh" || code == "unknown_ssh_key":
                return DBProblem(kind: .ssh, title: L("db.problem.ssh"), message: failure.errorDescription ?? "", detail: nil)
            case "client_not_installed":
                return DBProblem(kind: .clientMissing, title: L("db.problem.client"), message: failure.errorDescription ?? "", detail: nil)
            case "read_only_connection":
                return DBProblem(kind: .readOnly, title: L("db.problem.readOnly"), message: L("db.problem.readOnly.help"), detail: nil)
            default:
                return DBProblem(kind: .other, title: L("db.problem.other"), message: failure.errorDescription ?? L("engine.requestFailed"), detail: nil)
            }
        }
        return DBProblem(kind: .other, title: L("db.problem.other"), message: error.localizedDescription, detail: nil)
    }

    /// MySQL's error number and SQLSTATE ("ERROR 1045 (28000): …") or PostgreSQL's SQLSTATE
    /// ("ERROR:  42P01: …", psql runs with VERBOSITY=verbose).
    static func codes(_ text: String) -> (errno: Int?, sqlstate: String?) {
        let line = text.split(separator: "\n").first.map(String.init) ?? text
        if let match = line.firstMatch(of: /ERROR (\d{4,5}) \(([0-9A-Z]{5})\)/) { return (Int(match.1), String(match.2)) }
        if let match = line.firstMatch(of: /^(?:ERROR|FATAL|PANIC):\s+([0-9A-Z]{5}):/) { return (nil, String(match.1)) }
        if let match = line.firstMatch(of: /ERROR (\d{4})/) { return (Int(match.1), nil) }
        return (nil, nil)
    }

    /// The kind for a code, before falling back to the wording.
    static func kind(errno: Int?, sqlstate: String?, text: String) -> (Kind, String)? {
        switch errno {
        case 1045: return text.contains("using password: no") ? (.needsPassword, "needsPassword") : (.wrongPassword, "wrongPassword")
        case 1044, 1142, 1143, 1227, 1370: return (.permission, "permission")
        case 1049: return (.unknownDatabase, "unknownDatabase")
        case 1064, 1149: return (.syntax, "syntax")
        case 1792, 1290, 1836: return (.readOnly, "readOnly")
        case 2002, 2003, 2005, 2006, 2013: return (.offline, "offline")
        case 2026: return (.tls, "tls")
        default: break
        }
        guard let state = sqlstate else { return nil }
        switch state {
        case "28P01": return (.wrongPassword, "wrongPassword")
        case "3D000": return (.unknownDatabase, "unknownDatabase")
        case "42601": return (.syntax, "syntax")
        case "42501": return (.permission, "permission")
        case "25006": return (.readOnly, "readOnly")
        case let s where s.hasPrefix("08"): return (.offline, "offline")
        default: return nil
        }
    }

    /// The database's own message: by its code (errno, SQLSTATE) when it has one, by its usual
    /// wording otherwise (MySQL, PostgreSQL, SQLite, Redis).
    static func from(text: String) -> DBProblem {
        let t = text.lowercased()
        func make(_ kind: Kind, _ key: String) -> DBProblem {
            DBProblem(kind: kind, title: L("db.problem.\(key)"), message: L("db.problem.\(key).help"), detail: text)
        }
        let code = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if engineCodes.contains(code) {
            return DBProblem(kind: .other, title: L("db.problem.other"), message: L("error.\(code)"), detail: nil)
        }
        let (errno, sqlstate) = codes(text)
        if let (kind, key) = kind(errno: errno, sqlstate: sqlstate, text: t) { return make(kind, key) }
        if t.contains("readonly database") || t.contains("read-only transaction") || t.contains("read only transaction") { return make(.readOnly, "readOnly") }
        if t.contains("using password: no") || t.contains("no password supplied") || t.contains("noauth") || t.contains("authentication required") {
            return make(.needsPassword, "needsPassword")
        }
        if t.contains("access denied for user") || t.contains("password authentication failed") || t.contains("wrongpass") || t.contains("invalid password") {
            return make(.wrongPassword, "wrongPassword")
        }
        if t.contains("can't connect") || t.contains("connection refused") || t.contains("could not connect") || t.contains("lost connection")
            || t.contains("is the server running") || t.contains("timeout") || t.contains("timed out") || t.contains("unknown mysql server host")
            || t.contains("could not translate host name") {
            return make(.offline, "offline")
        }
        if t.contains("unknown database") || (t.contains("database") && t.contains("does not exist")) { return make(.unknownDatabase, "unknownDatabase") }
        if t.contains("ssl") || t.contains("tls") || t.contains("secure connection") || t.contains("certificate") { return make(.tls, "tls") }
        if t.contains("syntax") || t.contains("error 1064") { return make(.syntax, "syntax") }
        if t.contains("command denied") || t.contains("permission denied") || t.contains("must be owner") || t.contains("privilege") {
            return make(.permission, "permission")
        }
        return DBProblem(kind: .other, title: L("db.problem.query"), message: firstLine(text), detail: text)
    }

    /// "ERROR 1146 (42S02): Table 'x' doesn't exist" → "Table 'x' doesn't exist".
    static func firstLine(_ text: String) -> String {
        let line = text.split(separator: "\n").first.map(String.init) ?? text
        if let range = line.range(of: "): ") { return String(line[range.upperBound...]) }
        if line.hasPrefix("ERROR:  ") {
            let rest = line.dropFirst(8)
            // "42P01: relation …" (verbose psql): without the SQLSTATE.
            if let match = rest.firstMatch(of: #/^[0-9A-Z]{5}: /#) { return String(rest[match.range.upperBound...]) }
            return String(rest)
        }
        return line
    }

    var symbol: String {
        switch kind {
        case .needsPassword, .wrongPassword: "key.slash"
        case .offline: "bolt.horizontal.circle"
        case .unknownDatabase: Symbols.database
        case .tls: "lock.trianglebadge.exclamationmark"
        case .ssh: "lock.shield"
        case .clientMissing: "arrow.down.circle"
        case .syntax: Symbols.code
        case .permission: "hand.raised"
        case .readOnly: "lock"
        case .other: Symbols.warning
        }
    }
}
