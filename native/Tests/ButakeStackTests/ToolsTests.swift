import Foundation
import Testing
@testable import ButakeStack

// Registros: one place for every log, reached already filtered.

@Test func logsKnowTheOriginOfEachSource() {
    #expect(LogOrigin.of("stack.caddy") == .web)
    #expect(LogOrigin.of("stack.php-8-4") == .php)
    #expect(LogOrigin.of("stack.redis") == .services)
    #expect(LogOrigin.of("tienda.vite") == .projects)
    #expect(LogOrigin.of("share.tienda") == .projects)
    #expect(LogOrigin.of(LogsBrowser.vaultSource) == .vault)
}

@Test func logLevelsReadTheLine() {
    let error = "[2026-11-13 10:00:00] production.ERROR: falló la cola"
    let warning = "PHP Warning:  Undefined variable $x"
    let info = "GET /index.php 200"
    #expect(LogLevel.all.admits(info))
    #expect(LogLevel.errors.admits(error) && !LogLevel.errors.admits(warning) && !LogLevel.errors.admits(info))
    #expect(LogLevel.warnings.admits(error) && LogLevel.warnings.admits(warning) && !LogLevel.warnings.admits(info))
}

@Test @MainActor func showingLogsOpensRegistrosFilteredOnTheSource() {
    let store = StackStore()
    store.showLogs("stack.redis")
    #expect(store.route == .tool("logs"))
    #expect(LogsBrowser.shared.origin == .services && LogsBrowser.shared.selection == "stack.redis")
    // The source asked for is listed even when the supervisor does not run it now.
    #expect(LogsBrowser.shared.groups(store).flatMap(\.sources) == ["stack.redis"])

    // A link: butakestack://tool/logs?origin=web.
    store.handle(URL(string: "butakestack://tool/logs?origin=web")!)
    #expect(store.route == .tool("logs") && LogsBrowser.shared.origin == .web && LogsBrowser.shared.selection == nil)
    store.handle(URL(string: "butakestack://tool/logs?source=stack.php-8-4")!)
    #expect(LogsBrowser.shared.origin == .php && LogsBrowser.shared.selection == "stack.php-8-4")
    LogsBrowser.shared.origin = nil
    LogsBrowser.shared.selection = nil
}

@Test @MainActor func clearingAndPausingOnlyChangeWhatIsOnScreen() {
    let store = StackStore()
    let browser = LogsBrowser()
    store.logs["stack.caddy"] = ["uno", "dos"]
    browser.clear("stack.caddy", store: store)
    #expect(browser.lines(store, "stack.caddy").isEmpty)
    store.logs["stack.caddy"] = ["uno", "dos", "tres"]
    #expect(browser.lines(store, "stack.caddy") == ["tres"])
    browser.setPaused("stack.caddy", true, store: store)
    store.logs["stack.caddy"] = ["uno", "dos", "tres", "cuatro"]
    #expect(browser.lines(store, "stack.caddy") == ["tres"])
    browser.setPaused("stack.caddy", false, store: store)
    #expect(browser.lines(store, "stack.caddy") == ["tres", "cuatro"])
    #expect(store.logs["stack.caddy"]?.count == 4)
}

@Test @MainActor func everyToolWithAListUsesTheContentColumn() {
    for id in ["database-client", "mail", "dumps", "logs", "vault"] { #expect(Route.tool(id).hasContentColumn) }
    #expect(!Route.home.hasContentColumn)
}

/// GitHub's limit and the network say what they are, and a tool whose source did not answer says
/// why (or the version known from before, with its age).
@Test func sourcesThatDoNotAnswerSayWhy() throws {
    let limited = EngineFailure(code: "source_rate_limited:12")
    #expect(limited.code == "source_rate_limited" && limited.detail == "12")
    #expect(limited.errorDescription?.contains("12") == true && limited.errorDescription?.contains("GitHub") == true)
    #expect(EngineFailure(code: "download_offline").errorDescription == L("error.download_offline"))
    let json = """
    {"gh": {"installed": "", "latest": "2.80.0", "update": false},
     "codex": {"installed": "", "latest": "0.58.0", "update": false},
     "python": {}, "unavailable": {"uv": "source_rate_limited:30", "codex": "download_offline"},
     "known": {"codex": 1700000000}}
    """
    let updates = try JSONDecoder().decode(DevUpdates.self, from: Data(json.utf8))
    #expect(updates.tools.keys.sorted() == ["codex", "gh"])
    #expect(updates.unknownReason("uv")?.contains("30") == true)
    #expect(updates.unknownReason("codex") == nil && updates.unknownReason("gh") == nil)
    let note = try #require(updates.knownNote("codex", now: Date(timeIntervalSince1970: 1_700_000_000 + 3 * 3600)))
    #expect(note.contains("0.58.0") && note.contains("3"))
    #expect(updates.knownNote("gh") == nil)
}

/// What an install's sheet shows from the engine's reading of its log: the current step, a
/// measured download, and «Cancelar» off while what was checked is placed.
@MainActor @Test func installProgressFollowsTheEngine() throws {
    let monitor = InstallMonitor(log: "devtool-git", tool: "git")
    monitor.plan = ["downloadSource", "verifySum", "build", "install", "link"]
    monitor.phase = .running
    let json = #"{"steps": ["downloadSource"], "fixed": false, "bytes": {"done": 25, "total": 100}, "lines": ["descargando"]}"#
    monitor.apply(try JSONDecoder().decode(InstallProgress.self, from: Data(json.utf8)))
    #expect(monitor.current == 0 && monitor.fraction == 0.25 && monitor.canCancel)
    #expect(monitor.bytesText?.contains("25") == true)
    let building = #"{"steps": ["downloadSource", "verifySum", "build"], "fixed": false, "bytes": null, "lines": ["CC a.o"]}"#
    monitor.apply(try JSONDecoder().decode(InstallProgress.self, from: Data(building.utf8)))
    #expect(monitor.current == 2 && monitor.fraction == nil && monitor.currentTitle == L("progress.step.build"))
    let placing = #"{"steps": ["downloadSource", "verifySum", "build", "install"], "fixed": true, "bytes": null, "lines": []}"#
    monitor.apply(try JSONDecoder().decode(InstallProgress.self, from: Data(placing.utf8)))
    #expect(!monitor.canCancel)
    monitor.phase = .done
    #expect(monitor.current == 5 && monitor.finished)
    #expect(InstallMonitor.cancelled(CancellationError()))
    #expect(InstallMonitor.cancelled(EngineFailure(code: "install_cancelled", messageKey: "error.install_cancelled")))
}

/// An official installer's step (rustup, swiftly, sdkmanager) is not cut: «Cancelar» is off from
/// the start when the plan begins with one, and says why; a download before it can be stopped.
@MainActor @Test func officialInstallersAreNotCut() throws {
    let toolchain = InstallMonitor(log: "install-rust-toolchain", tool: "rust-toolchain")
    toolchain.plan = ["toolchain"]
    toolchain.phase = .running
    #expect(!toolchain.canCancel && toolchain.cancelHelp == L("progress.cantCancelExternal"))
    let rustup = InstallMonitor(log: "devtool-rustup", tool: "rustup")
    rustup.plan = ["download", "verifySum", "runInstaller"]
    rustup.phase = .running
    #expect(rustup.canCancel && rustup.cancelHelp.isEmpty)
    let json = #"{"steps": ["download", "verifySum", "runInstaller"], "fixed": true, "bytes": null, "lines": []}"#
    rustup.apply(try JSONDecoder().decode(InstallProgress.self, from: Data(json.utf8)))
    #expect(!rustup.canCancel && rustup.cancelHelp == L("progress.cantCancelExternal"))
    let placing = InstallMonitor(log: "install-php", tool: "php")
    placing.plan = ["download", "verifySum", "install"]
    placing.phase = .running
    placing.reported = placing.plan
    placing.fixed = true
    #expect(placing.cancelHelp == L("progress.cantCancel"))
}
