import Foundation
import Testing
@testable import ButakeStack

// Correo and Dumps: what the engine sends decodes as the pages read it, their searches, and the
// limits of «Opciones…». Made-up messages and dumps only.

private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try JSONDecoder().decode(T.self, from: Data(json.utf8))
}

/// A message as `mailGet` answers it, and the inbox's search by sender, recipient or subject.
@Test @MainActor func mailDecodesAndSearchesByWhoAndWhat() throws {
    let message = try decode(MailMessage.self, """
    {"id": "m1", "from": "tienda@ejemplo.test", "to": "ana@ejemplo.test", "cc": "", "subject": "Tu pedido",
     "date": "Fri, 14 Nov 2026 10:00:00 -0300", "received": 1794600000, "size": 512, "text": "Hola", "html": null,
     "attachments": [{"index": 0, "name": "boleta.pdf", "type": "application/pdf", "size": 2048}],
     "headers": [["Subject", "Tu pedido"]], "source": "Subject: Tu pedido"}
    """)
    #expect(message.attachments.first?.id == 0 && message.html == nil && message.headers.first == ["Subject", "Tu pedido"])
    let inbox = [
        MailSummary(id: "a", from: "tienda@ejemplo.test", to: "ana@ejemplo.test", subject: "Tu pedido", date: "", received: 2, size: 1),
        MailSummary(id: "b", from: "avisos@ejemplo.test", to: "luis@ejemplo.test", subject: "Contraseña nueva", date: "", received: 1, size: 1),
    ]
    let browser = MailBrowser()
    #expect(browser.visible(inbox).map(\.id) == ["a", "b"])
    browser.search = "  LUIS "
    #expect(browser.visible(inbox).map(\.id) == ["b"])
    browser.search = "pedido"
    #expect(browser.visible(inbox).map(\.id) == ["a"])
    browser.search = "nadie"
    #expect(browser.visible(inbox).isEmpty)
}

/// Dumps search their text, where they were called and where from; paused, the list stays.
@Test @MainActor func dumpsSearchTextPlaceAndOriginAndPauseKeepsTheList() throws {
    let dumps = try decode([DumpEntry].self, """
    [{"id": 2, "lines": ["array:1 [", "  \\"total\\" => 3", "]"], "time": 1794600000.5,
      "source": {"name": "PedidoController.php", "file": "/qa/tienda/app/PedidoController.php", "line": 42}, "origin": "GET /pedidos"},
     {"id": 1, "lines": ["\\"hola\\""], "time": null, "source": null, "origin": "artisan cola:trabajar"}]
    """)
    #expect(dumps[0].place == "PedidoController.php:42" && dumps[1].place == nil)
    let store = StackStore()
    store.dumps = dumps
    let browser = DumpsBrowser()
    for (search, ids) in [("total", [2]), ("pedidocontroller", [2]), ("artisan", [1]), ("", [2, 1]), ("nada", [])] {
        browser.search = search
        #expect(browser.visible(store).map(\.id) == ids, "\(search)")
    }
    browser.frozen = [dumps[1]]
    store.dumps = dumps + [DumpEntry(id: 3, lines: ["nuevo"], time: nil, source: nil, origin: nil)]
    browser.search = ""
    #expect(browser.entries(store).map(\.id) == [1])
}

/// The receivers' settings come with their own names from stack.json, and «Opciones…» only
/// offers what the engine accepts (`StackConfig::validate`).
@Test func receiverSettingsDecodeAndKeepTheEngineLimits() throws {
    let config = try decode(StackConfig.self, """
    {"tld": ["test"], "ports": {"http": 80, "https": 443, "dns": 53, "mysql": 3306, "redis": 6379}, "versions": {},
     "mail": {"enabled": true, "port": 2526, "retention_days": 30, "max_messages": 1000},
     "dumps": {"enabled": false, "port": 9913}}
    """)
    #expect(config.mail?.port == 2526 && config.mail?.retentionDays == 30 && config.mail?.maxMessages == 1000)
    #expect(config.dumps?.port == 9913 && config.dumps?.retentionDays == nil)
    #expect(ReceiverOptions.valid(port: 1024) && ReceiverOptions.valid(port: 65535))
    #expect(!ReceiverOptions.valid(port: 1023) && !ReceiverOptions.valid(port: 0) && !ReceiverOptions.valid(port: 70000))
    #expect(ReceiverOptions.days == 1...365 && ReceiverOptions.messages.upperBound == 10_000)
    #expect(ReceiverOptions.defaultPort("mail") == 2525 && ReceiverOptions.defaultPort("dumps") == 9912)
}

/// Off, the engine refuses every method of Correo and Dumps, the ones of «Opciones…» included.
@Test func receiverMethodsNeedTheirToolOn() async throws {
    let engine = StackEngine()
    for method in ["mailChanges", "mailGet", "mailDelete", "dumpsClear", "setMail", "setDumps"] {
        do {
            let _: JSONValue = try await engine.call(["method": method, "id": "x", "port": 2526])
            Issue.record("\(method) answered while off")
        } catch let failure as EngineFailure {
            #expect(failure.code == "plugin_disabled", "\(method)")
        }
    }
}
