import AppKit
import SwiftUI

/// The database client's detail: the selected connection, database or table, and the page's
/// actions in the window's toolbar. Its connections and their tree are in the window's content
/// column (`ContentColumn`). Every change goes through a confirmation that shows what will run.
struct DatabaseClientView: View {
    @Bindable var client = DatabaseClient.shared
    /// The tab of a connection or a database, and the one of a table, kept with the window.
    @SceneStorage("db.serverTab") private var serverTab = "overview"
    @SceneStorage("db.tableTab") private var tableTab = "data"

    private struct Shown { let connection: DBConnection; let selection: DBSelection }
    private var selected: Shown? {
        guard let selection = client.selection, let connection = client.connection(selection.connection) else { return nil }
        return Shown(connection: connection, selection: selection)
    }

    var body: some View {
        Group {
            if let shown = selected {
                DatabaseDetail(client: client, connection: shown.connection, selection: shown.selection,
                               tab: tabBinding(shown.connection, shown.selection))
                    .id(shown.selection)
            } else {
                ContentUnavailableView {
                    Label(L(client.connections.isEmpty ? "db.emptyNoneTitle" : "db.empty"), systemImage: Symbols.database)
                } description: {
                    Text(L(client.connections.isEmpty ? "db.emptyNone" : "db.emptyDetail"))
                } actions: {
                    Button { client.newConnection() } label: { Label(L("db.newConnection"), systemImage: Symbols.newConnection) }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("db.empty.newConnection")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .toolbar { toolbar }
        .task {
            client.watchIdle()
            await client.migrateHistory()
            await client.loadConnections()
            #if DEBUG
            QAHooks.databaseClientSheets(client)
            if let preset = QAHooks.databaseTab {
                if ["data", "structure"].contains(preset) { tableTab = preset } else { serverTab = preset }
            }
            #endif
        }
        .sheet(item: $client.editing) { connection in
            ConnectionEditor(client: client, original: connection).themedSheet()
        }
        .sheet(item: Binding(get: { client.pending }, set: { if $0 == nil { client.pending?.resume(false, ""); client.pending = nil } })) { pending in
            ConfirmChangeSheet(pending: pending).themedSheet()
        }
        .sheet(item: $client.hostCheck) { check in
            HostCheckSheet(client: client, check: check).themedSheet()
        }
        .overlay(alignment: .bottom) {
            if let progress = client.progress {
                Notice(.progress, progress.title, detail: progress.detail, value: progress.fraction).padding(18)
                    .accessibilityIdentifier("db.progress")
            }
        }
    }

    /// The tabs of what is selected (a table has its own) and the one on screen.
    private func tabBinding(_ connection: DBConnection, _ selection: DBSelection) -> Binding<String> {
        let tabs = DatabaseDetail.tabs(connection, selection)
        let table = selection.table != nil && !connection.isRedis
        return Binding(get: {
            let stored = table ? tableTab : serverTab
            return tabs.contains(stored) ? stored : tabs[0]
        }, set: { value in
            if table { tableTab = value } else { serverTab = value }
        })
    }

    // MARK: Toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button { client.newConnection() } label: { Label(L("db.newConnectionEllipsis"), systemImage: Symbols.newConnection) }
                .help(L("db.newConnectionHelp")).accessibilityIdentifier("db.toolbar.newConnection")
            if let connection = selected?.connection {
                if client.isConnected(connection.id) {
                    Button { Task { await client.disconnect(connection) } } label: { Label(L("db.disconnect"), systemImage: Symbols.disconnect) }
                        .help(L("db.disconnectHelp")).accessibilityIdentifier("db.toolbar.disconnect")
                } else {
                    Button { Task { await client.connect(connection) } } label: { Label(L("db.connect"), systemImage: Symbols.connect) }
                        .help(L("db.connectHelp")).accessibilityIdentifier("db.toolbar.connect")
                        .disabled(client.status[connection.id] == .checking)
                }
                Button { Task { await client.reload(connection) } } label: { Label(L("common.refresh"), systemImage: Symbols.reload) }
                    .shortcut(Shortcuts.dbReload)
                    .help(L("db.reloadHelp")).accessibilityIdentifier("db.toolbar.reload")
            }
        }
        if let connection = selected?.connection, let selection = selected?.selection {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    if let table = selection.table, connection.isSQL, client.isConnected(connection.id) {
                        Button { openInSQL(connection, selection, table) } label: { Label(L("db.openInSQL"), systemImage: Symbols.openInSQL) }
                            .help(L("db.openInSQLHelp")).accessibilityIdentifier("db.toolbar.openInSQL")
                        Divider()
                    }
                    Button { client.copyURL(connection, database: selection.database) } label: { Label(L("db.copyURL"), systemImage: Symbols.copy) }
                        .accessibilityIdentifier("db.toolbar.copyURL")
                    Button { Task { await client.openTerminal(connection, database: selection.database) } } label: {
                        Label(L("db.openTerminal"), systemImage: Symbols.terminal)
                    }
                    .accessibilityIdentifier("db.toolbar.openTerminal")
                    if !connection.builtin {
                        Divider()
                        Button { client.editing = connection } label: { Label(L("db.editConnectionEllipsis"), systemImage: Symbols.edit) }
                            .accessibilityIdentifier("db.toolbar.edit")
                        Button(role: .destructive) { Task { await client.delete(connection) } } label: {
                            Label(L("db.deleteConnection"), systemImage: Symbols.delete)
                        }
                        .accessibilityIdentifier("db.toolbar.delete")
                    }
                } label: {
                    Label(L("db.moreActions"), systemImage: Symbols.more)
                }
                .help(L("db.moreActions")).accessibilityIdentifier("db.toolbar.more")
            }
        }
    }

    /// A table's rows in the SQL editor of its database, in a tab of their own.
    private func openInSQL(_ connection: DBConnection, _ selection: DBSelection, _ table: String) {
        client.pendingSQL = "SELECT * FROM \(DatabaseDetail.quoted(table, schema: selection.schema, kind: connection.kind)) LIMIT 100;"
        serverTab = "sql"
        client.selection = DBSelection(connection: connection.id, database: selection.database)
    }
}

extension DatabaseClient.Progress {
    /// Rows exported so far, or bytes done of the total.
    var detail: String {
        if unit == "rows" { return String(format: L("db.export.rows"), done.formatted()) }
        return total > 0 ? "\(Format.fileSizeText(done)) / \(Format.fileSizeText(total))" : Format.fileSizeText(done)
    }
    var fraction: Double? { unit != "rows" && total > 0 ? Double(done) / Double(max(total, 1)) : nil }
}
