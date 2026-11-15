import Foundation
import Testing
@testable import ButakeStack

/// Keys the database client composes at run time ("db.tab.\(tab)", "db.op.\(op)"…) or picks with a
/// condition: every value they can take has its text.
@MainActor @Test func databaseClientDynamicTextsExist() {
    var keys: [String] = []
    keys += DatabaseDetail.allTabs.map { "db.tab.\($0)" }
    keys += TableDataPanel.operators.map { "db.op.\($0)" }
    keys += ["csv", "json", "sql"].map { "db.export.\($0)" }
    keys += ["prefer", "require", "verify", "off"].map { "db.tls.\($0)" }
    keys += ["no action", "restrict", "cascade", "set null", "set default"].map { "ddl.action.\($0)" }
    let problems = ["needsPassword", "wrongPassword", "offline", "unknownDatabase", "tls", "syntax", "permission", "readOnly"]
    keys += problems.flatMap { ["db.problem.\($0)", "db.problem.\($0).help"] }
    // Chosen with a condition: L(flag ? "a" : "b").
    keys += ["db.emptyNone", "db.emptyNoneTitle", "db.empty", "db.emptyDetail", "db.noRows", "db.noRowsFiltered", "db.sql.placeholder", "db.sql.placeholderRedis",
             "db.noForeignKeys", "ddl.sqliteForeignKeys", "db.mode.readOnlyHelp", "db.mode.readOnlyHelpRedis",
             "db.confirm.sql", "db.confirm.sqlTransaction", "db.tx.committed", "db.tx.rolledBack",
             "db.tls.verifySSHPostgres", "db.tls.verifySSHMySQL", "db.filter.and", "db.filter.or"]
    let missing = keys.filter { localized($0) == nil }
    #expect(missing.isEmpty, "Missing texts: \(missing.joined(separator: ", "))")
}

/// A connection or a database shows its server's tabs; a table, its rows and structure; Redis
/// and SQLite only what they have.
@MainActor @Test func databaseTabsFollowTheSelection() {
    let mysql = DBConnection(id: "m", name: "M", kind: "mysql")
    let sqlite = DBConnection(id: "s", name: "S", kind: "sqlite", path: "/tmp/x.sqlite")
    let redis = DBConnection(id: "r", name: "R", kind: "redis")
    #expect(DatabaseDetail.tabs(mysql, DBSelection(connection: "m")) == ["overview", "sql", "users", "processes", "backup"])
    #expect(DatabaseDetail.tabs(mysql, DBSelection(connection: "m", database: "app")) == ["tables", "sql", "users", "processes", "backup", "diagram"])
    #expect(DatabaseDetail.tabs(mysql, DBSelection(connection: "m", database: "app", table: "users")) == ["data", "structure"])
    #expect(DatabaseDetail.tabs(sqlite, DBSelection(connection: "s", database: "main")) == ["tables", "sql", "diagram"])
    #expect(DatabaseDetail.tabs(redis, DBSelection(connection: "r", database: "0")) == ["overview", "keys", "console", "clients"])
    for tab in ["overview", "tables", "data", "keys"] { #expect(DatabaseDetail.allTabs.contains(tab)) }
}

/// «Abrir en SQL» quotes a table's name as its engine writes it.
@MainActor @Test func tablesAreQuotedForTheirEngine() {
    #expect(DatabaseDetail.quoted("users", schema: nil, kind: "mysql") == "`users`")
    #expect(DatabaseDetail.quoted("users", schema: "public", kind: "postgres") == "\"users\"")
    #expect(DatabaseDetail.quoted("users", schema: "sales", kind: "postgres") == "\"sales\".\"users\"")
}
