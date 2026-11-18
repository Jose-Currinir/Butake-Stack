import Foundation
import Testing
@testable import ButakeStack

// Registros: clearing by position and the vault's log with the tool off.

@MainActor @Test func clearingRegistrosDoesNotHideNewLinesThatRepeatAnOldOne() {
    #expect(LogsBrowser.after(["x", "x"], in: ["x", "x", "x"]) == ["x"])
    #expect(LogsBrowser.after(["a", "b"], in: ["a", "b"]).isEmpty)
    #expect(LogsBrowser.after(["a", "b"], in: ["a", "b", "c"]) == ["c"])
    // The window slides as lines arrive.
    #expect(LogsBrowser.after(["a", "b", "c", "d"], in: ["c", "d", "e", "f"]) == ["e", "f"])
    // Past the window, or a log that started over: everything is new, nothing comes back from before.
    #expect(LogsBrowser.after(["a", "b"], in: ["x", "y", "z"]) == ["x", "y", "z"])
    #expect(LogsBrowser.after([], in: ["x"]) == ["x"])

    let store = StackStore()
    let browser = LogsBrowser()
    store.logs["stack.caddy"] = ["GET / 200", "GET / 200"]
    browser.clear("stack.caddy", store: store)
    store.logs["stack.caddy"] = ["GET / 200", "GET / 200", "GET / 200"]
    #expect(browser.lines(store, "stack.caddy") == ["GET / 200"])
}

@MainActor @Test func theVaultAccessLogIsNotAnOptionWhileTheVaultIsOff() {
    let store = StackStore()
    // The tools list is loaded and the vault is not in it as on: the vault is off.
    store.pluginsLoaded = true
    let browser = LogsBrowser()
    browser.show(LogsBrowser.vaultSource, vaultEnabled: false)
    #expect(browser.selection == nil && browser.origin == nil)
    browser.open([URLQueryItem(name: "source", value: LogsBrowser.vaultSource)], vaultEnabled: false)
    #expect(browser.selection == nil)
    // A selection left from when the tool was on is not listed any more.
    browser.selection = LogsBrowser.vaultSource
    #expect(!browser.groups(store).flatMap(\.sources).contains(LogsBrowser.vaultSource))
    browser.show(LogsBrowser.vaultSource, vaultEnabled: true)
    #expect(browser.selection == LogsBrowser.vaultSource && browser.origin == .vault)
}
