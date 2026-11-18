import Foundation
import Testing
@testable import ButakeStack

// Barrido de UI/UX, grupos G8 y G9: errores de conexión, archivos .sql soltados y Terminal.

@Test func aGenericFailureReachingAServerIsAConnectionProblem() {
    let connection = DBConnection(id: "stack-mysql", name: "MySQL", kind: "mysql", host: "127.0.0.1", port: 3306, builtin: true)
    let problem = DBProblem.connecting(EngineFailure(code: "query_failed", messageKey: "error.query_failed"), to: connection)
    #expect(problem.kind == .offline)
    #expect(problem.title.contains("127.0.0.1:3306"))
    #expect(!problem.title.contains("consulta"))
    // The engine's own words stay as the technical detail.
    #expect(problem.detail == L("error.query_failed"))
}

@Test func aSpecificConnectionFailureKeepsItsOwnExplanation() {
    let connection = DBConnection(id: "x", name: "Remota", kind: "mysql", host: "db.example", port: 3306)
    let failure = EngineFailure(code: "query_failed", messageKey: "error.query_failed", detail: "ERROR 1045 (28000): Access denied for user 'a'@'h' (using password: YES)")
    #expect(DBProblem.connecting(failure, to: connection).kind == .wrongPassword)
}

@Test func onlySQLScriptsAreRestoredWhenDropped() {
    #expect(DatabaseClient.isSQLDump(URL(fileURLWithPath: "/tmp/respaldo.sql")))
    #expect(DatabaseClient.isSQLDump(URL(fileURLWithPath: "/tmp/respaldo.SQL.GZ")))
    #expect(!DatabaseClient.isSQLDump(URL(fileURLWithPath: "/tmp/respaldo.csv")))
    #expect(!DatabaseClient.isSQLDump(URL(fileURLWithPath: "/tmp/respaldo.gz")))
}

@Test func thisMacTerminalIsCalledTerminalLocal() {
    #expect(LocalProgram.shell.title == "Terminal local")
}
