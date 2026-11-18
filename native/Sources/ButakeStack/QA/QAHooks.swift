#if DEBUG
import AppKit
import SwiftUI

/// Hooks for QA and screenshots: debug builds with BUTAKE_QA_WINDOW only. Every BUTAKE_QA_*
/// variable (except the vault's, in VaultQA.swift) is read here; each screen makes one call.
@MainActor enum QAHooks {
    static var env: [String: String] { ProcessInfo.processInfo.environment }
    /// A variable's value, only while the QA window is on.
    static func value(_ name: String) -> String? { StackStore.qaWindow ? env[name] : nil }

    /// The menu bar panel opened as a window (BUTAKE_QA_PANEL).
    static var panel: NSWindow?

    // MARK: App

    /// At launch: setup assistant, new project, route, panel, window size, snapshot, vault, folder.
    static func appDidLaunch() {
        guard StackStore.qaWindow else { return }
        let env = Self.env
        // Only the menu dump takes the focus (its menus need a key window): screenshots never take
        // the keyboard from whoever is using the Mac.
        if env["BUTAKE_QA_MENUS"] != nil {
            Task {
                try? await Task.sleep(for: .seconds(1))
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        // BUTAKE_QA_REPORT: Ayuda › «Informar de un problema…» with two invented failures in the session.
        if env["BUTAKE_QA_REPORT"] != nil {
            Task {
                try? await Task.sleep(for: .seconds(2))
                let store = StackStore.shared
                store.report(EngineFailure(code: "port_in_use", messageKey: "error.port_in_use", detail: "puerto 5432 ocupado; token=ghp_InventadoParaLaCapturaDeEjemplo0123456789"))
                store.report(EngineFailure(code: "folder_missing", messageKey: "error.folder_missing", detail: "\(NSHomeDirectory())/Stack/Projects/demo"))
                store.dismissFailure()
                store.showReport = true
            }
        }
        if let setup = env["BUTAKE_QA_SETUP"] {
            Task {
                try? await Task.sleep(for: .seconds(2))
                StackStore.shared.showSetup = true
                // BUTAKE_QA_SETUP=3end: the last step scrolled to its end.
                guard setup.hasSuffix("end") else { return }
                try? await Task.sleep(for: .seconds(1.2))
                func scrolls(_ view: NSView) -> [NSScrollView] { ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(scrolls) }
                let sheet = NSApp.windows.first { $0.isVisible && $0.identifier?.rawValue.hasPrefix("main") == true }?.attachedSheet
                guard let scroll = sheet?.contentView.flatMap({ scrolls($0).max { $0.frame.height < $1.frame.height } }),
                      let document = scroll.documentView else { return }
                document.scroll(NSPoint(x: 0, y: document.isFlipped ? document.bounds.height : 0))
            }
        }
        if let kind = env["BUTAKE_QA_NEW"] {
            Task {
                try? await Task.sleep(for: .seconds(2))
                UserDefaults.standard.set(kind, forKey: "newProject.kind")
                StackStore.shared.showNewProject = true
            }
        }
        if let path = env["BUTAKE_QA_RESTORE"] { openRestore(path) }
        if env["BUTAKE_QA_DB_BACKUP"] != nil || env["BUTAKE_QA_DB_LOAD"] != nil {
            databaseBackup(dump: env["BUTAKE_QA_DB_BACKUP"], load: env["BUTAKE_QA_DB_LOAD"])
        }
        if env["BUTAKE_QA_PALETTE"] != nil {
            Task { try? await Task.sleep(for: .seconds(2)); StackStore.shared.showPalette = true }
        }
        if env["BUTAKE_QA_SHORTCUTS"] != nil {
            Task { try? await Task.sleep(for: .seconds(2)); StackStore.shared.showShortcuts = true }
        }
        if let language = env["BUTAKE_QA_LANGUAGE"] {
            Task { try? await Task.sleep(for: .seconds(1)); StackStore.shared.route = .language(language) }
        }
        // The sidebar scrolled to its end before the route changes, as a user does to reach the tools
        // under a long list of projects (BUTAKE_QA_SIDEBAR_END).
        if env["BUTAKE_QA_SIDEBAR_END"] != nil {
            Task {
                try? await Task.sleep(for: .seconds(1.3))
                guard let window = NSApp.windows.first(where: { $0.isVisible && $0.identifier?.rawValue.hasPrefix("main") == true }),
                      let outline = sidebarOutline(window) else { return }
                outline.scrollRowToVisible(outline.numberOfRows - 1)
                // The list holds the keyboard, as after a click on one of its rows. The window becomes
                // key inside the app only: the app is not activated and takes nothing from the user.
                window.makeKey()
                window.makeFirstResponder(outline)
            }
        }
        // Screenshots: "site:<id>", "service:<name>", "language:<name>", "tool:<id>" (logs included), "utilities[:<section>]" or
        // "home"; several joined by ">" change page one after another, a second apart (two and
        // three columns and back, without rebuilding the window).
        if let targets = env["BUTAKE_QA_ROUTE"]?.split(separator: ">").map(String.init) {
            // The proposal to order the sidebar by the disk's folders would cover the page in the demo store.
            if env["BUTAKE_QA_MIGRATION"] == nil { StackStore.shared.migrationDeferred = true }
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                for (index, target) in targets.enumerated() {
                    if index > 0 { try? await Task.sleep(for: .seconds(1)) }
                    let parts = target.split(separator: ":", maxSplits: 1).map(String.init)
                    let value = parts.count > 1 ? parts[1] : ""
                    switch parts[0] {
                    case "home": StackStore.shared.route = .home
                    case "site": StackStore.shared.openSite(value)
                    case "composite": StackStore.shared.openComposite(value)
                    case "service": StackStore.shared.route = .service(value)
                    case "language": StackStore.shared.route = .language(value)
                    case "tool": StackStore.shared.route = .tool(value)
                    case "utilities": StackStore.shared.route = UtilityCatalog.group(value) == nil ? UtilityCatalog.route() : .utilities(value)
                    case "toggleSidebar":
                        // The sidebar's button, without a click: the split view's own action.
                        func splits(_ view: NSView) -> [NSSplitView] { (view as? NSSplitView).map { [$0] } ?? view.subviews.flatMap(splits) }
                        let window = NSApp.windows.first { $0.isVisible && $0.identifier?.rawValue.hasPrefix("main") == true }
                        (window?.contentView.flatMap { splits($0).first }?.delegate as? NSSplitViewController)?.toggleSidebar(nil)
                    default: break
                    }
                }
            }
        }
        // Ajustes on a tab: BUTAKE_QA_SETTINGS=<general|appearance|network|tools|keys|advanced>, with
        // BUTAKE_QA_SETTINGS_TOOL=<id> for the highlighted row of Herramientas. The snapshot takes
        // the Settings window instead of the main one.
        if let tab = env["BUTAKE_QA_SETTINGS"].flatMap(SettingsTab.init(rawValue:)) {
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                SettingsRouter.shared.open(tab, tool: env["BUTAKE_QA_SETTINGS_TOOL"])
            }
        }
        // Screenshots of the menu bar panel, which otherwise only opens from the menu bar.
        if env["BUTAKE_QA_PANEL"] != nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 600), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Panel"
            window.contentView = NSHostingView(rootView: MenuPanel(store: StackStore.shared))
            window.setContentSize(window.contentView?.fittingSize ?? NSSize(width: 340, height: 600))
            window.center()
            window.makeKeyAndOrderFront(nil)
            panel = window
        }
        // The standard About panel, captured instead of the main window (BUTAKE_QA_ABOUT).
        if env["BUTAKE_QA_ABOUT"] != nil {
            Task {
                try? await Task.sleep(for: .seconds(2))
                NSApp.orderFrontStandardAboutPanel(nil)
                panel = NSApp.windows.first { $0.isVisible && $0 is NSPanel }
            }
        }
        // The activation policy without a window: the main window closes after this many seconds.
        if let seconds = env["BUTAKE_QA_CLOSE_WINDOW"].flatMap(Double.init) {
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                NSApp.windows.first { $0.isVisible && $0.identifier?.rawValue.hasPrefix("main") == true }?.performClose(nil)
            }
        }
        // A tall window: BUTAKE_QA_WINDOW_SIZE=<width>x<height>, or "screen" for the whole visible
        // screen, as the green button leaves it (wins over the minimum).
        if let size = env["BUTAKE_QA_WINDOW_SIZE"] {
            Task {
                try? await Task.sleep(for: .seconds(1.2))
                if let window = mainWindow { resize(window, to: size) }
            }
        } else if env["BUTAKE_QA_MINIMUM_WINDOW"] == "1" {
            Task {
                try? await Task.sleep(for: .seconds(1))
                if let window = mainWindow { resize(window, to: "minimum") }
            }
        }
        // Screenshots without screen recording permission: the window draws itself into a PNG.
        // BUTAKE_QA_SIZES=minimum,normal,screen takes one per size in the same window, resized as a
        // user would ("{size}" in the path is replaced by each one).
        if let path = env["BUTAKE_QA_SNAPSHOT"] {
            Task {
                try? await Task.sleep(for: .seconds(Double(env["BUTAKE_QA_SNAPSHOT_DELAY"] ?? "") ?? 6))
                let sizes = env["BUTAKE_QA_SIZES"]?.split(separator: ",").map(String.init) ?? [""]
                for (index, size) in sizes.enumerated() {
                    if !size.isEmpty, let window = mainWindow, env["BUTAKE_QA_SETTINGS"] == nil, panel == nil {
                        if index > 0 || env["BUTAKE_QA_WINDOW_SIZE"] != nil || size != "minimum" { resize(window, to: size) }
                        if index > 0 || size != "minimum" { try? await Task.sleep(for: .seconds(1.5)) }
                    }
                    snapshot(to: path.replacingOccurrences(of: "{size}", with: size))
                }
            }
        }
        // A change of theme while the window is open: BUTAKE_QA_THEME_SWITCH=<family>:<mode>.
        if let target = env["BUTAKE_QA_THEME_SWITCH"]?.split(separator: ":").map(String.init), target.count == 2 {
            Task {
                try? await Task.sleep(for: .seconds(2.5))
                if let family = ThemeStore.Family(rawValue: target[0]) { ThemeStore.shared.family = family }
                if let mode = ThemeStore.Mode(rawValue: target[1]) { ThemeStore.shared.mode = mode }
            }
        }
        if let path = env["BUTAKE_QA_MENUS"] {
            Task {
                try? await Task.sleep(for: .seconds(Double(env["BUTAKE_QA_SNAPSHOT_DELAY"] ?? "") ?? 4))
                try? menuOutline().write(toFile: path, atomically: true, encoding: .utf8)
            }
        }
        if env["BUTAKE_QA_VAULT"] != nil { Task { await VaultQA.start() } }
        RenameQA.start()
        // Dumps and Registros with content (ToolsQA.swift).
        ToolsQA.start()
        // The Git pieces with made-up data (GitPiecesQA.swift).
        GitPiecesQA.start()
        // The context menu of a folder and of a project of several parts, as text.
        groupMenus()
        if let folder = env["BUTAKE_QA_OPEN_FOLDER"] {
            Task { try? await Task.sleep(for: .seconds(2)); await StackStore.shared.openFolder(folder, scan: true) }
        }
    }

    /// The main window (not Ajustes, a panel or a sheet).
    static var mainWindow: NSWindow? { NSApp.windows.first { $0.isVisible && $0.identifier?.rawValue.hasPrefix("main") == true } }

    /// The sizes of the layout sweep: the window's minimum, a usual one and the whole screen.
    static func resize(_ window: NSWindow, to size: String) {
        let parts = size.split(separator: "x").compactMap { Double($0) }
        switch size {
        case "minimum": window.setContentSize(NSSize(width: 960, height: 600))
        case "normal": window.setContentSize(NSSize(width: 1280, height: 800))
        case "screen": if let screen = window.screen { window.setFrame(screen.visibleFrame, display: true) }
        default: if parts.count == 2 { window.setContentSize(NSSize(width: parts[0], height: parts[1])) }
        }
    }

    /// The window on screen (the menu bar panel, Ajustes or the main one, with its sheet) into a PNG,
    /// with its layout report in the log first.
    static func snapshot(to path: String) {
        let env = Self.env
        let settings = env["BUTAKE_QA_SETTINGS"] == nil ? nil : NSApp.windows.first { $0.isVisible && $0.identifier?.rawValue.localizedCaseInsensitiveContains("settings") == true }
        guard let main = panel ?? settings ?? mainWindow,
              case let window = main.attachedSheet.map({ $0.attachedSheet ?? $0 }) ?? main,
              // A process may capture its own windows; the symbol is looked up at run time
              // because newer SDKs hide it (debug QA only).
              let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return }
        print("QA snapshot:", (path as NSString).lastPathComponent)
        print(layoutReport(main))
        print(textReport(main))
        print("QA windows:", NSApp.windows.filter(\.isVisible).map { "\($0.identifier?.rawValue ?? "-") \(Int($0.frame.width))x\(Int($0.frame.height))" }.joined(separator: ", "))
        fflush(stdout)
        typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        let capture = unsafeBitCast(symbol, to: Capture.self)
        guard let image = capture(.null, 1 << 3, UInt32(window.windowNumber), 1 << 0)?.takeRetainedValue() else {
            // A dialog over a sheet is not captured by the window server: it draws itself instead.
            guard let view = window.contentView?.superview ?? window.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            return
        }
        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    // MARK: Sidebar

    /// Text the sidebar's search starts with (BUTAKE_QA_SEARCH).
    static var sidebarSearch: String? { value("BUTAKE_QA_SEARCH") }

    /// Text Inicio's filter and Registros' line filter start with (BUTAKE_QA_HOME_FILTER, BUTAKE_QA_LOG_FILTER).
    static var homeFilter: String? { value("BUTAKE_QA_HOME_FILTER") }
    static var logFilter: String? { value("BUTAKE_QA_LOG_FILTER") }

    // MARK: Utilities

    /// The confirmation to install this utility, open on the Utilidades page (BUTAKE_QA_UTILITY_SHEET).
    static func opensUtilitySheet(_ tool: String) async -> Bool {
        guard value("BUTAKE_QA_UTILITY_SHEET") == tool else { return false }
        try? await Task.sleep(for: .seconds(2))
        return true
    }

    /// The section of the sidebar that can close ("sites", `SidebarLayout.collapsible`) or a folder
    /// of projects ("folder:<id>") closed through its own binding after the route is on screen, and
    /// open again a second later with ":reopen" (BUTAKE_QA_SIDEBAR_COLLAPSE).
    static func sidebarCollapse(_ toggle: (String, Bool) -> Void) async {
        guard let value = value("BUTAKE_QA_SIDEBAR_COLLAPSE") else { return }
        let reopen = value.hasSuffix(":reopen")
        let target = reopen ? String(value.dropLast(":reopen".count)) : value
        try? await Task.sleep(for: .seconds(2.2))
        // The list holds the keyboard, as after a click on its row: the selection is drawn in the
        // accent color. The window becomes key inside the app only; the app is not activated.
        if let window = NSApp.windows.first(where: { $0.isVisible && $0.identifier?.rawValue.hasPrefix("main") == true }),
           let outline = sidebarOutline(window) {
            window.makeKey()
            window.makeFirstResponder(outline)
        }
        toggle(target, false)
        guard reopen else { return }
        try? await Task.sleep(for: .seconds(1.2))
        toggle(target, true)
    }

    // MARK: Activation policy

    /// Each change of the activation policy, in the QA log (proof that sheets and panels change nothing).
    static func activationChanged(_ policy: NSApplication.ActivationPolicy) {
        guard StackStore.qaWindow else { return }
        print("QA activation:", policy == .regular ? "regular" : policy == .accessory ? "accessory" : "prohibited")
        fflush(stdout)
    }

    // MARK: Setup assistant

    /// The step the assistant opens on: BUTAKE_QA_SETUP=<1|2|3>[end] (1 is the welcome).
    static var setupStep: Int? { value("BUTAKE_QA_SETUP").flatMap { Int($0.prefix(1)) }.map { $0 - 1 } }

    // MARK: Stack's state

    /// «Estado» opens by itself and the snapshot takes it (BUTAKE_QA_STATE_POPOVER). Only the status
    /// bar's indicator opens it: the menu bar panel is not on screen in that capture.
    static func opensStatePopover() async -> Bool {
        guard value("BUTAKE_QA_STATE_POPOVER") != nil, panel == nil else { return false }
        try? await Task.sleep(for: .seconds(2))
        Task {
            try? await Task.sleep(for: .seconds(1))
            panel = NSApp.windows.first { $0.isVisible && String(describing: type(of: $0)).contains("Popover") }
        }
        return true
    }

    /// A simulated stack for screenshots of Inicio (BUTAKE_QA_STACK=stopped|running, and more running
    /// process ids in BUTAKE_QA_STACK_PROCESSES, comma separated): the setup counts
    /// as done and, when running, the supervisor answers with a few services. The QA store never
    /// starts a supervisor, and these screenshots never touch the real one.
    static var simulatesStack: Bool { value("BUTAKE_QA_STACK") != nil }
    /// BUTAKE_QA_STACK=reconnecting: the supervisor does not answer and the bar shows «Reconectando…».
    static var simulatesReconnecting: Bool { value("BUTAKE_QA_STACK") == "reconnecting" }
    /// Every site answers 200 (BUTAKE_QA_SITES_ONLINE): presentation screenshots with sites online.
    static var simulatesSitesOnline: Bool { value("BUTAKE_QA_SITES_ONLINE") != nil }
    static var simulatedStatus: StackStatus? {
        if let logs = ToolsQA.simulatedStatus { return logs }
        guard value("BUTAKE_QA_STACK") == "running" else { return nil }
        func process(_ id: String) -> String {
            #"{"spec":{"id":"\#(id)","executable":"","args":[],"autostart":true},"status":{"id":"\#(id)","state":"running","pid":1,"restarts":0}}"#
        }
        let listeners = ["dns": 53, "http": 80, "https": 443].map { #""\#($0.key)":{"port":\#($0.value),"mode":"agent","owner":null}"# }
        let json = #"{"listeners":{\#(listeners.joined(separator: ","))},"processes":[\#((["stack.caddy", "stack.php-8-4", "stack.mysql"] + (value("BUTAKE_QA_STACK_PROCESSES")?.split(separator: ",").map(String.init) ?? [])).map(process).joined(separator: ","))]}"#
        return try? JSONDecoder().decode(StackStatus.self, from: Data(json.utf8))
    }

    // MARK: Menu bar panel


    // MARK: Database client

    /// BUTAKE_QA_DB_SHEET: the sheet a screenshot wants (and "disconnected" for the connection).
    static var databaseSheet: String? { value("BUTAKE_QA_DB_SHEET") }
    /// The panel tab a screenshot wants (BUTAKE_QA_DB_TAB).
    static var databaseTab: String? { value("BUTAKE_QA_DB_TAB") }
    /// The table whose relations the diagram highlights (BUTAKE_QA_DB_DIAGRAM_FOCUS).
    static var diagramFocus: String? { value("BUTAKE_QA_DB_DIAGRAM_FOCUS") }
    /// SQL text the editor starts with (BUTAKE_QA_DB_SQL).
    static var databaseSQL: String? { value("BUTAKE_QA_DB_SQL") }

    /// Screenshots: BUTAKE_QA_DB="connection[/database[/schema.table]]".
    static func databaseSelection() -> (selection: DBSelection, disconnected: Bool)? {
        guard let preset = value("BUTAKE_QA_DB") else { return nil }
        let parts = preset.split(separator: "/", maxSplits: 2).map(String.init)
        let table = parts[safe: 2].map { $0.split(separator: ".", maxSplits: 1).map(String.init) }
        let selection = DBSelection(connection: parts[0], database: parts[safe: 1],
                                    schema: table.flatMap { $0.count == 2 ? $0[0] : nil }, table: table?.last)
        return (selection, env["BUTAKE_QA_DB_SHEET"] == "disconnected")
    }

    /// Screenshots: BUTAKE_QA_DB_GRID="col:op:value|or:col:op:value;sort:col:desc,col".
    static func databaseGrid() -> (filters: [[String: String]], sorts: [(column: String, descending: Bool)])? {
        guard let preset = value("BUTAKE_QA_DB_GRID") else { return nil }
        var filters: [[String: String]] = []
        var sorts: [(column: String, descending: Bool)] = []
        let halves = preset.components(separatedBy: ";sort:")
        for part in halves[0].split(separator: "|").map(String.init) where !part.isEmpty {
            var bits = part.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            let join = bits.first == "or" || bits.first == "and" ? bits.removeFirst() : "and"
            filters.append(["column": bits[safe: 0] ?? "", "op": bits[safe: 1] ?? "eq", "value": bits[safe: 2] ?? "", "join": filters.isEmpty ? "and" : join])
        }
        for item in (halves[safe: 1] ?? "").split(separator: ",") {
            let bits = item.split(separator: ":").map(String.init)
            sorts.append((bits[0], bits[safe: 1] == "desc"))
        }
        return (filters, sorts)
    }

    /// Screenshots: open a transaction, run or explain the SQL right away.
    static func databaseQueryActions(inTransaction: Bool, begin: () async -> Void, run: () async -> Void, explain: () async -> Void) async {
        guard StackStore.qaWindow else { return }
        if env["BUTAKE_QA_DB_TX"] != nil, !inTransaction { await begin() }
        if env["BUTAKE_QA_DB_SQL_RUN"] != nil { await run() }
        if env["BUTAKE_QA_DB_SQL_EXPLAIN"] != nil { await explain() }
    }

    /// Screenshots of the client's sheets: the confirmation of a change (production asks for its
    /// name) and the connection editor.
    static func databaseClientSheets(_ client: DatabaseClient) {
        let sheet = databaseSheet
        if sheet == "confirm", let connection = client.connection {
            Task {
                try? await Task.sleep(for: .seconds(1))
                _ = await client.askTyped(String(format: L("db.confirm.sql"), connection.title), ["DELETE FROM t WHERE id = 1"], typedName: nil,
                                          typedConnection: connection.production ? connection.name : nil)
            }
        }
        seedPendingEdits(client)
        if sheet == "connection" {
            client.editing = DBConnection(id: "", name: "Producción", kind: "postgres", host: "db.interna", port: 5432, user: "app", database: "app",
                                          ssh: DBConnection.SSH(host: "bastion.ejemplo.cl", user: "deploy"))
        }
    }

    // MARK: Mail

    /// Screenshots: open the newest message (BUTAKE_QA_MAIL set).
    static var mailSelectsFirst: Bool { value("BUTAKE_QA_MAIL") != nil }
    /// The view of a message a screenshot wants (BUTAKE_QA_MAIL=<mode>).
    static var mailMode: String? { env["BUTAKE_QA_MAIL"] }

    // MARK: Tools

    /// Screenshots: the confirmation to delete a tool's data (BUTAKE_QA_PLUGIN_DELETE=<id>).
    static func pluginDelete(_ plugins: [ToolInfo]) -> ToolInfo? {
        guard let id = value("BUTAKE_QA_PLUGIN_DELETE") else { return nil }
        return plugins.first { $0.id == id }
    }

}

// MARK: Versions of languages and services

extension QAHooks {
    /// The version picker of a language or a service open at launch (BUTAKE_QA_VERSION_PICKER=<id>:
    /// php, python, node, jdk, mysql…). It only shows the catalog; nothing is installed.
    static var versionPicker: String? { value("BUTAKE_QA_VERSION_PICKER") }
}
#endif
