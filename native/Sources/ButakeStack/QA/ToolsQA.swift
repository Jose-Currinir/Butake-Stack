#if DEBUG
import Foundation

/// Screenshots of Dumps and Registros with content, without a supervisor (debug builds with
/// BUTAKE_QA_WINDOW and a separate BUTAKE_STACK_HOME). Correo needs no hook: its messages are files
/// of the store, written there by the capture script like the local SMTP server does.
///
///     BUTAKE_QA_DUMPS=1                  three made-up dumps (the newest selected)
///     BUTAKE_QA_LOGS=<proceso>|vault     a supervisor that answers with a web server, PHP-FPM, a
///                                        search service and a project's process (no database
///                                        service: nothing reaches the Keychain), made-up lines, and
///                                        Registros filtered on that source as a service row opens it
///     BUTAKE_QA_LOGS_ORIGIN=<origen>     the origin filter instead (web, php, services, projects, vault)
///     BUTAKE_QA_LOGS_LEVEL=<nivel>       warnings or errors
///     BUTAKE_QA_LOGS_SEARCH=<texto>      search of the list of sources
///     BUTAKE_QA_RECEIVER_OPTIONS=mail|dumps  the «Opciones…» sheet of Correo or Dumps, open
@MainActor enum ToolsQA {
    private static var env: [String: String] { ProcessInfo.processInfo.environment }
    private static func value(_ name: String) -> String? { StackStore.qaWindow && env["BUTAKE_STACK_HOME"] != nil ? env[name] : nil }

    /// The tool whose «Opciones…» sheet opens by itself.
    static var receiverOptions: String? { value("BUTAKE_QA_RECEIVER_OPTIONS") }

    static func start() {
        if value("BUTAKE_QA_DUMPS") != nil {
            Task {
                try? await Task.sleep(for: .seconds(2.5))
                StackStore.shared.dumps = dumps
            }
        }
        if let source = value("BUTAKE_QA_LOGS") {
            Task {
                try? await Task.sleep(for: .seconds(1.6))
                let store = StackStore.shared
                for (id, lines) in logs { store.logs[id] = lines }
                store.showLogs(source == "vault" ? LogsBrowser.vaultSource : source)
                let browser = LogsBrowser.shared
                if let origin = value("BUTAKE_QA_LOGS_ORIGIN").flatMap(LogOrigin.init(rawValue:)) { browser.origin = origin }
                if let level = value("BUTAKE_QA_LOGS_LEVEL").flatMap(LogLevel.init(rawValue:)) { browser.level = level }
                if let search = value("BUTAKE_QA_LOGS_SEARCH") { browser.search = search }
                // The stream of the missing supervisor never answers; the lines stay as written.
                try? await Task.sleep(for: .seconds(1))
                for (id, lines) in logs where store.logs[id] != lines { store.logs[id] = lines }
            }
        }
    }

    /// The supervisor's answer while BUTAKE_QA_LOGS is set.
    static var simulatedStatus: StackStatus? {
        guard value("BUTAKE_QA_LOGS") != nil else { return nil }
        func process(_ id: String, _ state: String) -> String {
            #"{"spec":{"id":"\#(id)","executable":"","args":[],"autostart":true},"status":{"id":"\#(id)","state":"\#(state)","pid":1,"restarts":0}}"#
        }
        let processes = [("stack.caddy", "running"), ("stack.php-8-4", "running"), ("stack.meilisearch", "crashed"), ("qa.vite", "running")]
        let json = #"{"listeners":{},"processes":[\#(processes.map(process).joined(separator: ","))]}"#
        return try? JSONDecoder().decode(StackStatus.self, from: Data(json.utf8))
    }

    private static let logs: [String: [String]] = [
        "stack.caddy": [
            #"{"level":"info","ts":"2026-11-13T10:00:01Z","msg":"serving initial configuration"}"#,
            #"{"level":"info","ts":"2026-11-13T10:00:02Z","logger":"tls","msg":"certificate obtained","identifier":"qa.test"}"#,
            #"{"level":"warn","ts":"2026-11-13T10:02:13Z","msg":"upstream slow","upstream":"127.0.0.1:5173","duration":2.4}"#,
            #"{"level":"error","ts":"2026-11-13T10:03:40Z","msg":"dial tcp 127.0.0.1:5173: connection refused"}"#,
            #"{"level":"info","ts":"2026-11-13T10:04:00Z","msg":"handled request","uri":"/","status":200}"#,
        ],
        "stack.php-8-4": [
            "[13-Nov-2026 10:00:01] NOTICE: fpm is running, pid 4242",
            "[13-Nov-2026 10:00:01] NOTICE: ready to handle connections",
            "[13-Nov-2026 10:05:12] WARNING: [pool www] server reached pm.max_children setting (5)",
            "[13-Nov-2026 10:06:30] PHP Fatal error:  Uncaught Error: Call to undefined function foo() in /qa/index.php:3",
        ],
        "stack.meilisearch": [
            "2026-11-13T10:00:01Z INFO  meilisearch: starting",
            "2026-11-13T10:00:02Z ERROR meilisearch: address already in use (127.0.0.1:7700)",
        ],
        "qa.vite": [
            "  VITE v6.0.0  ready in 312 ms",
            "  ➜  Local:   http://localhost:5173/",
            "10:04:12 [vite] hmr update /src/App.vue",
        ],
    ]

    private static var dumps: [DumpEntry] {
        let json = #"""
        [{"id":3,"lines":["array:3 [","  \"id\" => 42","  \"nombre\" => \"Producto sintético\"","  \"precio\" => 1990","]"],"time":1763028250,
          "source":{"name":"ProductController.php","file":"/qa/app/Http/Controllers/ProductController.php","line":28},"origin":"GET http://qa.test/productos/42"},
         {"id":2,"lines":["\"Hola desde la cola\""],"time":1763028190,
          "source":{"name":"EnviarCorreo.php","file":"/qa/app/Jobs/EnviarCorreo.php","line":17},"origin":"php artisan queue:work"},
         {"id":1,"lines":["true"],"time":1763028100,"source":null,"origin":null}]
        """#
        return (try? JSONDecoder().decode([DumpEntry].self, from: Data(json.utf8))) ?? []
    }
}
#endif
