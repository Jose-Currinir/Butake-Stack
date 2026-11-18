import AppKit
import SwiftUI

// MARK: - Rows of a table

/// Datos: the rows of a table a page at a time, with filters and sorting, edited in place and
/// saved together after the confirmation. Exportar is in the toolbar.
struct TableDataPanel: View {
    @Bindable var client: DatabaseClient
    let connection: DBConnection
    let selection: DBSelection
    @State private var data: DBRows?
    @State private var error: DBProblem?
    @State private var page = 0
    /// Sort columns in order; a click on a header replaces them, ⇧-click adds one.
    @State private var sorts: [Sort] = []
    @State private var filterJoin = "and"
    @State private var filterColumn = ""
    @State private var filterOp = "contains"
    @State private var filterValue = ""
    @State private var filters: [[String: String]] = []
    /// The unsaved edits live in the client (see `PendingEdits`), so they survive leaving the page.
    private var pendingKey: String { DatabaseClient.pendingKey(selection) }
    private var edits: [Int: [Int: String?]] {
        get { client.pendingEdits[pendingKey]?.edits ?? [:] }
        nonmutating set { update { $0.edits = newValue } }
    }
    private var deleted: Set<Int> {
        get { client.pendingEdits[pendingKey]?.deleted ?? [] }
        nonmutating set { update { $0.deleted = newValue } }
    }
    private var inserted: [[String?]] {
        get { client.pendingEdits[pendingKey]?.inserted ?? [] }
        nonmutating set { update { $0.inserted = newValue } }
    }
    /// Writes one change together with the page, filters and sorting it was made under.
    private func update(_ change: (inout PendingEdits) -> Void) {
        var value = client.pendingEdits[pendingKey] ?? PendingEdits()
        change(&value)
        value.page = page
        value.filters = filters
        value.sorts = sorts.map { PendingEdits.Sort(column: $0.column, descending: $0.descending) }
        client.setPending(pendingKey, value)
    }
    /// The first load after the page appears keeps the edits left by the previous visit.
    @State private var restored = false
    @State private var loading = false
    /// Bumped by every load: an answer that arrives after a newer request is dropped.
    @State private var loadGeneration = 0
    struct Sort: Hashable { var column: String; var descending: Bool }
    let pageSize = 100
    var editable: Bool { !(data?.primaryKey.isEmpty ?? true) && !selection.isView && connection.allowsWrites }
    var changes: Int { edits.count + deleted.count + inserted.count }

    private var filterControls: some View {
        HStack(spacing: 8) {
            if !filters.isEmpty {
                Picker(L("db.filter.join"), selection: $filterJoin) {
                    Text(L("db.filter.and")).tag("and")
                    Text(L("db.filter.or")).tag("or")
                }
                .labelsHidden().pickerStyle(.segmented).fixedSize()
                .accessibilityIdentifier("db.data.filter.join")
            }
            Picker(L("db.filter.column"), selection: $filterColumn) {
                ForEach(data?.columns.map(\.name) ?? [], id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden().frame(minWidth: 90, maxWidth: 150).accessibilityIdentifier("db.data.filter.column")
            Picker(L("db.filter.op"), selection: $filterOp) {
                ForEach(Self.operators, id: \.self) { Text(L("db.op.\($0)")).tag($0) }
            }
            .labelsHidden().frame(minWidth: 80, maxWidth: 130).accessibilityIdentifier("db.data.filter.op")
            TextField(L("db.filterValue"), text: $filterValue).textFieldStyle(.roundedBorder).frame(minWidth: 120)
                .disabled(filterOp == "null" || filterOp == "notnull")
                .onSubmit { addFilter() }
                .accessibilityIdentifier("db.data.filter.value")
            Button { addFilter() } label: { Label(L("db.filter"), systemImage: Symbols.filter) }
                .buttonStyle(.bordered).fixedSize().disabled(filterColumn.isEmpty).accessibilityIdentifier("db.data.filter.apply")
            if !filters.isEmpty {
                Button { Task { guard await discardEditsConfirmed() else { return }; filters = []; page = 0; await load() } } label: { Label(L("db.clearFilters"), systemImage: Symbols.remove) }
                    .buttonStyle(.bordered).fixedSize()
                    .accessibilityIdentifier("db.data.filter.clear")
            }
            if loading { ProgressView().controlSize(.small) }
        }
    }

    /// Every operator of a filter (LocalizationTests checks each has its text).
    static let operators = ["contains", "eq", "ne", "starts", "gt", "lt", "ge", "le", "null", "notnull"]

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                filterControls.fixedSize(horizontal: true, vertical: false).padding(10)
            }
            if !filters.isEmpty || !sorts.isEmpty { criteria }
            Divider()
            if let error { DBProblemCard(problem: error).padding(14) }
            if let data {
                DataGrid(columns: data.columns.map(\.name), rows: data.rows + inserted, editable: editable, edits: edits, deleted: deleted,
                         firstNewRow: data.rows.count, sorts: sorts.map { ($0.column, $0.descending) },
                         onEdit: { row, column, value in
                             if row >= data.rows.count { inserted[row - data.rows.count][column] = value }
                             else if data.rows[row][safe: column] == value { edits[row]?[column] = nil; if edits[row]?.isEmpty == true { edits[row] = nil } }
                             else { edits[row, default: [:]][column] = .some(value) }
                         },
                         onSort: { name, adding in
                             Task {
                                 guard await discardEditsConfirmed() else { return }
                                 sorts = Self.sorting(sorts, by: name, adding: adding)
                                 await load()
                             }
                         },
                         onDelete: { rows in
                             for row in rows {
                                 if row >= data.rows.count { inserted.remove(at: row - data.rows.count) } else { deleted.insert(row) }
                             }
                         })
                    .overlay {
                        if data.rows.isEmpty && inserted.isEmpty {
                            ContentUnavailableView(L(filters.isEmpty ? "db.noRows" : "db.noRowsFiltered"), systemImage: Symbols.table,
                                                   description: filters.isEmpty ? nil : Text(L("db.noRowsFilteredDetail")))
                                .accessibilityIdentifier("db.data.empty")
                        }
                    }
            } else if error == nil {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            footer
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    ForEach(["csv", "json", "sql"], id: \.self) { format in
                        Button(L("db.export.\(format)")) { Task { await export(format) } }.accessibilityIdentifier("db.data.export.\(format)")
                    }
                } label: { Label(L("db.export"), systemImage: Symbols.share) }
                    .help(L("db.export.tableHelp")).accessibilityIdentifier("db.toolbar.export")
            }
        }
        .task(id: client.reloads) {
            #if DEBUG
            if filters.isEmpty, sorts.isEmpty, let qa = QAHooks.databaseGrid() {
                filters = qa.filters
                sorts += qa.sorts.map { Sort(column: $0.column, descending: $0.descending) }
            }
            #endif
            if !restored {
                restored = true
                if let saved = client.pendingEdits[pendingKey] {
                    page = saved.page
                    filters = saved.filters
                    sorts = saved.sorts.map { Sort(column: $0.column, descending: $0.descending) }
                    await load(keepEdits: true)
                    return
                }
            }
            // Recargar (⌘R) also reloads: unsaved edits are only dropped if the user agrees.
            guard await discardEditsConfirmed() else { return }
            await load()
        }
    }

    /// Loading again replaces the rows on screen: with unsaved edits the user must agree first.
    func discardEditsConfirmed() async -> Bool {
        guard changes > 0 else { return true }
        return await client.confirmSimple(String(format: L("db.confirm.discardEdits"), changes))
    }

    /// The filters and sort columns in use, each removable.
    private var criteria: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(filters.enumerated()), id: \.offset) { index, f in
                    if index > 0 {
                        Text(L(f["join"] == "or" ? "db.filter.or" : "db.filter.and")).font(.uiCaption.weight(.bold))
                            .foregroundStyle(f["join"] == "or" ? Brand.warning : .secondary)
                    }
                    Button { removeFilter(at: index) } label: {
                        Label("\(f["column"] ?? "") \(L("db.op.\(f["op"] ?? "")")) \(f["value"] ?? "")", systemImage: Symbols.remove)
                    }
                    .buttonStyle(.bordered).controlSize(.small).help(L("db.filter.remove"))
                    .accessibilityIdentifier("db.data.filter.chip.\(index)")
                }
                if !sorts.isEmpty {
                    if !filters.isEmpty { Divider().frame(height: 16) }
                    Image(systemName: Symbols.sort).foregroundStyle(.secondary).accessibilityHidden(true)
                    ForEach(Array(sorts.enumerated()), id: \.offset) { index, s in
                        Button { Task { guard await discardEditsConfirmed() else { return }; sorts.remove(at: index); await load() } } label: {
                            Label("\(index + 1). \(s.column) \(s.descending ? "↓" : "↑")", systemImage: Symbols.remove)
                        }
                        .buttonStyle(.bordered).controlSize(.small).help(L("db.sort.remove"))
                        .accessibilityIdentifier("db.data.sort.chip.\(index)")
                    }
                    Text(L("db.sort.hint")).font(.uiCaption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
        }
        .padding(.bottom, 6)
    }

    private var footer: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if let data {
                    Text(summary(data)).font(.uiCaption.monospacedDigit()).foregroundStyle(.secondary)
                        .accessibilityIdentifier("db.data.summary")
                    if !editable {
                        Label(!connection.allowsWrites ? L("db.mode.readOnlyGrid") : selection.isView ? L("db.readOnlyView") : L("db.readOnlyNoKey"), systemImage: Symbols.certificate)
                            .font(.uiCaption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if editable {
                    Button { inserted.append(Array(repeating: nil, count: data?.columns.count ?? 0)) } label: { Label(L("db.addRow"), systemImage: Symbols.add) }
                        .buttonStyle(.bordered).accessibilityIdentifier("db.data.addRow")
                }
                if changes > 0 {
                    Button { client.pendingEdits[pendingKey] = nil } label: { Label(L("db.discard"), systemImage: Symbols.rollback) }
                        .buttonStyle(.bordered).accessibilityIdentifier("db.data.discard")
                    Button { Task { await save() } } label: { Label(String(format: L("db.saveChanges"), changes), systemImage: Symbols.success) }
                        .buttonStyle(.borderedProminent).keyboardShortcut("s").accessibilityIdentifier("db.data.save")
                }
                Button { page -= 1; Task { await load() } } label: { Label(L("db.page.previous"), systemImage: Symbols.back).labelStyle(.iconOnly) }
                    .help(L("db.page.previous")).disabled(page == 0 || changes > 0).accessibilityIdentifier("db.data.page.previous")
                Text("\(page + 1)").monospacedDigit().accessibilityIdentifier("db.data.page")
                Button { page += 1; Task { await load() } } label: { Label(L("db.page.next"), systemImage: Symbols.forward).labelStyle(.iconOnly) }
                    .help(L("db.page.next"))
                    .disabled(changes > 0 || (data.map { $0.rows.count < $0.pageSize || (($0.page + 1) * $0.pageSize >= ($0.total ?? 0) && $0.totalEstimated != true) } ?? true))
                    .accessibilityIdentifier("db.data.page.next")
            }
            .fixedSize(horizontal: true, vertical: false)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
    }

    func summary(_ data: DBRows) -> String {
        let from = data.rows.isEmpty ? 0 : data.page * data.pageSize + 1
        let total = data.total ?? 0
        let totalText = data.totalCapped == true ? String(format: L("db.totalCapped"), total.formatted())
            : data.totalEstimated == true ? "≈ " + total.formatted() : total.formatted()
        return String(format: L("db.rowsSummary"), from, data.page * data.pageSize + data.rows.count, totalText, data.durationMs ?? 0)
    }
    func addFilter() {
        guard !filterColumn.isEmpty else { return }
        Task {
            guard await discardEditsConfirmed() else { return }
            filters.append(["column": filterColumn, "op": filterOp, "value": filterValue, "join": filters.isEmpty ? "and" : filterJoin])
            filterValue = ""; page = 0
            await load()
        }
    }
    /// The first filter never joins anything: removing it makes the next one the first.
    func removeFilter(at index: Int) {
        Task {
            guard await discardEditsConfirmed() else { return }
            filters.remove(at: index)
            if !filters.isEmpty { filters[0]["join"] = "and" }
            page = 0
            await load()
        }
    }
    /// A plain click sorts by that column alone (again: reverses it); ⇧-click adds it after the
    /// others (again: reverses it; a third time removes it).
    static func sorting(_ sorts: [Sort], by name: String, adding: Bool) -> [Sort] {
        let existing = sorts.first { $0.column == name }
        guard adding else { return [Sort(column: name, descending: existing.map { !$0.descending } ?? false)] }
        var list = sorts
        if let index = list.firstIndex(where: { $0.column == name }) {
            if list[index].descending { list.remove(at: index) } else { list[index].descending = true }
        } else {
            list.append(Sort(column: name, descending: false))
        }
        return list
    }
    var filterRequest: [String: Any] {
        ["database": selection.database ?? "", "schema": selection.schema ?? "", "table": selection.table ?? "",
         "filters": filters, "sorts": sorts.map { ["column": $0.column, "descending": $0.descending] }]
    }
    func export(_ format: String) async {
        var request = filterRequest
        request["source"] = "table"
        await client.export(connection, format: format, suggested: selection.table ?? "tabla", request)
    }
    func load(keepEdits: Bool = false) async {
        loadGeneration += 1
        let generation = loadGeneration
        loading = true
        defer { if generation == loadGeneration { loading = false } }
        do {
            var request = filterRequest
            request["page"] = page
            request["pageSize"] = pageSize
            let value: DBRows = try await client.read("dbRows", connection, request)
            guard generation == loadGeneration else { return }
            data = value; error = nil
            if keepEdits {
                var kept = client.pendingEdits[pendingKey] ?? PendingEdits()
                kept.prune(rows: value.rows.count, columns: value.columns.count)
                client.setPending(pendingKey, kept)
            } else {
                client.pendingEdits[pendingKey] = nil
            }
            if filterColumn.isEmpty || !value.columns.contains(where: { $0.name == filterColumn }) { filterColumn = value.columns.first?.name ?? "" }
        } catch {
            guard generation == loadGeneration else { return }
            self.error = DBProblem.from(error)
        }
    }
    func key(_ row: [String?], _ data: DBRows) -> [String: Any] {
        var key: [String: Any] = [:]
        for name in data.primaryKey {
            if let index = data.columns.firstIndex(where: { $0.name == name }) { key[name] = row[index] ?? NSNull() }
        }
        return key
    }
    func save() async {
        guard let data else { return }
        let names = data.columns.map(\.name)
        let updates: [[String: Any]] = edits.filter { !deleted.contains($0.key) }.map { row, values in
            var set: [String: Any] = [:]
            for (column, value) in values { set[names[column]] = value ?? NSNull() }
            return ["key": key(data.rows[row], data), "values": set]
        }
        let inserts: [[String: Any]] = inserted.map { row in
            var values: [String: Any] = [:]
            for (index, value) in row.enumerated() where value != nil { values[names[index]] = value }
            return values
        }
        let deletes = deleted.sorted().map { key(data.rows[$0], data) }
        struct Applied: Decodable { let applied: Int; let affected: [Int] }
        let request: [String: Any] = ["database": selection.database ?? "", "schema": selection.schema ?? "", "table": selection.table ?? "",
                                      "updates": updates, "inserts": inserts, "deletes": deletes]
        if let _: Applied = await client.change("dbEdit", connection, request, title: String(format: L("db.confirm.edit"), selection.table ?? "", connection.title)) {
            await load()
        }
    }
}
