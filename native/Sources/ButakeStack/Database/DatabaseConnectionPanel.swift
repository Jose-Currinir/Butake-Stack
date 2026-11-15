import AppKit
import SwiftUI

// MARK: - Connection overview

/// Resumen of a connection: what it connects to, its databases and, for Stack's MySQL, root's
/// password.
struct ConnectionOverview: View {
    @Bindable var client: DatabaseClient
    let connection: DBConnection
    @State private var newDatabase = ""
    var body: some View {
        Form {
            Section {
                ConnectionFacts(client: client, connection: connection)
            } header: {
                Text(L("db.connectionData"))
            } footer: {
                if connection.builtin { Text(L("db.builtinHelp")).font(.uiCaption).foregroundStyle(.secondary) }
            }
            if connection.isSQL && connection.kind != "sqlite" { databases }
            if connection.id == DatabaseVault.mysqlRoot { RootPasswordSection(client: client, connection: connection) }
            if connection.builtin && connection.kind == "postgres" { PostgresAuthSection(client: client) }
        }
        .formStyle(.grouped)
        .themedScroll()
        .task { if client.databases[connection.id] == nil { await client.loadDatabases(connection) } }
    }

    private var databases: some View {
        Section {
            let list = client.databases[connection.id] ?? []
            if list.isEmpty {
                Text(L("db.noDatabases")).foregroundStyle(.secondary).accessibilityIdentifier("db.overview.noDatabases")
            }
            ForEach(list) { database in
                LabeledContent {
                    HStack(spacing: 8) {
                        Text(Format.fileSizeText(database.size)).font(.uiCaption.monospacedDigit()).foregroundStyle(.secondary)
                        Button { client.copyURL(connection, database: database.name) } label: {
                            Label(L("db.copyURL"), systemImage: Symbols.link).labelStyle(.iconOnly)
                        }
                        .buttonStyle(.borderless).help(L("db.copyURL"))
                        .accessibilityIdentifier("db.overview.copyURL.\(database.name)")
                        if !database.system && database.name != "postgres" && connection.allowsWrites {
                            Button { Task { await drop(database.name) } } label: {
                                Label(L("db.dropDatabase"), systemImage: Symbols.delete).labelStyle(.iconOnly)
                            }
                            .buttonStyle(.borderless).help(L("db.dropDatabase"))
                            .accessibilityIdentifier("db.overview.drop.\(database.name)")
                        }
                        Button { client.selection = DBSelection(connection: connection.id, database: database.name) } label: {
                            Label(L("db.openDatabase"), systemImage: Symbols.forward).labelStyle(.iconOnly)
                        }
                        .buttonStyle(.borderless).help(L("db.openDatabase"))
                        .accessibilityIdentifier("db.overview.open.\(database.name)")
                    }
                } label: {
                    Label(database.name, systemImage: Symbols.database)
                        .foregroundStyle(database.system ? .secondary : .primary)
                }
            }
            if connection.allowsWrites {
                LabeledContent(L("db.newDatabase")) {
                    HStack {
                        TextField(L("db.newDatabase"), text: $newDatabase, prompt: Text(L("db.newDatabasePrompt")))
                            .labelsHidden().textFieldStyle(.roundedBorder).multilineTextAlignment(.leading)
                            .onSubmit { if !newDatabase.isEmpty { Task { await create() } } }
                            .accessibilityIdentifier("db.overview.newDatabase")
                        Button { Task { await create() } } label: { Label(L("common.create"), systemImage: Symbols.add) }
                            .buttonStyle(.bordered).disabled(newDatabase.isEmpty)
                            .accessibilityIdentifier("db.overview.createDatabase")
                    }
                }
            }
        } header: {
            Text(L("db.databases"))
        } footer: {
            Text(L("db.databasesHelp")).font(.uiCaption).foregroundStyle(.secondary)
        }
    }

    func create() async {
        let name = newDatabase
        if let _: DBRunOutput = await client.change("dbCreateDatabase", connection, ["name": name], title: String(format: L("db.confirm.create"), name)) {
            newDatabase = ""
            await client.loadDatabases(connection)
        }
    }
    func drop(_ name: String) async {
        if let _: DBRunOutput = await client.change("dbDropDatabase", connection, ["name": name], title: String(format: L("db.confirm.drop"), name, connection.title), typedName: name) {
            await client.loadDatabases(connection)
        }
    }
}

/// The stack's MySQL starts with root and no password. Setting one keeps it in the Keychain; the
/// client and new projects' databases use it (each new project then gets its own account).
struct RootPasswordSection: View {
    @Bindable var client: DatabaseClient
    let connection: DBConnection
    @State private var revealed: String?
    var body: some View {
        let has = DatabaseVault.has(connection.id)
        Section {
            HStack(spacing: 10) {
                IconTile(symbol: has ? Symbols.certificate : Symbols.noRootPassword, color: has ? TileColor.correct : TileColor.warning, size: 26)
                Text(has ? L("db.root.set") : L("db.root.none")).frame(maxWidth: .infinity, alignment: .leading)
                Spacer()
                if connection.allowsWrites {
                    Button { Task { await setPassword() } } label: { Label(has ? L("db.root.change") : L("db.root.setButton"), systemImage: Symbols.key) }
                        .buttonStyle(.borderedProminent).accessibilityIdentifier("db.root.set")
                }
            }
            if has {
                LabeledContent(L("db.password")) {
                    HStack {
                        Text(revealed ?? "••••••••••••").font(.uiMonospaced).textSelection(.enabled)
                        Button {
                            if revealed != nil { revealed = nil } else {
                                // Read once when revealed, never on each redraw (each read may ask macOS for access).
                                Task { if await EnvVault.authenticate(L("db.root.authReveal")) { revealed = DatabaseVault.get(connection.id) ?? "" } }
                            }
                        } label: { Label(revealed != nil ? L("db.root.hide") : L("db.root.reveal"), systemImage: Symbols.databaseView) }
                            .buttonStyle(.bordered).accessibilityIdentifier("db.root.reveal")
                        Button {
                            Task {
                                guard await EnvVault.authenticate(L("db.root.authReveal")), let value = DatabaseVault.get(connection.id) else { return }
                                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string)
                                client.store.notify(L("db.root.copied"))
                            }
                        } label: { Label(L("common.copy"), systemImage: Symbols.copy) }
                            .buttonStyle(.bordered).accessibilityIdentifier("db.root.copy")
                    }
                }
            }
        } header: {
            Text(L("db.root.title"))
        } footer: {
            Text(L("db.root.help")).font(.uiCaption).foregroundStyle(.secondary)
        }
    }
    /// The new password goes to the Keychain only after MySQL accepted it.
    func setPassword() async {
        let password = DatabaseVault.generate()
        let sites = client.store.projects.filter { $0.services.contains("mysql") }.map(\.title)
        let title = sites.isEmpty ? L("db.root.confirm") : String(format: L("db.root.confirmSites"), sites.joined(separator: ", "))
        struct Done: Decodable { let accounts: Int }
        if let _: Done = await client.change("dbSetRootPassword", connection, ["newPassword": password], title: title) {
            DatabaseVault.set(password, for: connection.id, label: "MySQL root")
            client.store.notify(L("db.root.saved"))
            await client.loadConnections()
        }
    }
}

// MARK: - Tables of a database (with sizes)

extension DBObject {
    /// The name with its schema when it is not the default one.
    var qualifiedName: String { schema.map { $0.isEmpty || $0 == "public" ? name : "\($0).\(name)" } ?? name }
    var sortRows: Int { rows ?? -1 }
    var sortSize: Int { size ?? -1 }
    var sortEngine: String { engine ?? "" }
}

struct TablesPanel: View {
    @Bindable var client: DatabaseClient
    let connection: DBConnection
    let database: String
    @State private var creating = false
    @State private var picked: DBObject.ID?
    @State private var order = [KeyPathComparator(\DBObject.sortSize, order: .reverse)]
    var body: some View {
        let key = "\(connection.id)/\(database)"
        let list = (client.objects[key] ?? []).sorted(using: order)
        VStack(spacing: 0) {
            if let error = client.errors[key] { DBProblemCard(problem: error).padding(14) }
            if list.isEmpty && client.errors[key] == nil && !client.loading.contains(key) && client.objects[key] != nil {
                ContentUnavailableView(L("db.noTables"), systemImage: Symbols.table, description: Text(L("db.noTablesDetail")))
                    .accessibilityIdentifier("db.tables.empty")
            } else {
                Table(list, selection: $picked, sortOrder: $order) {
                    TableColumn(L("db.col.table"), value: \.qualifiedName) { o in
                        Label(o.qualifiedName, systemImage: o.view ? Symbols.databaseView : Symbols.table).lineLimit(1)
                    }
                    .width(min: 120, ideal: 200)
                    TableColumn(L("db.col.rows"), value: \.sortRows) { o in
                        Text(o.rows.map { "≈ \($0.formatted())" } ?? "—").monospacedDigit().foregroundStyle(.secondary)
                    }
                    .width(min: 60, ideal: 80).alignment(.trailing)
                    TableColumn(L("db.col.size"), value: \.sortSize) { o in
                        Text(Format.fileSizeText(o.size)).monospacedDigit()
                    }
                    .width(min: 60, ideal: 80).alignment(.trailing)
                    TableColumn(L("db.col.engine"), value: \.sortEngine) { o in
                        Text(o.view ? L("db.view") : (o.engine ?? "")).foregroundStyle(.secondary)
                    }
                    .width(min: 60, ideal: 80)
                }
                .contextMenu(forSelectionType: DBObject.ID.self) { ids in
                    if let object = list.first(where: { ids.contains($0.id) }) {
                        Button { open(object) } label: { Label(L("db.openTable"), systemImage: Symbols.openTable) }
                            .accessibilityIdentifier("db.tables.menu.open")
                    }
                } primaryAction: { ids in
                    if let object = list.first(where: { ids.contains($0.id) }) { open(object) }
                }
                .accessibilityIdentifier("db.tables.table")
            }
            Divider()
            HStack {
                Text(String(format: L("db.tablesTotal"), list.count, Format.fileSizeText(list.compactMap(\.size).reduce(0, +))))
                    .font(.uiCaption).foregroundStyle(.secondary)
                Spacer()
                if connection.allowsWrites {
                    Button { creating = true } label: { Label(L("ddl.newTable"), systemImage: Symbols.newTable) }
                        .buttonStyle(.bordered).accessibilityIdentifier("db.tables.newTable")
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .task {
            if client.objects[key] == nil { await client.loadObjects(connection, database) }
            #if DEBUG
            if QAHooks.databaseSheet == "newTable" { creating = true }
            #endif
        }
        .sheet(isPresented: $creating) {
            CreateTableSheet(client: client, connection: connection, database: database, schema: connection.kind == "postgres" ? "public" : "").themedSheet()
        }
    }

    private func open(_ o: DBObject) {
        client.selection = DBSelection(connection: connection.id, database: database, schema: o.schema.flatMap { $0.isEmpty ? nil : $0 }, table: o.name, isView: o.view)
    }
}
