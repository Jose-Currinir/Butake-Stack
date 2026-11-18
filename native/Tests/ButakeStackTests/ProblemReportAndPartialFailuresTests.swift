import Foundation
import Testing
@testable import ButakeStack

// Invented values, never real ones.
private let fakeToken = "ghp_" + String(repeating: "aB3dE", count: 8)
private let fakePassword = "hunter2-inventada"
private let fakeEnvValue = "valorSecretoDeEjemplo123"
private let fakeHome = "/Users/inventada"

private func sample() -> String {
    """
    token \(fakeToken) rejected
    DB_PASSWORD=\(fakeEnvValue)
    password: \(fakePassword)
    {"api_key": "\(fakeEnvValue)"}
    postgres://admin:\(fakePassword)@127.0.0.1/demo
    Authorization: Bearer abcdefghijklmnop12345
    run --password \(fakePassword) now
    open \(fakeHome)/Stack/Projects/demo/.env
    """
}

@Test func redactionRemovesTokensPasswordsEnvValuesAndTheHomeName() {
    let clean = ProblemReport.redact(sample(), home: fakeHome)
    for secret in [fakeToken, fakePassword, fakeEnvValue, "abcdefghijklmnop12345", "inventada"] {
        #expect(!clean.contains(secret), "left: \(secret)")
    }
    #expect(clean.contains("~/Stack/Projects/demo/.env"))
    #expect(clean.contains("DB_PASSWORD="))
}

@Test func redactionKeepsWhatDiagnosesAndHexHashes() {
    let hash = String(repeating: "ab12", count: 16)
    let clean = ProblemReport.redact("checksum \(hash) en el puerto 8080: folder_missing", home: fakeHome)
    #expect(clean == "checksum \(hash) en el puerto 8080: folder_missing")
}

@MainActor @Test func theReportAndTheCopiedDetailsCarryNoSecret() {
    let failure = ActionFailure(error: EngineFailure(code: "new_code", messageKey: "error.new_code",
                                                      detail: "falló con password=\(fakePassword) en \(fakeHome)/x"))
    let details = ProblemReport.details(of: failure, version: "9.9", macOS: "macOS 15.0.0", home: fakeHome)
    #expect(details.contains("new_code") && details.contains("9.9") && details.contains("macOS 15.0.0"))
    let store = StackStore()
    store.record(failure)
    let report = ProblemReport.build(note: "mi ficha es \(fakeToken)", failures: store.recentFailures,
                                     log: ["[store] fallo con env PORT=\(fakeEnvValue) y token=\(fakeEnvValue)"], version: "9.9", macOS: "macOS 15.0.0", home: fakeHome)
    for text in [details, report] {
        for secret in [fakeToken, fakePassword, fakeEnvValue, "inventada"] { #expect(!text.contains(secret), "left: \(secret)") }
    }
    #expect(report.contains("new_code"))
}

@MainActor @Test func aFailedReadKeepsTheListAndIsSaidOnItsPageNotAsAnAlert() async {
    let store = StackStore()
    store.phpRuntimes = []
    store.readDone(.runtimes, EngineFailure(code: "engine", messageKey: "engine.requestFailed"), retry: {})
    #expect(store.pageFailures[.runtimes]?.impact == .partial)
    #expect(store.pageFailures[.runtimes]?.retry != nil)
    #expect(store.windowFailure == nil)
    store.readDone(.runtimes, nil, retry: nil)
    #expect(store.pageFailures[.runtimes] == nil)
}

@MainActor @Test func aPolledReadIsSaidOnlyAfterTwoFailuresInARow() {
    let store = StackStore()
    let error = EngineFailure(code: "engine", messageKey: "engine.requestFailed")
    store.readDone(.mail, error, streak: StackStore.readFailureStreak, retry: nil)
    #expect(store.pageFailures[.mail] == nil)
    store.readDone(.mail, error, streak: StackStore.readFailureStreak, retry: nil)
    #expect(store.pageFailures[.mail] != nil)
    store.readDone(.mail, error, streak: StackStore.readFailureStreak, retry: nil)
    #expect(store.recentFailures.count == 1)
    store.readDone(.mail, nil, retry: nil)
    #expect(store.pageFailures[.mail] == nil)
}

@MainActor @Test func anActionFailureStaysBlockingByDefault() {
    #expect(ActionFailure(error: EngineFailure(code: "folder_missing")).impact == .blocking)
    let store = StackStore()
    store.report(EngineFailure(code: "folder_missing"))
    #expect(store.windowFailure != nil && store.pageFailures.isEmpty && store.recentFailures.count == 1)
}
