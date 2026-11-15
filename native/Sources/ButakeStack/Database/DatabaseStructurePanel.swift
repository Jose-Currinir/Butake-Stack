import AppKit
import SwiftUI

// MARK: - Structure

/// A column of the structure with its position (the order a table declares them).
struct StructureColumnRow: Identifiable {
    let id: Int
    let column: DBColumn
    var name: String { column.name }
    var type: String { column.type ?? "" }
    var defaultValue: String { column.default ?? "" }
    var key: String { column.key ?? "" }
}

struct StructureIndexRow: Identifiable {
    let id: Int
    let index: DBIndex
    var name: String { index.name ?? "" }
    var columns: String { index.columns ?? "" }
    var unique: String { index.unique ? "1" : "0" }
}

struct StructureForeignKeyRow: Identifiable {
    let id: Int
    let key: DBForeignKey
    var name: String { key.name ?? "" }
    var columns: String { key.columns ?? "" }
    var references: String { key.references ?? "" }
}

/// Estructura: the columns, indexes and foreign keys of a table in resizable panes, and its DDL.
struct StructurePanel: View {
    @Bindable var client: DatabaseClient
    let connection: DBConnection
    let selection: DBSelection
    @State private var structure: DBStructure?
    @State private var error: DBProblem?
    @State private var sheet: DDLSheet?
    @State private var columnOrder = [KeyPathComparator(\StructureColumnRow.id)]
    @State private var indexOrder = [KeyPathComparator(\StructureIndexRow.name)]
    @State private var keyOrder = [KeyPathComparator(\StructureForeignKeyRow.name)]
    @State private var pickedColumn: StructureColumnRow.ID?
    var canChange: Bool { connection.allowsWrites && !selection.isView }
    var body: some View {
        Group {
            if let error {
                VStack { DBProblemCard(problem: error).padding(14); Spacer() }
            } else if let s = structure {
                VSplitView {
                    columnsPane(s).frame(minHeight: 150, idealHeight: 260)
                    HSplitView {
                        indexesPane(s).frame(minWidth: 180)
                        foreignKeysPane(s).frame(minWidth: 180)
                    }
                    .frame(minHeight: 110, idealHeight: 160)
                    ddlPane(s).frame(minHeight: 90, idealHeight: 140)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: client.reloads) {
            await load()
            #if DEBUG
            // Screenshots: column, index, foreignKey or rename.
            switch QAHooks.databaseSheet {
            case "column": sheet = .column(structure?.columns.last)
            case "index": sheet = .index
            case "foreignKey": sheet = .foreignKey
            case "rename": sheet = .rename
            default: break
            }
            #endif
        }
        .sheet(item: $sheet) { which in
            Group {
                switch which {
                case .column(let original):
                    ColumnSheet(client: client, connection: connection, selection: selection, original: original) { await changed() }
                case .index:
                    IndexSheet(client: client, connection: connection, selection: selection, columns: structure?.columns.map(\.name) ?? []) { await changed() }
                case .foreignKey:
                    ForeignKeySheet(client: client, connection: connection, selection: selection, columns: structure?.columns.map(\.name) ?? []) { await changed() }
                case .rename:
                    RenameTableSheet(client: client, connection: connection, selection: selection)
                }
            }
            .themedSheet()
        }
    }

    /// The title of a pane and its actions, above its table. When the buttons don't fit whole (a
    /// narrow pane, larger text) they go in a menu with their names instead of being cut.
    private func pane<Trailing: View, Content: View>(_ title: String, id: String, @ViewBuilder trailing: () -> Trailing, @ViewBuilder content: () -> Content) -> some View {
        let actions = trailing()
        return VStack(spacing: 0) {
            HStack {
                Text(title).font(.uiHeadline).lineLimit(1).fixedSize()
                Spacer(minLength: 8)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { actions }.fixedSize()
                    Menu { actions } label: { Label(L("db.paneActions"), systemImage: Symbols.more) }
                        .fixedSize().accessibilityIdentifier("db.structure.\(id).menu")
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            content()
        }
    }

    private func columnsPane(_ s: DBStructure) -> some View {
        let rows = s.columns.enumerated().map { StructureColumnRow(id: $0.offset, column: $0.element) }.sorted(using: columnOrder)
        return pane(L("db.columns"), id: "columns") {
            if canChange {
                Button { sheet = .column(nil) } label: { Label(L("ddl.addColumnEllipsis"), systemImage: Symbols.add) }
                    .buttonStyle(.bordered).controlSize(.small).accessibilityIdentifier("db.structure.addColumn")
            }
        } content: {
            Table(rows, selection: $pickedColumn, sortOrder: $columnOrder) {
                TableColumn(L("db.col.position"), value: \.id) { row in Text("\(row.id + 1)").monospacedDigit().foregroundStyle(.secondary) }
                    .width(min: 28, ideal: 36)
                TableColumn(L("common.name"), value: \.name) { row in
                    HStack(spacing: 4) {
                        if row.key == "PRI" {
                            Image(systemName: Symbols.key).foregroundStyle(Brand.warning).help(L("db.primaryKey"))
                                .accessibilityLabel(L("db.primaryKey"))
                        }
                        Text(row.name).font(.uiMonospaced)
                    }
                }
                .width(min: 90, ideal: 140)
                TableColumn(L("common.type"), value: \.type) { row in Text(row.type).font(.uiMonospaced).foregroundStyle(.secondary) }
                    .width(min: 70, ideal: 110)
                TableColumn(L("db.col.null")) { row in Text(row.column.nullable ? "NULL" : "NOT NULL").font(.uiCaption).foregroundStyle(.secondary) }
                    .width(min: 60, ideal: 80)
                TableColumn(L("db.col.default"), value: \.defaultValue) { row in
                    Text(row.column.default ?? "—").font(.uiMonospaced).foregroundStyle(.secondary).lineLimit(1).help(row.defaultValue)
                }
                .width(min: 60, ideal: 100)
                TableColumn(L("db.col.key"), value: \.key) { row in Text(row.key).font(.uiCaption) }
                    .width(min: 40, ideal: 60)
                TableColumn(L("db.col.extra")) { row in Text(row.column.extra ?? "").font(.uiCaption).foregroundStyle(.secondary).lineLimit(1) }
                    .width(min: 40, ideal: 90)
                TableColumn("") { row in
                    if canChange {
                        Menu {
                            Button(L("ddl.editColumn")) { sheet = .column(row.column) }
                                .accessibilityIdentifier("db.structure.column.edit.\(row.name)")
                            Button(L("ddl.dropColumn"), role: .destructive) { Task { await dropColumn(row.name) } }
                                .accessibilityIdentifier("db.structure.column.drop.\(row.name)")
                        } label: { Label(L("db.structure.columnActions"), systemImage: Symbols.more).labelStyle(.iconOnly) }
                            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                            .help(L("db.structure.columnActions"))
                            .accessibilityIdentifier("db.structure.column.\(row.name)")
                    }
                }
                .width(28)
            }
            .contextMenu(forSelectionType: StructureColumnRow.ID.self) { ids in
                if canChange, let id = ids.first, let column = s.columns[safe: id] {
                    Button(L("ddl.editColumn")) { sheet = .column(column) }.accessibilityIdentifier("db.structure.menu.edit")
                    Button(L("ddl.dropColumn"), role: .destructive) { Task { await dropColumn(column.name) } }
                        .accessibilityIdentifier("db.structure.menu.drop")
                }
            } primaryAction: { ids in
                if canChange, let id = ids.first, let column = s.columns[safe: id] { sheet = .column(column) }
            }
            .accessibilityIdentifier("db.structure.columns")
        }
    }

    private func indexesPane(_ s: DBStructure) -> some View {
        let rows = s.indexes.enumerated().map { StructureIndexRow(id: $0.offset, index: $0.element) }.sorted(using: indexOrder)
        return pane(L("db.indexes"), id: "indexes") {
            if canChange {
                Button { sheet = .index } label: { Label(L("ddl.addIndex"), systemImage: Symbols.add) }
                    .buttonStyle(.bordered).controlSize(.small).accessibilityIdentifier("db.structure.addIndex")
            }
        } content: {
            Table(rows, sortOrder: $indexOrder) {
                TableColumn(L("common.name"), value: \.name) { row in
                    HStack(spacing: 6) {
                        Text(row.name).lineLimit(1)
                        if row.index.unique { Chip(text: "UNIQUE", tint: Brand.info) }
                    }
                }
                TableColumn(L("db.columns"), value: \.columns) { row in Text(row.columns).font(.uiMonospaced).foregroundStyle(.secondary).lineLimit(1) }
                TableColumn("") { row in
                    if canChange && Self.droppable(row.index) {
                        Button { Task { await dropIndex(row.name) } } label: { Label(L("ddl.dropIndex"), systemImage: Symbols.delete).labelStyle(.iconOnly) }
                            .buttonStyle(.borderless).help(L("ddl.dropIndex")).accessibilityIdentifier("db.structure.dropIndex.\(row.name)")
                    }
                }
                .width(28)
            }
            .overlay { if rows.isEmpty { Text(L("db.noIndexes")).foregroundStyle(.secondary) } }
            .accessibilityIdentifier("db.structure.indexes")
        }
    }

    private func foreignKeysPane(_ s: DBStructure) -> some View {
        let rows = s.foreignKeys.enumerated().map { StructureForeignKeyRow(id: $0.offset, key: $0.element) }.sorted(using: keyOrder)
        let sqlite = connection.kind == "sqlite"
        return pane(L("db.foreignKeys"), id: "foreignKeys") {
            if canChange && !sqlite {
                Button { sheet = .foreignKey } label: { Label(L("ddl.addForeignKey"), systemImage: Symbols.add) }
                    .buttonStyle(.bordered).controlSize(.small).accessibilityIdentifier("db.structure.addForeignKey")
            }
        } content: {
            Table(rows, sortOrder: $keyOrder) {
                TableColumn(L("common.name"), value: \.name) { row in Text(row.name).lineLimit(1) }
                TableColumn(L("db.col.references"), value: \.references) { row in
                    Text("\(row.columns) → \(row.references)").font(.uiMonospaced).foregroundStyle(.secondary).lineLimit(1)
                        .help("\(row.columns) → \(row.references)")
                }
                TableColumn("") { row in
                    if canChange && !sqlite {
                        Button { Task { await dropForeignKey(row.name) } } label: { Label(L("ddl.dropForeignKey"), systemImage: Symbols.delete).labelStyle(.iconOnly) }
                            .buttonStyle(.borderless).help(L("ddl.dropForeignKey")).accessibilityIdentifier("db.structure.dropForeignKey.\(row.name)")
                    }
                }
                .width(28)
            }
            .overlay {
                if rows.isEmpty {
                    Text(L(canChange && sqlite ? "ddl.sqliteForeignKeys" : "db.noForeignKeys")).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).padding()
                }
            }
            .accessibilityIdentifier("db.structure.foreignKeys")
        }
    }

    private func ddlPane(_ s: DBStructure) -> some View {
        pane(L("db.structure.ddl"), id: "ddl") {
            Group {
                Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s.ddl, forType: .string); client.store.notify(L("db.copied")) } label: {
                    Label(L("common.copy"), systemImage: Symbols.copy)
                }
                .buttonStyle(.bordered).controlSize(.small).accessibilityIdentifier("db.structure.copyDDL")
                if connection.allowsWrites {
                    if !selection.isView {
                        Button { sheet = .rename } label: { Label(L("ddl.renameTable"), systemImage: Symbols.edit) }
                            .buttonStyle(.bordered).controlSize(.small).accessibilityIdentifier("db.structure.rename")
                    }
                    Button(role: .destructive) { Task { await dropTable() } } label: {
                        Label(selection.isView ? L("ddl.dropView") : L("ddl.dropTable"), systemImage: Symbols.delete)
                    }
                    .buttonStyle(.bordered).controlSize(.small).accessibilityIdentifier("db.structure.dropTable")
                }
            }
        } content: {
            ScrollView {
                Text(s.ddl).font(.uiMonospaced).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12)
                    .padding(.bottom, 10)
            }
            .accessibilityIdentifier("db.structure.ddlText")
        }
    }

    enum DDLSheet: Identifiable {
        case column(DBColumn?), index, foreignKey, rename
        var id: String {
            switch self {
            case .column(let c): "column.\(c?.name ?? "")"
            case .index: "index"
            case .foreignKey: "foreignKey"
            case .rename: "rename"
            }
        }
    }
    /// Indexes that back a primary key (or SQLite's automatic ones) are not dropped by themselves.
    static func droppable(_ index: DBIndex) -> Bool {
        let name = index.name ?? ""
        return !name.isEmpty && name != "PRIMARY" && !name.hasSuffix("_pkey") && !["pk", "u"].contains(index.type ?? "") && !name.hasPrefix("sqlite_autoindex")
    }
    var base: [String: Any] { ["database": selection.database ?? "", "schema": selection.schema ?? "", "table": selection.table ?? ""] }
    func load() async {
        do {
            structure = try await client.read("dbStructure", connection, base)
            error = nil
        } catch { self.error = DBProblem.from(error) }
    }
    /// After a change: the structure, the tree and the completion list show it.
    func changed() async {
        await load()
        if let database = selection.database {
            client.schemas["\(connection.id)/\(database)"] = nil
            await client.loadObjects(connection, database)
        }
    }
    func ddl(_ extra: [String: Any], title: String, typedName: String? = nil) async -> Bool {
        var request = base
        request.merge(extra) { $1 }
        let done: DBRunOutput? = await client.change("dbDdl", connection, request, title: title, typedName: typedName)
        return done != nil
    }
    func dropColumn(_ name: String) async {
        if await ddl(["action": "dropColumn", "name": name], title: String(format: L("ddl.confirm.dropColumn"), name, selection.table ?? ""), typedName: name) { await changed() }
    }
    func dropIndex(_ name: String) async {
        if await ddl(["action": "dropIndex", "name": name], title: String(format: L("ddl.confirm.dropIndex"), name)) { await changed() }
    }
    func dropForeignKey(_ name: String) async {
        if await ddl(["action": "dropForeignKey", "name": name], title: String(format: L("ddl.confirm.dropForeignKey"), name)) { await changed() }
    }
    func dropTable() async {
        let table = selection.table ?? ""
        if await ddl(["action": "dropTable", "view": selection.isView], title: String(format: L("ddl.confirm.dropTable"), table, connection.title), typedName: table) {
            if let database = selection.database {
                client.schemas["\(connection.id)/\(database)"] = nil
                await client.loadObjects(connection, database)
                client.selection = DBSelection(connection: connection.id, database: database)
            }
        }
    }
}
