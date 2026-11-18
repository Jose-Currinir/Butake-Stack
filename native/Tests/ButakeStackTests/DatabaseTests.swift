import Foundation
import Testing
@testable import ButakeStack

@Test func changesComeBackAsConfirmationFirst() throws {
    let ask = Data(#"{"needsConfirmation":true,"statements":["DROP DATABASE `x`"]}"#.utf8)
    guard case .confirm(let statements) = try JSONDecoder().decode(Confirmable<DBRunOutput>.self, from: ask) else {
        Issue.record("expected a confirmation"); return
    }
    #expect(statements == ["DROP DATABASE `x`"])
    let done = Data(#"{"results":[],"error":null,"durationMs":3}"#.utf8)
    guard case .done(let output) = try JSONDecoder().decode(Confirmable<DBRunOutput>.self, from: done) else {
        Issue.record("expected a result"); return
    }
    #expect(output.durationMs == 3)
    guard case .done(let flag) = try JSONDecoder().decode(Confirmable<Bool>.self, from: Data("true".utf8)) else {
        Issue.record("expected a plain value"); return
    }
    #expect(flag)
}

@Test func databaseErrorsAreExplained() {
    #expect(DBProblem.from(text: "ERROR 1045 (28000): Access denied for user 'root'@'localhost' (using password: NO)").kind == .needsPassword)
    #expect(DBProblem.from(text: "ERROR 1045 (28000): Access denied for user 'app'@'localhost' (using password: YES)").kind == .wrongPassword)
    #expect(DBProblem.from(text: "psql: error: connection to server at \"127.0.0.1\", port 5432 failed: Connection refused").kind == .offline)
    #expect(DBProblem.from(text: "ERROR 1064 (42000): You have an error in your SQL syntax").kind == .syntax)
    let other = DBProblem.from(text: "ERROR 1146 (42S02): Table 'demo.x' doesn't exist")
    #expect(other.kind == .other && other.message == "Table 'demo.x' doesn't exist" && other.detail != nil)
    let engine = EngineFailure(code: "database_error", messageKey: "error.database_error", detail: "ERROR:  password authentication failed for user \"app\"")
    #expect(DBProblem.from(engine).kind == .wrongPassword)
}

@Test func databaseErrorsAreRecognizedByTheirCodes() {
    #expect(DBProblem.from(text: "ERROR 1792 (25006): Cannot execute statement in a READ ONLY transaction.").kind == .readOnly)
    #expect(DBProblem.from(text: "ERROR:  25006: cannot execute INSERT in a read-only transaction").kind == .readOnly)
    #expect(DBProblem.from(text: "ERROR:  42601: error de sintaxis en o cerca de «FORM»").kind == .syntax)
    #expect(DBProblem.from(text: "ERROR:  42501: permiso denegado a la tabla t").kind == .permission)
    #expect(DBProblem.from(text: "FATAL:  3D000: no existe la base de datos «x»").kind == .unknownDatabase)
    #expect(DBProblem.from(text: "ERROR 1049 (42000): Unknown database 'x'").kind == .unknownDatabase)
    #expect(DBProblem.from(text: "Runtime error: attempt to write a readonly database (8)").kind == .readOnly)
    let pg = DBProblem.from(text: "ERROR:  42P01: relation \"x\" does not exist")
    #expect(pg.kind == .other && pg.message == "relation \"x\" does not exist")
    // Engine codes in place of a server message have messages of their own, never the raw code.
    let code = DBProblem.from(text: "client_failed")
    #expect(code.message != "client_failed" && code.detail == nil)
    let readOnly = EngineFailure(code: "read_only_connection", messageKey: "error.read_only_connection", detail: nil)
    #expect(DBProblem.from(readOnly).kind == .readOnly)
}

@Test func connectionFlagsDecodeAndDefaultToOff() throws {
    let old = Data(#"{"id":"a","name":"A","kind":"mysql","host":"h","port":3306,"user":"u","database":"","tls":"prefer","builtin":false,"hasPassword":false}"#.utf8)
    let decoded = try JSONDecoder().decode(DBConnection.self, from: old)
    #expect(!decoded.production && !decoded.readOnly && decoded.allowsWrites)
    let flagged = Data(#"{"id":"a","name":"A","kind":"sqlite","path":"/x","production":true,"readOnly":true}"#.utf8)
    let connection = try JSONDecoder().decode(DBConnection.self, from: flagged)
    #expect(connection.production && connection.readOnly && !connection.allowsWrites)
    let again = try JSONDecoder().decode(DBConnection.self, from: JSONEncoder().encode(connection))
    #expect(again == connection)
}

@Test @MainActor func gridSortsBySeveralColumns() {
    typealias Sort = TableDataPanel.Sort
    var sorts = TableDataPanel.sorting([], by: "a", adding: false)
    #expect(sorts == [Sort(column: "a", descending: false)])
    sorts = TableDataPanel.sorting(sorts, by: "b", adding: true)
    #expect(sorts == [Sort(column: "a", descending: false), Sort(column: "b", descending: false)])
    sorts = TableDataPanel.sorting(sorts, by: "b", adding: true)
    #expect(sorts.last == Sort(column: "b", descending: true))
    sorts = TableDataPanel.sorting(sorts, by: "b", adding: true)
    #expect(sorts == [Sort(column: "a", descending: false)])
    #expect(TableDataPanel.sorting(sorts, by: "a", adding: false) == [Sort(column: "a", descending: true)])
}

@Test func sqlIsFormattedWithoutTouchingStrings() {
    let out = SQLFormatter.format("select id, name from users u left join roles r on r.id = u.role where u.active = 1 and u.name like 'a and b' order by name;")
    #expect(out == """
    SELECT id,
        name
    FROM users u
    LEFT JOIN roles r ON r.id = u.role
    WHERE u.active = 1
        AND u.name LIKE 'a and b'
    ORDER BY name;
    """)
    #expect(SQLFormatter.format("select count(*) from t where x between 1 and 2").contains("BETWEEN 1 AND 2"))
}

@Test func completionOffersTablesColumnsAndKeywords() {
    let schema = DBSchema(tables: [DBSchema.Table(schema: "", name: "users", columns: [.init(name: "id", type: "int", key: "PRI"), .init(name: "email", type: "text", key: "")])],
                          foreignKeys: [])
    #expect(SQLCompletion.suggestions(prefix: "us", qualifier: nil, schema: schema).first == "users")
    #expect(SQLCompletion.suggestions(prefix: "", qualifier: "users", schema: schema) == ["id", "email"])
    #expect(SQLCompletion.suggestions(prefix: "sel", qualifier: nil, schema: schema).contains("SELECT"))
}

@Test func connectionURLsNeverCarryPasswords() {
    let mysql = DBConnection(id: "stack-mysql", name: "mysql", kind: "mysql", host: "127.0.0.1", port: 3306, user: "root", builtin: true, hasPassword: true)
    #expect(mysql.url(database: "gestion") == "mysql://root@127.0.0.1:3306/gestion")
    let pg = DBConnection(id: "pg", name: "pg", kind: "postgres", host: "db", port: 5432, user: "app user")
    #expect(pg.url() == "postgresql://app%20user@db:5432/postgres")
    #expect(DBConnection(id: "r", name: "r", kind: "redis", host: "127.0.0.1", port: 6379).url() == "redis://127.0.0.1:6379/0")
}

@Test func emptyStoreListsNoConnections() async throws {
    let engine = StackEngine()
    let list: [DBConnection] = try await engine.call(["method": "dbConnections"])
    #expect(list.isEmpty)
}
