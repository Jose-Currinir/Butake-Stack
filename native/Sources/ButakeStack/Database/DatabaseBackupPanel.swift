import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Backups

extension DBDatabase {
    var sortSize: Int { size ?? -1 }
}

/// Respaldos: a dump of one database (with its tables to choose) or of several (ticked in the
/// table), and a restore or a CSV import into the database chosen.
struct BackupPanel: View {
    @Bindable var client: DatabaseClient
    let connection: DBConnection
    let database: String?
    @State private var chosen: Set<String> = []
    @State private var tables: Set<String> = []
    @State private var content = "all"
    @State private var routines = true
    @State private var triggers = true
    @State private var events = true
    @State private var compress = true
    @State private var restoreTarget = ""
    @State private var createTarget = false
    @State private var last: String?
    @State private var order = [KeyPathComparator(\DBDatabase.name)]
    var dbs: [DBDatabase] { (client.databases[connection.id] ?? []).filter { !$0.system || $0.name == "postgres" } }
    var objects: [DBObject] { database.map { client.objects["\(connection.id)/\($0)"] ?? [] } ?? [] }
    var body: some View {
        VStack(spacing: 0) {
            if database == nil {
                databasesTable.frame(minHeight: 120, idealHeight: 200, maxHeight: 260)
                Divider()
            }
            Form {
                dumpSection
                if connection.allowsWrites { restoreSection }
            }
            .formStyle(.grouped)
            .themedScroll()
        }
        .task {
            if client.databases[connection.id] == nil { await client.loadDatabases(connection) }
            if restoreTarget.isEmpty { restoreTarget = database ?? dbs.first?.name ?? "" }
            if let database {
                chosen = [database]; restoreTarget = database
                if client.objects["\(connection.id)/\(database)"] == nil { await client.loadObjects(connection, database) }
            }
        }
    }

    /// The databases of the server, ticked to go into the dump.
    private var databasesTable: some View {
        Table(dbs.sorted(using: order), sortOrder: $order) {
            TableColumn("") { d in
                Toggle(L("db.dump.include"), isOn: Binding(get: { chosen.contains(d.name) }, set: { if $0 { chosen.insert(d.name) } else { chosen.remove(d.name) } }))
                    .labelsHidden().toggleStyle(.checkbox)
                    .accessibilityIdentifier("db.backup.choose.\(d.name)")
            }
            .width(24)
            TableColumn(L("db.database"), value: \.name) { d in Label(d.name, systemImage: Symbols.database) }
            TableColumn(L("db.col.size"), value: \.sortSize) { d in Text(Format.fileSizeText(d.size)).monospacedDigit().foregroundStyle(.secondary) }
                .width(min: 70, ideal: 100).alignment(.trailing)
        }
        .accessibilityIdentifier("db.backup.databases")
    }

    private var dumpSection: some View {
        Section {
            if let database {
                LabeledContent(L("db.database"), value: database)
                if !objects.isEmpty {
                    DisclosureGroup(tables.isEmpty ? L("db.allTables") : String(format: L("db.someTables"), tables.count)) {
                        ForEach(objects.filter { !$0.view }) { o in
                            let name = connection.kind == "postgres" ? "\(o.schema ?? "public").\(o.name)" : o.name
                            Toggle(name, isOn: Binding(get: { tables.contains(name) }, set: { if $0 { tables.insert(name) } else { tables.remove(name) } }))
                                .toggleStyle(.checkbox)
                                .accessibilityIdentifier("db.backup.table.\(name)")
                        }
                    }
                    .accessibilityIdentifier("db.backup.tables")
                }
            } else {
                LabeledContent(L("db.dump.chosen"), value: chosen.isEmpty ? L("db.dump.noneChosen") : chosen.sorted().joined(separator: ", "))
            }
            Picker(L("db.dumpContent"), selection: $content) {
                Text(L("db.content.all")).tag("all")
                Text(L("db.content.schema")).tag("schema")
                Text(L("db.content.data")).tag("data")
            }
            .pickerStyle(.segmented).accessibilityIdentifier("db.backup.content")
            if content != "data" {
                Toggle(L("db.routines"), isOn: $routines).accessibilityIdentifier("db.backup.routines")
                Toggle(L("db.triggers"), isOn: $triggers).accessibilityIdentifier("db.backup.triggers")
                if connection.kind != "postgres" { Toggle(L("db.events"), isOn: $events).accessibilityIdentifier("db.backup.events") }
            }
            Toggle(L("db.compress"), isOn: $compress).accessibilityIdentifier("db.backup.compress")
            HStack {
                if let last {
                    Label(last, systemImage: Symbols.success).font(.uiCaption).foregroundStyle(Brand.success).textSelection(.enabled)
                        .accessibilityIdentifier("db.backup.last")
                }
                Spacer()
                Button { Task { await dump() } } label: { Label(L("db.dumpButton"), systemImage: Symbols.dump) }
                    .buttonStyle(.borderedProminent).disabled(database == nil && chosen.isEmpty)
                    .accessibilityIdentifier("db.backup.dump")
            }
        } header: {
            Text(L("db.dump"))
        } footer: {
            Text(L("db.dumpHelp")).font(.uiCaption).foregroundStyle(.secondary)
        }
    }

    private var restoreSection: some View {
        Section {
            Picker(L("db.restoreMode"), selection: $createTarget) {
                Text(L("db.restoreExisting")).tag(false)
                Text(L("db.restoreCreate")).tag(true)
            }
            .pickerStyle(.segmented)
            .onChange(of: createTarget) { _, create in restoreTarget = create ? "" : (database ?? dbs.first?.name ?? "") }
            .accessibilityIdentifier("db.backup.restoreMode")
            if createTarget {
                LabeledContent(L("db.newDatabase")) {
                    TextField(L("db.newDatabase"), text: $restoreTarget, prompt: Text(L("db.newDatabasePrompt"))).labelsHidden()
                        .textFieldStyle(.roundedBorder).multilineTextAlignment(.leading)
                        .accessibilityIdentifier("db.backup.restoreName")
                }
            } else {
                Picker(L("db.restoreInto"), selection: $restoreTarget) {
                    if restoreTarget.isEmpty { Text(L("db.chooseDatabase")).tag("") }
                    ForEach(dbs) { Text($0.name).tag($0.name) }
                }
                .accessibilityIdentifier("db.backup.restoreInto")
            }
            HStack {
                Spacer()
                Button { Task { await restore() } } label: { Label(L("db.restoreButton"), systemImage: Symbols.restore) }
                    .buttonStyle(.bordered).disabled(restoreTarget.isEmpty).accessibilityIdentifier("db.backup.restore")
            }
            if database != nil, !objects.isEmpty {
                LabeledContent {
                    Menu {
                        ForEach(objects.filter { !$0.view }) { o in
                            Button(o.name) { Task { await importCSV(o) } }.accessibilityIdentifier("db.backup.importCSV.\(o.name)")
                        }
                    } label: {
                        Label(L("db.importCSVInto"), systemImage: Symbols.importCSV)
                    }
                    .fixedSize()
                    .accessibilityIdentifier("db.backup.importCSV")
                } label: {
                    Text(L("db.importCSV"))
                    Text(L("db.importCSVHelp")).font(.uiCaption).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text(L("db.restore"))
        } footer: {
            Text(L("db.restoreHelp")).font(.uiCaption).foregroundStyle(.secondary)
        }
    }

    func dump() async {
        let list = database.map { [$0] } ?? Array(chosen).sorted()
        let panel = NSSavePanel()
        let stamp = Format.fileStamp().replacingOccurrences(of: "-", with: "")
        panel.nameFieldStringValue = "\(list.count == 1 ? list[0] : connection.kind)-\(stamp).sql\(compress ? ".gz" : "")"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let request: [String: Any] = ["databases": list, "tables": Array(tables).sorted(), "path": url.path, "compress": compress,
                                      "content": content, "routines": routines, "triggers": triggers, "events": events]
        struct Dumped: Decodable { let bytes: Int; let size: Int }
        if let result: Dumped = await client.longRun(String(format: L("db.dumping"), list.joined(separator: ", ")), "dbDump", connection, request, confirm: false) {
            last = String(format: L("db.dumped"), url.lastPathComponent, Format.fileSizeText(result.size))
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
    func restore() async {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "sql") ?? .plainText, .gzip, .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let request: [String: Any] = ["database": restoreTarget, "path": url.path, "create": createTarget]
        struct Restored: Decodable { let bytes: Int }
        if let _: Restored = await client.longRun(String(format: L("db.confirm.restore"), url.lastPathComponent, restoreTarget, connection.title), "dbRestore", connection, request, confirm: true) {
            client.store.notify(L("db.restored"))
            await client.refresh(connection)
        }
    }
    func importCSV(_ object: DBObject) async {
        guard let database else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        struct Imported: Decodable { let rows: Int }
        let request: [String: Any] = ["database": database, "schema": object.schema ?? "", "table": object.name, "path": url.path]
        if let result: Imported = await client.longRun(String(format: L("db.confirm.csv"), url.lastPathComponent, object.name), "dbImportCsv", connection, request, confirm: true) {
            client.store.notify(String(format: L("db.imported"), result.rows))
        }
    }
}
