import SwiftUI

/// What is selected in the list: its path and modes on one line, its tabs under it and the tab
/// chosen. A connection that does not answer, or that the user closed, says so instead.
struct DatabaseDetail: View {
    @Bindable var client: DatabaseClient
    let connection: DBConnection
    let selection: DBSelection
    @Binding var tab: String

    /// Two levels: a connection or a database (its server's tabs), and a table (its rows and its
    /// structure). Redis has its own; SQLite has no users, sessions or dumps.
    static func tabs(_ connection: DBConnection, _ selection: DBSelection) -> [String] {
        if connection.isRedis { return ["overview", "keys", "console", "clients"] }
        if selection.table != nil { return ["data", "structure"] }
        var list = [selection.database == nil ? "overview" : "tables", "sql"]
        if connection.kind != "sqlite" { list += ["users", "processes", "backup"] }
        if selection.database != nil { list.append("diagram") }
        if selection.database != nil && connection.builtin && connection.kind == "postgres" { list.append("extensions") }
        return list
    }

    /// Every tab the client can show (LocalizationTests checks each has its title).
    static let allTabs = ["overview", "tables", "sql", "users", "processes", "backup", "diagram", "data", "structure", "keys", "console", "clients", "extensions"]

    static func title(of tab: String) -> String { L("db.tab.\(tab)") }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            // The tabs live with what they show, not in the toolbar: there they would crowd the
            // detail's actions over the content column. Too many for the width, they become a menu.
            if client.isConnected(connection.id) {
                ViewThatFits(in: .horizontal) {
                    tabPicker.pickerStyle(.segmented).fixedSize()
                    tabPicker.pickerStyle(.menu).fixedSize()
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 16).padding(.bottom, 9)
            }
            Divider()
            switch client.status[connection.id] {
            case .failed(let problem):
                ConnectionProblemView(client: client, connection: connection, problem: problem)
            case .ok:
                content.frame(maxWidth: .infinity, maxHeight: .infinity)
            case .disconnected:
                DisconnectedView(client: client, connection: connection)
            default:
                ProgressView(L("db.connecting")).frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("db.detail.connecting")
            }
        }
        // Production: a red band on top and a red frame around everything shown for it.
        .overlay(alignment: .top) {
            if connection.production { Rectangle().fill(Brand.danger).frame(height: 4).accessibilityIdentifier("db.detail.productionBand") }
        }
        .overlay {
            if connection.production { Rectangle().strokeBorder(Brand.danger.opacity(0.55), lineWidth: 2).allowsHitTesting(false) }
        }
        .task(id: connection.id) {
            switch client.status[connection.id] {
            case .ok, .disconnected: return
            default: await client.check(connection)
            }
        }
    }

    private var tabPicker: some View {
        Picker(L("db.detailTabs"), selection: $tab) {
            ForEach(Self.tabs(connection, selection), id: \.self) { Text(Self.title(of: $0)).tag($0) }
        }
        .labelsHidden()
        .accessibilityIdentifier("db.toolbar.tabs")
    }

    /// Where the selection is (connection › database › table), its modes and the server's version.
    private var header: some View {
        HStack(spacing: 10) {
            TechLogo(tech: connection.tech, size: 22)
            Text(breadcrumb).font(.uiHeadline).lineLimit(1).truncationMode(.middle).help(breadcrumb)
                .accessibilityIdentifier("db.detail.title")
            ConnectionModeBadges(connection: connection)
            Spacer(minLength: 8)
            if case .ok(let version) = client.status[connection.id] {
                Text(version).font(.uiCaption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail).help(version)
                    .accessibilityIdentifier("db.detail.version")
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
    }

    var breadcrumb: String {
        var parts = [connection.title]
        if let db = selection.database { parts.append(connection.isRedis ? String(format: L("db.redis.database"), db) : db) }
        if let schema = selection.schema, !schema.isEmpty, selection.table != nil { parts.append(schema) }
        if let table = selection.table { parts.append(table) }
        return parts.joined(separator: " › ")
    }

    @ViewBuilder var content: some View {
        let database = selection.database ?? ""
        switch tab {
        case "data": TableDataPanel(client: client, connection: connection, selection: selection)
        case "structure": StructurePanel(client: client, connection: connection, selection: selection)
        case "sql", "console": SQLPanel(client: client, connection: connection, database: database)
        case "tables": TablesPanel(client: client, connection: connection, database: database)
        case "diagram": SchemaDiagramPanel(client: client, connection: connection, database: database)
        case "backup": BackupPanel(client: client, connection: connection, database: selection.database)
        case "users": UsersPanel(client: client, connection: connection)
        case "processes", "clients": ProcessesPanel(client: client, connection: connection)
        case "extensions": DatabaseExtensionsPanel(client: client, database: database)
        case "keys": RedisKeysPanel(client: client, connection: connection, database: selection.database ?? "0")
        default: ConnectionOverview(client: client, connection: connection)
        }
    }

    /// A table's name as the engine's SQL writes it.
    static func quoted(_ table: String, schema: String?, kind: String) -> String {
        switch kind {
        case "mysql", "mariadb": "`\(table)`"
        default: schema.map { $0.isEmpty || $0 == "public" ? "\"\(table)\"" : "\"\($0)\".\"\(table)\"" } ?? "\"\(table)\""
        }
    }
}

/// A connection the user closed: one button to connect again, and what it connects to.
private struct DisconnectedView: View {
    let client: DatabaseClient
    let connection: DBConnection
    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    IconTile(symbol: Symbols.disconnect, size: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("db.disconnected")).font(.uiHeadline)
                        Text(L("db.disconnectedShort")).font(.uiCaption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .help(L("db.disconnectedHelp"))
                    Spacer()
                    Button { Task { await client.connect(connection) } } label: { Label(L("db.connect"), systemImage: Symbols.connect) }
                        .buttonStyle(.borderedProminent).accessibilityIdentifier("db.disconnected.connect")
                }
            }
            Section(L("db.connectionData")) {
                ConnectionFacts(client: client, connection: connection)
            }
        }
        .formStyle(.grouped)
        .themedScroll()
    }
}

/// "Producción" and "Solo lectura" next to the name of what is shown.
struct ConnectionModeBadges: View {
    let connection: DBConnection
    var body: some View {
        HStack(spacing: 6) {
            if connection.production {
                Label(L("db.mode.production"), systemImage: Symbols.error)
                    .font(.uiSubheadline.weight(.bold)).foregroundStyle(.white).lineLimit(1).fixedSize()
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Brand.danger, in: Capsule())
                    .help(L("db.mode.productionHelp"))
                    .accessibilityIdentifier("db.detail.badge.production")
            }
            if connection.readOnly {
                Chip(text: L("db.mode.readOnly"), symbol: Symbols.readOnly, tint: Brand.info, help: L("db.mode.readOnlyHelp"))
                    .fixedSize()
                    .accessibilityIdentifier("db.detail.badge.readOnly")
            }
        }
    }
}
