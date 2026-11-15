import AppKit
import SwiftUI

// MARK: - SQL editor

/// The SQL editor: several query tabs per connection (kept between launches), completion of
/// keywords, tables and columns, EXPLAIN, formatting, an optional manual transaction and the
/// result exported to a file. Ejecutar, Explicar, Formatear, Historial and Exportar are in the
/// toolbar; ⌘T opens a tab, ⌘W closes the one on screen and ⌃Tab moves to the next.
struct SQLPanel: View {
    @Bindable var client: DatabaseClient
    let connection: DBConnection
    let database: String
    /// Every tab of the connection (the ones of other databases stay as they are).
    @State private var allTabs: [QueryTab] = []
    @State private var current = ""
    @State private var text = ""
    @State private var selected = ""
    @State private var outputs: [String: DBRunOutput] = [:]
    @State private var plans: [String: DBPlan] = [:]
    @State private var showPlan = false
    @State private var resultIndex = 0
    @State private var running = false
    @State private var showHistory = false
    @State private var historyItems: [String] = []
    @State private var schema: DBSchema?
    @State private var saving: Task<Void, Never>?
    static let maxTabs = 30
    var tabs: [QueryTab] { allTabs.filter { $0.database == database } }
    var output: DBRunOutput? { outputs[current] }
    var inTransaction: Bool { client.inTransaction(connection, database) }
    var hasText: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var body: some View {
        VSplitView {
            VStack(spacing: 0) {
                tabBar
                Divider()
                SQLEditor(text: $text, selection: $selected, onRun: { Task { await run() } },
                          completions: connection.isSQL ? { prefix, qualifier in SQLCompletion.suggestions(prefix: prefix, qualifier: qualifier, schema: schema) } : nil)
                    .frame(minHeight: 120)
                    .overlay(alignment: .topLeading) {
                        if text.isEmpty {
                            Text(L(connection.isRedis ? "db.sql.placeholderRedis" : "db.sql.placeholder"))
                                .font(.uiMonospaced).foregroundStyle(.tertiary)
                                .padding(.leading, 11).padding(.top, 8).allowsHitTesting(false)
                        }
                    }
                    .overlay(alignment: .top) {
                        if inTransaction { Rectangle().fill(Brand.warning).frame(height: 2) }
                    }
                    .accessibilityIdentifier("db.sql.editor")
            }
            .frame(minHeight: 180)
            results.frame(minHeight: 160)
        }
        .toolbar { toolbar }
        .background { shortcuts }
        .task { await open() }
        .onChange(of: text) { _, value in
            guard let index = allTabs.firstIndex(where: { $0.id == current }), allTabs[index].sql != value else { return }
            allTabs[index].sql = value
            saveSoon()
        }
    }

    // MARK: Tabs

    var tabBar: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(tabs) { tab in QueryTabButton(tab: tab, current: tab.id == current, closable: tabs.count > 1, select: { select(tab.id) }, close: { close(tab.id) }) }
                }
                .padding(.vertical, 1)
            }
            Button { addTab(sql: "") } label: { Label(L("db.sql.newTab"), systemImage: Symbols.newTab).labelStyle(.iconOnly) }
                .buttonStyle(.borderless).help(L("db.sql.newTabHelp")).accessibilityIdentifier("db.sql.newTab")
                .disabled(allTabs.count >= Self.maxTabs)
            if connection.isSQL && connection.allowsWrites {
                Divider().frame(height: 18)
                transactionControls
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
    }

    /// ⌘T, ⌘W and ⌃Tab act on the query tabs while the editor is on screen.
    private var shortcuts: some View {
        Group {
            Button(L("db.sql.newTab")) { addTab(sql: "") }.keyboardShortcut("t").disabled(allTabs.count >= Self.maxTabs)
            Button(L("db.sql.closeTab")) { close(current) }.keyboardShortcut("w").disabled(tabs.count < 2)
            Button(L("db.sql.nextTab")) { cycle(1) }.keyboardShortcut(.tab, modifiers: .control)
            Button(L("db.sql.previousTab")) { cycle(-1) }.keyboardShortcut(.tab, modifiers: [.control, .shift])
        }
        .hidden()
    }

    func open() async {
        var list = await client.queryTabs(connection)
        if !list.contains(where: { $0.database == database }) {
            list.append(QueryTab(id: UUID().uuidString.lowercased(), title: String(format: L("db.sql.tabTitle"), 1), database: database, sql: ""))
        }
        allTabs = list
        let mine = list.filter { $0.database == database }
        current = mine.first?.id ?? ""
        // «Abrir en SQL» from a table starts from a SELECT of it: in its own tab if that text is not open yet.
        if let initial = client.pendingSQL {
            client.pendingSQL = nil
            if let same = mine.first(where: { $0.sql == initial }) { current = same.id }
            else if let empty = mine.first(where: { $0.sql.isEmpty }) { current = empty.id; setSQL(initial, in: empty.id) }
            else { addTab(sql: initial) }
        }
        text = allTabs.first(where: { $0.id == current })?.sql ?? ""
        #if DEBUG
        if let preset = QAHooks.databaseSQL { text = preset }
        #endif
        if connection.isSQL { schema = await client.schema(connection, database) }
        if connection.isSQL, connection.allowsWrites, !inTransaction,
           (try? await client.read("dbTxStatus", connection, ["database": database], as: Bool.self)) == true {
            // A transaction left open (the window closed, the app went on): it is still there.
            client.transactions.insert("\(connection.id)/\(database)")
        }
        #if DEBUG
        await QAHooks.databaseQueryActions(inTransaction: inTransaction, begin: { await client.beginTransaction(connection, database) },
                                           run: { await run() }, explain: { await explain() })
        #endif
    }
    func select(_ id: String) {
        current = id
        text = allTabs.first(where: { $0.id == id })?.sql ?? ""
        resultIndex = 0
    }
    /// The next (or previous) tab, going round.
    func cycle(_ step: Int) {
        let list = tabs
        guard list.count > 1, let index = list.firstIndex(where: { $0.id == current }) else { return }
        select(list[(index + step + list.count) % list.count].id)
    }
    func addTab(sql: String) {
        guard allTabs.count < Self.maxTabs else { return }
        let used = Set(tabs.map(\.title))
        var n = tabs.count + 1
        while used.contains(String(format: L("db.sql.tabTitle"), n)) { n += 1 }
        let tab = QueryTab(id: UUID().uuidString.lowercased(), title: String(format: L("db.sql.tabTitle"), n), database: database, sql: sql)
        allTabs.append(tab)
        select(tab.id)
        saveSoon()
    }
    func close(_ id: String) {
        guard tabs.count > 1 else { return }
        let mine = tabs
        let index = mine.firstIndex(where: { $0.id == id }) ?? 0
        allTabs.removeAll { $0.id == id }
        outputs[id] = nil
        plans[id] = nil
        if current == id { select(tabs[safe: max(0, index - 1)]?.id ?? tabs.first?.id ?? "") }
        saveSoon()
    }
    func setSQL(_ sql: String, in id: String) {
        if let index = allTabs.firstIndex(where: { $0.id == id }) { allTabs[index].sql = sql }
        saveSoon()
    }
    /// Saved a moment after the last keystroke.
    func saveSoon() {
        saving?.cancel()
        let tabs = allTabs
        saving = Task {
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            await client.saveQueryTabs(tabs, for: connection)
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button { Task { await run() } } label: {
                Label(selected.isEmpty ? L("db.run") : L("db.runSelection"), systemImage: Symbols.start)
            }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(running || !hasText)
            .help(L("db.runHelp"))
            .accessibilityIdentifier("db.toolbar.run")
            if connection.isSQL {
                Button { Task { await explain() } } label: { Label(L("db.sql.explain"), systemImage: Symbols.explain) }
                    .help(L("db.sql.explainHelp")).disabled(running || !hasText)
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .accessibilityIdentifier("db.toolbar.explain")
            }
            if connection.isSQL, let r = output?.results[safe: resultIndex], !r.columns.isEmpty {
                Menu {
                    ForEach(["csv", "json", "sql"], id: \.self) { format in
                        Button(L("db.export.\(format)")) {
                            Task { await client.export(connection, format: format, suggested: "resultado", ["source": "query", "sql": r.statement, "database": database]) }
                        }
                        .accessibilityIdentifier("db.sql.export.\(format)")
                    }
                } label: { Label(L("db.export"), systemImage: Symbols.share) }
                    .help(L("db.export.queryHelp")).accessibilityIdentifier("db.toolbar.export")
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if connection.isSQL {
                Button { format() } label: { Label(L("db.sql.format"), systemImage: Symbols.format) }
                    .help(L("db.sql.formatHelp")).keyboardShortcut("f", modifiers: [.command, .shift])
                    .accessibilityIdentifier("db.toolbar.format")
            }
            Button { Task { historyItems = await client.history(connection, database: database); showHistory.toggle() } } label: {
                Label(L("db.history"), systemImage: Symbols.history)
            }
            .popover(isPresented: $showHistory, arrowEdge: .bottom) { history }
            .accessibilityIdentifier("db.toolbar.history")
        }
    }

    @ViewBuilder var transactionControls: some View {
        if inTransaction {
            Label(L("db.tx.open"), systemImage: Symbols.transaction).font(.uiCaption.weight(.semibold)).lineLimit(1).fixedSize().foregroundStyle(Brand.warning)
                .help(L("db.tx.openHelp")).accessibilityIdentifier("db.sql.tx.state")
            Button { Task { await client.endTransaction(connection, database, commit: true) } } label: { Label(L("db.tx.commit"), systemImage: Symbols.success).fixedSize() }
                .buttonStyle(.borderedProminent).controlSize(.small).accessibilityIdentifier("db.sql.tx.commit")
            Button { Task { await client.endTransaction(connection, database, commit: false) } } label: { Label(L("db.tx.rollback"), systemImage: Symbols.rollback).fixedSize() }
                .buttonStyle(.bordered).controlSize(.small).accessibilityIdentifier("db.sql.tx.rollback")
        } else {
            Button { Task { await client.beginTransaction(connection, database) } } label: { Label(L("db.tx.begin"), systemImage: Symbols.transaction).fixedSize() }
                .buttonStyle(.bordered).controlSize(.small)
                .help(L("db.tx.beginHelp")).accessibilityIdentifier("db.sql.tx.begin")
        }
    }

    var history: some View {
        VStack(alignment: .leading, spacing: 0) {
            if historyItems.isEmpty {
                ContentUnavailableView(L("db.historyEmpty"), systemImage: Symbols.history).frame(height: 160)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(historyItems.enumerated()), id: \.offset) { index, sql in
                            Button { text = sql; showHistory = false } label: {
                                Text(sql).font(.uiSubheadline.monospaced()).lineLimit(3).padding(8)
                            }
                            .buttonStyle(HighlightButtonStyle())
                            .accessibilityIdentifier("db.sql.history.\(index)")
                            Divider()
                        }
                    }
                }
                HStack {
                    Spacer()
                    Button { Task { await client.clearHistory(connection, database: database); historyItems = [] } } label: {
                        Label(L("db.history.clear"), systemImage: Symbols.delete)
                    }
                    .buttonStyle(.bordered).accessibilityIdentifier("db.sql.history.clear")
                }
                .padding(10)
            }
            Text(L("db.history.note")).font(.uiCaption).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.bottom, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 420, idealWidth: 460, minHeight: 200, idealHeight: 340)
    }

    // MARK: Results

    @ViewBuilder var results: some View {
        VStack(spacing: 0) {
            if showPlan, let plan = plans[current] {
                HStack {
                    Label(L("db.sql.plan"), systemImage: Symbols.explain).font(.uiCallout.weight(.semibold))
                    Spacer()
                    Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(plan.raw, forType: .string); client.store.notify(L("db.copied")) } label: {
                        Label(L("common.copy"), systemImage: Symbols.copy)
                    }
                    .buttonStyle(.bordered).controlSize(.small).disabled(plan.raw.isEmpty).accessibilityIdentifier("db.sql.plan.copy")
                    Button { showPlan = false } label: { Label(L("db.sql.closePlan"), systemImage: Symbols.back) }
                        .buttonStyle(.bordered).controlSize(.small).accessibilityIdentifier("db.sql.plan.close")
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                PlanView(plan: plan)
            } else if let output {
                HStack(spacing: 8) {
                    if output.results.count > 1 {
                        Picker(L("db.sql.resultPicker"), selection: $resultIndex) {
                            ForEach(Array(output.results.enumerated()), id: \.offset) { index, r in
                                Text(verbatim: "\(index + 1). \(r.statement.prefix(30))").tag(index)
                            }
                        }
                        .labelsHidden().frame(maxWidth: 320).accessibilityIdentifier("db.sql.resultPicker")
                    }
                    if let r = output.results[safe: resultIndex] {
                        Text(r.columns.isEmpty ? String(format: L("db.affected"), r.affected ?? 0) : String(format: L("db.returned"), r.rows.count) + (r.truncated ? " · " + L("db.truncated") : ""))
                            .font(.uiCaption.monospacedDigit()).foregroundStyle(.secondary)
                            .accessibilityIdentifier("db.sql.resultSummary")
                    }
                    Spacer()
                    Text(String(format: L("db.durationMs"), output.durationMs)).font(.uiCaption.monospacedDigit()).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                Divider()
                if let error = output.error { DBProblemCard(problem: .from(text: error)).padding(10) }
                if let r = output.results[safe: resultIndex], !r.columns.isEmpty {
                    DataGrid(columns: r.columns, rows: r.rows)
                        .overlay {
                            if r.rows.isEmpty {
                                ContentUnavailableView(L("db.noResultRows"), systemImage: Symbols.table).accessibilityIdentifier("db.sql.noRows")
                            }
                        }
                } else {
                    Spacer()
                }
            } else {
                ContentUnavailableView(L("db.resultsHere"), systemImage: Symbols.table, description: Text(L("db.resultsHereDetail")))
                    .accessibilityIdentifier("db.sql.noResults")
            }
        }
    }

    // MARK: Actions

    var statementText: String { selected.isEmpty ? text : selected }

    func run() async {
        let sql = statementText
        guard !sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !running else { return }
        running = true; defer { running = false }
        let tab = current
        var request: [String: Any] = ["database": database, "sql": sql]
        if inTransaction { request["transaction"] = true }
        let title = String(format: L(inTransaction ? "db.confirm.sqlTransaction" : "db.confirm.sql"), connection.title)
        if let value: DBRunOutput = await client.change("dbRun", connection, request, title: title) {
            outputs[tab] = value
            showPlan = false
            resultIndex = max(0, value.results.lastIndex(where: { !$0.columns.isEmpty }) ?? value.results.count - 1)
            await client.remember(sql, in: connection, database: database)
        } else if inTransaction, (try? await client.read("dbTxStatus", connection, ["database": database], as: Bool.self)) != true {
            // The transaction's session ended (idle, disconnected): the server rolled it back.
            client.transactions.remove("\(connection.id)/\(database)")
        }
    }

    func explain() async {
        let sql = statementText
        guard !sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !running else { return }
        running = true; defer { running = false }
        do {
            let plan: DBPlan = try await client.read("dbExplain", connection, ["database": database, "sql": sql])
            plans[current] = plan
            showPlan = true
        } catch {
            client.store.report(error)
        }
    }

    func format() {
        if selected.isEmpty {
            text = SQLFormatter.format(text)
        } else if let range = text.range(of: selected) {
            text.replaceSubrange(range, with: SQLFormatter.format(selected))
        }
    }
}

/// A query tab: its title selects it and the cross at its end (16 pt, reachable with Tab) closes it.
private struct QueryTabButton: View {
    let tab: QueryTab
    let current: Bool
    let closable: Bool
    let select: () -> Void
    let close: () -> Void
    var body: some View {
        HStack(spacing: 2) {
            Button(action: select) {
                Text(tab.title).lineLimit(1).font(.uiCallout.weight(current ? .semibold : .regular))
                    .padding(.leading, 8).padding(.trailing, closable ? 2 : 8).padding(.vertical, 3)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.primary)
            .accessibilityAddTraits(current ? .isSelected : [])
            .accessibilityIdentifier("db.sql.tab.\(tab.title)")
            if closable {
                Button(action: close) {
                    Label(L("db.sql.closeTab"), systemImage: Symbols.close).labelStyle(.iconOnly)
                        .font(.uiCaption.weight(.semibold))
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help(L("db.sql.closeTab"))
                .accessibilityIdentifier("db.sql.tab.close.\(tab.title)")
                .padding(.trailing, 4)
            }
        }
        .background(current ? AnyShapeStyle(Brand.accent.opacity(0.16)) : AnyShapeStyle(.quaternary.opacity(0.5)), in: RoundedRectangle(cornerRadius: 7))
    }
}

/// A plan as an indented tree: nodes with an arrow, their details below in grey.
struct PlanView: View {
    let plan: DBPlan
    var body: some View {
        if let table = plan.table {
            DataGrid(columns: table.columns, rows: table.rows)
        } else {
            GeometryReader { geometry in ScrollView([.vertical, .horizontal]) {
                VStack(alignment: .leading, spacing: 3) {
                    if plan.lines.isEmpty { Text(L("db.sql.planEmpty")).foregroundStyle(.secondary) }
                    ForEach(Array(plan.lines.enumerated()), id: \.offset) { _, line in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Color.clear.frame(width: CGFloat(line.depth) * 20, height: 1)
                            if line.detail {
                                Text(line.text).font(.uiSubheadline.monospaced()).foregroundStyle(.secondary)
                            } else {
                                Image(systemName: line.depth == 0 ? Symbols.planRoot : Symbols.planStep).font(.uiCaption2).foregroundStyle(.secondary)
                                Text(line.text).font(.uiCallout.weight(.medium).monospaced())
                            }
                        }
                        .textSelection(.enabled)
                    }
                }
                .padding(12)
                .frame(minWidth: geometry.size.width, minHeight: geometry.size.height, alignment: .topLeading)
            } }
            .accessibilityIdentifier("db.sql.planView")
        }
    }
}
