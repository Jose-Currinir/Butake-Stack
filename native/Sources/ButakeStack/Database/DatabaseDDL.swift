import SwiftUI

/// Forms that change a table's structure. None of them runs anything by itself: "Revisar SQL" asks
/// the engine for the statements, which the confirmation shows before they run.

/// Usual types per engine (any other can be typed).
enum DDLTypes {
    static func common(_ kind: String) -> [String] {
        switch kind {
        case "postgres": ["integer", "bigint", "text", "varchar(255)", "boolean", "numeric(10, 2)", "timestamp with time zone", "date", "uuid", "jsonb"]
        case "sqlite": ["integer", "text", "real", "numeric", "blob"]
        default: ["int", "bigint", "varchar(255)", "text", "tinyint(1)", "decimal(10, 2)", "datetime", "timestamp", "date", "json"]
        }
    }
}

/// A type field with the usual types one click away.
private struct TypeField: View {
    @Binding var text: String
    let kind: String
    var identifier = "db.ddl.type"
    var body: some View {
        HStack(spacing: 4) {
            TextField(L("common.type"), text: $text).textFieldStyle(.roundedBorder).font(.uiCallout.monospaced())
                .accessibilityIdentifier(identifier)
            Menu {
                ForEach(DDLTypes.common(kind), id: \.self) { type in Button(type) { text = type } }
            } label: { Label(L("ddl.commonTypes"), systemImage: Symbols.dropDown).labelStyle(.iconOnly) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help(L("ddl.commonTypes")).accessibilityIdentifier("\(identifier).menu")
        }
    }
}

private func ddlRequest(_ selection: DBSelection, _ extra: [String: Any]) -> [String: Any] {
    var request: [String: Any] = ["database": selection.database ?? "", "schema": selection.schema ?? "", "table": selection.table ?? ""]
    request.merge(extra) { $1 }
    return request
}

@MainActor private func runDDL(_ client: DatabaseClient, _ connection: DBConnection, _ request: [String: Any], title: String) async -> Bool {
    let done: DBRunOutput? = await client.change("dbDdl", connection, request, title: title)
    return done != nil
}

// MARK: - Column

struct ColumnSheet: View {
    let client: DatabaseClient
    let connection: DBConnection
    let selection: DBSelection
    /// The column being changed; nil adds one.
    let original: DBColumn?
    let done: () async -> Void
    @State private var name = ""
    @State private var type = ""
    @State private var nullable = true
    @State private var defaultValue = ""
    init(client: DatabaseClient, connection: DBConnection, selection: DBSelection, original: DBColumn?, done: @escaping () async -> Void) {
        self.client = client; self.connection = connection; self.selection = selection; self.original = original; self.done = done
        _name = State(initialValue: original?.name ?? "")
        _type = State(initialValue: original?.type ?? (["mysql", "mariadb"].contains(connection.kind) ? "varchar(255)" : "text"))
        _nullable = State(initialValue: original?.nullable ?? true)
        _defaultValue = State(initialValue: original?.default ?? "")
    }
    var note: String {
        var lines = [L("ddl.defaultHelp")]
        if original != nil && connection.kind == "sqlite" { lines.append(L("ddl.sqliteAlter")) }
        if original != nil && ["mysql", "mariadb"].contains(connection.kind) { lines.append(L("ddl.mysqlChange")) }
        return lines.joined(separator: " ")
    }
    var body: some View {
        SheetFrame(title: original == nil ? String(format: L("ddl.addColumnTo"), selection.table ?? "") : String(format: L("ddl.editColumnOf"), original?.name ?? ""),
                   symbol: Symbols.column, note: note, width: 560, actionTitle: L("ddl.review"), actionSymbol: Symbols.review, actionID: "db.ddl.review", canAct: !name.trimmingCharacters(in: .whitespaces).isEmpty && !type.isEmpty, cancelID: "db.ddl.cancel",
                   action: review) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text(L("common.name")).foregroundStyle(.secondary)
                    TextField("", text: $name).textFieldStyle(.roundedBorder).accessibilityIdentifier("db.ddl.column.name")
                }
                GridRow {
                    Text(L("common.type")).foregroundStyle(.secondary)
                    TypeField(text: $type, kind: connection.kind)
                }
                GridRow {
                    Text(L("db.col.default")).foregroundStyle(.secondary)
                    TextField(L("ddl.noDefault"), text: $defaultValue).textFieldStyle(.roundedBorder).font(.uiCallout.monospaced())
                        .accessibilityIdentifier("db.ddl.column.default")
                }
                GridRow {
                    Text("")
                    Toggle(L("ddl.nullable"), isOn: $nullable).accessibilityIdentifier("db.ddl.column.nullable")
                }
            }
        }
    }
    func spec(_ name: String, _ type: String, _ nullable: Bool, _ value: String?, auto: Bool = false) -> [String: Any] {
        var spec: [String: Any] = ["name": name, "type": type, "nullable": nullable, "autoIncrement": auto]
        if let value, !value.isEmpty { spec["default"] = value }
        return spec
    }
    func review() async -> Bool {
        let column = spec(name.trimmingCharacters(in: .whitespaces), type.trimmingCharacters(in: .whitespaces), nullable, defaultValue,
                          auto: (original?.extra ?? "").lowercased().contains("auto_increment"))
        let request: [String: Any]
        let title: String
        if let original {
            request = ddlRequest(selection, ["action": "alterColumn", "column": column,
                                             "original": spec(original.name, original.type ?? "", original.nullable, original.default,
                                                              auto: (original.extra ?? "").lowercased().contains("auto_increment"))])
            title = String(format: L("ddl.confirm.alterColumn"), original.name, selection.table ?? "")
        } else {
            request = ddlRequest(selection, ["action": "addColumn", "column": column])
            title = String(format: L("ddl.confirm.addColumn"), name, selection.table ?? "")
        }
        guard await runDDL(client, connection, request, title: title) else { return false }
        await done()
        return true
    }
}

// MARK: - Index

struct IndexSheet: View {
    let client: DatabaseClient
    let connection: DBConnection
    let selection: DBSelection
    let columns: [String]
    let done: () async -> Void
    @State private var name = ""
    @State private var chosen: [String] = []
    @State private var unique = false
    var suggested: String { "idx_\(selection.table ?? "")_\(chosen.joined(separator: "_"))".prefix(60).description }
    var body: some View {
        SheetFrame(title: String(format: L("ddl.addIndexTo"), selection.table ?? ""), symbol: Symbols.index, note: L("ddl.indexHelp"),
                   width: 560, actionTitle: L("ddl.review"), actionSymbol: Symbols.review, actionID: "db.ddl.review", canAct: !chosen.isEmpty, cancelID: "db.ddl.cancel",
                   action: review) {
            ColumnPicker(columns: columns, chosen: $chosen, identifier: "db.ddl.index.column")
            TextField(suggested, text: $name).textFieldStyle(.roundedBorder).accessibilityIdentifier("db.ddl.index.name")
            Toggle(L("ddl.unique"), isOn: $unique).accessibilityIdentifier("db.ddl.index.unique")
        }
    }
    func review() async -> Bool {
        let request = ddlRequest(selection, ["action": "createIndex", "name": name.isEmpty ? suggested : name, "columns": chosen, "unique": unique])
        guard await runDDL(client, connection, request, title: String(format: L("ddl.confirm.addIndex"), selection.table ?? "")) else { return false }
        await done()
        return true
    }
}

/// Columns ticked in the order they are chosen (the order of an index or a key matters).
private struct ColumnPicker: View {
    let columns: [String]
    @Binding var chosen: [String]
    let identifier: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("ddl.columnsInOrder")).font(.uiCaption).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(columns, id: \.self) { column in
                        Toggle(isOn: Binding(get: { chosen.contains(column) }, set: { on in
                            if on { chosen.append(column) } else { chosen.removeAll { $0 == column } }
                        })) {
                            HStack {
                                Text(column).font(.uiCallout.monospaced())
                                if let position = chosen.firstIndex(of: column) { Text("\(position + 1)").font(.uiCaption.monospacedDigit()).foregroundStyle(Brand.accent) }
                            }
                        }
                        .accessibilityIdentifier("\(identifier).\(column)")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 160)
            .padding(8)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

// MARK: - Foreign key

struct ForeignKeySheet: View {
    let client: DatabaseClient
    let connection: DBConnection
    let selection: DBSelection
    let columns: [String]
    let done: () async -> Void
    @State private var name = ""
    @State private var chosen: [String] = []
    @State private var refTable = ""
    @State private var refColumns: [String] = []
    @State private var available: [String] = []
    @State private var onDelete = "no action"
    @State private var onUpdate = "no action"
    var tables: [DBObject] {
        (client.objects["\(connection.id)/\(selection.database ?? "")"] ?? []).filter { !$0.view && ($0.schema ?? "") == (selection.schema ?? $0.schema ?? "") }
    }
    var suggested: String { "fk_\(selection.table ?? "")_\(chosen.joined(separator: "_"))".prefix(60).description }
    var body: some View {
        SheetFrame(title: String(format: L("ddl.addForeignKeyTo"), selection.table ?? ""), symbol: Symbols.foreignKey, note: L("ddl.foreignKeyHelp"),
                   width: 560, actionTitle: L("ddl.review"), actionSymbol: Symbols.review, actionID: "db.ddl.review", canAct: !chosen.isEmpty && !refTable.isEmpty && chosen.count == refColumns.count, cancelID: "db.ddl.cancel",
                   action: review) {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading) {
                    Text(String(format: L("ddl.fromTable"), selection.table ?? "")).font(.uiCallout.weight(.semibold))
                    ColumnPicker(columns: columns, chosen: $chosen, identifier: "db.ddl.fk.column")
                }
                VStack(alignment: .leading) {
                    Picker(L("ddl.references"), selection: $refTable) {
                        Text(L("ddl.chooseTable")).tag("")
                        ForEach(tables) { Text($0.name).tag($0.name) }
                    }
                    .accessibilityIdentifier("db.ddl.fk.table")
                    .onChange(of: refTable) { _, table in Task { await loadColumns(table) } }
                    ColumnPicker(columns: available, chosen: $refColumns, identifier: "db.ddl.fk.refColumn")
                }
            }
            TextField(suggested, text: $name).textFieldStyle(.roundedBorder).accessibilityIdentifier("db.ddl.fk.name")
            HStack {
                Picker(L("ddl.onDelete"), selection: $onDelete) { actions }.fixedSize().accessibilityIdentifier("db.ddl.fk.onDelete")
                Spacer()
                Picker(L("ddl.onUpdate"), selection: $onUpdate) { actions }.fixedSize().accessibilityIdentifier("db.ddl.fk.onUpdate")
            }
        }
        .task { if client.objects["\(connection.id)/\(selection.database ?? "")"] == nil, let db = selection.database { await client.loadObjects(connection, db) } }
    }
    @ViewBuilder var actions: some View {
        ForEach(["no action", "restrict", "cascade", "set null", "set default"], id: \.self) { Text(L("ddl.action.\($0)")).tag($0) }
    }
    func loadColumns(_ table: String) async {
        refColumns = []
        available = []
        guard !table.isEmpty else { return }
        if let s: DBStructure = try? await client.read("dbStructure", connection, ["database": selection.database ?? "", "schema": selection.schema ?? "", "table": table]) {
            available = s.columns.map(\.name)
            // The referenced table's primary key is the usual target.
            refColumns = s.columns.filter { $0.key == "PRI" }.map(\.name).prefix(chosen.count).map { $0 }
        }
    }
    func review() async -> Bool {
        let request = ddlRequest(selection, ["action": "addForeignKey", "name": name.isEmpty ? suggested : name, "columns": chosen,
                                             "refTable": refTable, "refSchema": selection.schema ?? "", "refColumns": refColumns, "onDelete": onDelete, "onUpdate": onUpdate])
        guard await runDDL(client, connection, request, title: String(format: L("ddl.confirm.addForeignKey"), selection.table ?? "", refTable)) else { return false }
        await done()
        return true
    }
}

// MARK: - Rename

struct RenameTableSheet: View {
    let client: DatabaseClient
    let connection: DBConnection
    let selection: DBSelection
    @State private var newName = ""
    var body: some View {
        SheetFrame(title: String(format: L("ddl.renameTitle"), selection.table ?? ""), symbol: Symbols.edit, note: L("ddl.renameHelp"),
                   width: 560, actionTitle: L("ddl.review"), actionSymbol: Symbols.review, actionID: "db.ddl.review", canAct: !newName.trimmingCharacters(in: .whitespaces).isEmpty && newName != selection.table, cancelID: "db.ddl.cancel",
                   action: review) {
            TextField(selection.table ?? "", text: $newName).textFieldStyle(.roundedBorder).accessibilityIdentifier("db.ddl.rename.name")
        }
    }
    func review() async -> Bool {
        let request = ddlRequest(selection, ["action": "renameTable", "newName": newName])
        guard await runDDL(client, connection, request, title: String(format: L("ddl.confirm.rename"), selection.table ?? "", newName)) else { return false }
        if let database = selection.database {
            client.schemas["\(connection.id)/\(database)"] = nil
            await client.loadObjects(connection, database)
            client.selection = DBSelection(connection: connection.id, database: database, schema: selection.schema, table: newName)
        }
        return true
    }
}

// MARK: - New table

struct CreateTableSheet: View {
    let client: DatabaseClient
    let connection: DBConnection
    let database: String
    let schema: String
    struct Row: Identifiable {
        let id = UUID()
        var name: String
        var type: String
        var nullable = true
        var primary = false
        var autoIncrement = false
        var defaultValue = ""
    }
    @State private var name = ""
    @State private var rows: [Row]
    init(client: DatabaseClient, connection: DBConnection, database: String, schema: String) {
        self.client = client; self.connection = connection; self.database = database; self.schema = schema
        let sqlite = connection.kind == "sqlite"
        _rows = State(initialValue: [
            Row(name: "id", type: sqlite ? "integer" : "bigint", nullable: false, primary: true, autoIncrement: true),
            Row(name: "nombre", type: sqlite || connection.kind == "postgres" ? "text" : "varchar(255)", nullable: false),
        ])
    }
    var valid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && !rows.isEmpty
            && rows.allSatisfy { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty && !$0.type.isEmpty }
    }
    var body: some View {
        SheetFrame(title: String(format: L("ddl.newTableIn"), database.isEmpty ? connection.title : database), symbol: Symbols.newTable,
                   note: L("ddl.newTableHelp"), width: 680, actionTitle: L("ddl.review"), actionSymbol: Symbols.review, actionID: "db.ddl.review", canAct: valid, cancelID: "db.ddl.cancel",
                   action: review) {
            TextField(L("ddl.tableName"), text: $name).textFieldStyle(.roundedBorder).accessibilityIdentifier("db.ddl.table.name")
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                GridRow {
                    ForEach([L("common.name"), L("common.type"), L("db.col.default"), "NULL", "PK", L("ddl.autoShort"), ""], id: \.self) {
                        Text($0).font(.uiCaption.weight(.semibold)).foregroundStyle(.secondary)
                    }
                }
                ForEach($rows) { $row in
                    GridRow {
                        TextField("", text: $row.name).textFieldStyle(.roundedBorder).frame(width: 110).accessibilityIdentifier("db.ddl.table.column.\(row.name)")
                        TypeField(text: $row.type, kind: connection.kind, identifier: "db.ddl.table.type.\(row.name)").frame(width: 170)
                        TextField("", text: $row.defaultValue).textFieldStyle(.roundedBorder).frame(width: 90).accessibilityIdentifier("db.ddl.table.default.\(row.id)")
                        Toggle("NULL", isOn: $row.nullable).labelsHidden().disabled(row.primary).accessibilityIdentifier("db.ddl.table.nullable.\(row.id)")
                        Toggle("PK", isOn: $row.primary).labelsHidden().accessibilityIdentifier("db.ddl.table.primary.\(row.id)")
                        Toggle(L("ddl.autoShort"), isOn: $row.autoIncrement).labelsHidden().disabled(!row.primary).accessibilityIdentifier("db.ddl.table.auto.\(row.id)")
                        Button { rows.removeAll { $0.id == row.id } } label: { Label(L("ddl.removeColumn"), systemImage: Symbols.remove).labelStyle(.iconOnly) }
                            .buttonStyle(.borderless).disabled(rows.count == 1).help(L("ddl.removeColumn"))
                            .accessibilityIdentifier("db.ddl.table.remove.\(row.id)")
                    }
                }
            }
            Button { rows.append(Row(name: "", type: DDLTypes.common(connection.kind)[0])) } label: { Label(L("ddl.addColumn"), systemImage: Symbols.add) }.buttonStyle(.bordered)
                .accessibilityIdentifier("db.ddl.table.addColumn")
        }
    }
    func review() async -> Bool {
        let columns: [[String: Any]] = rows.map { row in
            var spec: [String: Any] = ["name": row.name.trimmingCharacters(in: .whitespaces), "type": row.type.trimmingCharacters(in: .whitespaces),
                                       "nullable": row.nullable && !row.primary, "primary": row.primary, "autoIncrement": row.primary && row.autoIncrement]
            if !row.defaultValue.isEmpty { spec["default"] = row.defaultValue }
            return spec
        }
        let request: [String: Any] = ["database": database, "schema": schema, "table": name.trimmingCharacters(in: .whitespaces), "action": "createTable", "columns": columns]
        guard await runDDL(client, connection, request, title: String(format: L("ddl.confirm.createTable"), name, database.isEmpty ? connection.title : database)) else { return false }
        client.schemas["\(connection.id)/\(database)"] = nil
        await client.loadObjects(connection, database)
        return true
    }
}
