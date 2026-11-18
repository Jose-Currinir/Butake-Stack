import SwiftUI

/// Where each table of a diagram goes: tables that reference nobody on the left, each table one
/// column to the right of the furthest table it references; long columns wrap.
struct DiagramLayout {
    static let boxWidth: CGFloat = 230
    static let header: CGFloat = 28
    static let row: CGFloat = 18
    static let maxRows = 14
    static let gapX: CGFloat = 90
    static let gapY: CGFloat = 26
    static let perColumn = 8

    var frames: [String: CGRect] = [:]
    var size: CGSize = .zero

    static func height(_ table: DBSchema.Table) -> CGFloat {
        let shown = min(table.columns.count, maxRows)
        return header + CGFloat(shown) * row + (table.columns.count > maxRows ? row : 0) + 8
    }

    init(_ schema: DBSchema) {
        let ids = schema.tables.map(\.id)
        let known = Set(ids)
        var parents: [String: Set<String>] = [:]
        for key in schema.foreignKeys where known.contains(key.to) && key.to != key.from {
            parents[key.from, default: []].insert(key.to)
        }
        // Layer = 1 + the deepest table it references (cycles stop at the first repeat).
        var layer: [String: Int] = [:]
        func depth(_ id: String, _ seen: Set<String>) -> Int {
            if let known = layer[id] { return known }
            let refs = (parents[id] ?? []).filter { !seen.contains($0) }
            let value = refs.isEmpty ? 0 : 1 + (refs.map { depth($0, seen.union([id])) }.max() ?? 0)
            layer[id] = value
            return value
        }
        for id in ids { _ = depth(id, []) }
        let byId = Dictionary(schema.tables.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var x: CGFloat = 0
        var maxY: CGFloat = 0
        for level in Set(layer.values).sorted() {
            let members = ids.filter { layer[$0] == level }.sorted { (byId[$0]?.name ?? "") < (byId[$1]?.name ?? "") }
            for start in stride(from: 0, to: members.count, by: Self.perColumn) {
                var y: CGFloat = 0
                for id in members[start..<min(start + Self.perColumn, members.count)] {
                    guard let table = byId[id] else { continue }
                    let h = Self.height(table)
                    frames[id] = CGRect(x: x, y: y, width: Self.boxWidth, height: h)
                    y += h + Self.gapY
                }
                maxY = max(maxY, y)
                x += Self.boxWidth + Self.gapX
            }
        }
        size = CGSize(width: max(x - Self.gapX, Self.boxWidth), height: max(maxY - Self.gapY, Self.header))
    }

    /// Vertical position of a column inside its table's box (the header when it is not shown).
    static func rowY(_ table: DBSchema.Table, _ column: String?, in frame: CGRect) -> CGFloat {
        guard let column, let index = table.columns.firstIndex(where: { $0.name == column }), index < maxRows else { return frame.minY + header / 2 }
        return frame.minY + header + CGFloat(index) * row + row / 2
    }
}

/// Tables of a database and the foreign keys between them, drawn as boxes and lines. Scroll and
/// zoom to move around; a click on a table shows its relations, its button opens it.
struct SchemaDiagramPanel: View {
    @Bindable var client: DatabaseClient
    let connection: DBConnection
    let database: String
    @State private var schema: DBSchema?
    @State private var layout = DiagramLayout(DBSchema(tables: [], foreignKeys: []))
    @State private var zoom: CGFloat = 1
    @State private var focused: String?
    @State private var error: DBProblem?
    @State private var loading = false
    static let limit = 300
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if let schema {
                    Text(String(format: L("db.diagram.summary"), schema.tables.count, schema.foreignKeys.count)).font(.uiCaption).foregroundStyle(.secondary)
                    if schema.tables.count > Self.limit {
                        Text(String(format: L("db.diagram.limited"), Self.limit)).font(.uiCaption).foregroundStyle(Brand.warningText)
                    }
                }
                if let focused { Label(String(format: L("db.diagram.focused"), focused.split(separator: ".").last.map(String.init) ?? focused), systemImage: Symbols.focus).font(.uiCaption).accessibilityIdentifier("db.diagram.focused") }
                Spacer()
                if loading { ProgressView().controlSize(.small) }
                Image(systemName: Symbols.zoomOut).foregroundStyle(.secondary).accessibilityHidden(true)
                Slider(value: $zoom, in: 0.4...1.6) { Text(L("db.diagram.zoom")) }.labelsHidden().frame(width: 140).accessibilityIdentifier("db.diagram.zoom")
                Image(systemName: Symbols.zoomIn).foregroundStyle(.secondary).accessibilityHidden(true)
            }
            .padding(10)
            Divider()
            if let error {
                DBProblemCard(problem: error).padding(14)
                Spacer()
            } else if let schema, schema.tables.isEmpty {
                ContentUnavailableView(L("db.diagram.empty"), systemImage: Symbols.diagram).accessibilityIdentifier("db.diagram.empty")
            } else if let schema {
                GeometryReader { geometry in
                    ScrollView([.horizontal, .vertical]) {
                        canvas(schema)
                            .scaleEffect(zoom, anchor: .topLeading)
                            .frame(width: (layout.size.width + 60) * zoom, height: (layout.size.height + 60) * zoom, alignment: .topLeading)
                            // Smaller than the view: kept in the top-left corner, not centered.
                            .frame(minWidth: geometry.size.width, minHeight: geometry.size.height, alignment: .topLeading)
                    }
                }
                .background(Color.primary.opacity(0.02))
                .accessibilityIdentifier("db.diagram")
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: client.reloads) { await load() }
    }

    func load() async {
        loading = true; defer { loading = false }
        do {
            let value: DBSchema = try await client.read("dbSchema", connection, ["database": database])
            client.schemas["\(connection.id)/\(database)"] = value
            let shown = DBSchema(tables: Array(value.tables.prefix(Self.limit)), foreignKeys: value.foreignKeys)
            layout = DiagramLayout(shown)
            schema = shown
            error = nil
            #if DEBUG
            if let preset = QAHooks.diagramFocus { focused = shown.tables.first { $0.name == preset }?.id }
            #endif
        } catch { self.error = DBProblem.from(error) }
    }

    func related(_ key: DBSchema.ForeignKey) -> Bool { focused == nil || key.from == focused || key.to == focused }

    func canvas(_ schema: DBSchema) -> some View {
        let byId = Dictionary(schema.tables.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return ZStack(alignment: .topLeading) {
            Canvas { context, _ in
                for key in schema.foreignKeys {
                    guard let from = layout.frames[key.from], let to = layout.frames[key.to], let child = byId[key.from], let parent = byId[key.to] else { continue }
                    let y1 = DiagramLayout.rowY(child, key.columns.first ?? nil, in: from)
                    let y2 = DiagramLayout.rowY(parent, key.refColumns.first ?? nil, in: to)
                    let selfReference = key.from == key.to
                    let rightward = to.minX > from.maxX
                    let start = CGPoint(x: rightward ? from.maxX : from.minX, y: y1)
                    let end = CGPoint(x: selfReference ? from.minX : (rightward ? to.minX : to.maxX), y: y2)
                    let bend: CGFloat = selfReference ? -50 : (rightward ? 45 : -45)
                    var path = Path()
                    path.move(to: start)
                    path.addCurve(to: end, control1: CGPoint(x: start.x + bend, y: start.y), control2: CGPoint(x: end.x + (selfReference ? bend : -bend), y: end.y))
                    let highlighted = focused != nil && related(key)
                    let color: Color = highlighted ? Brand.accent : Color.secondary.opacity(focused == nil ? 0.55 : 0.15)
                    context.stroke(path, with: .color(color), lineWidth: highlighted ? 2 : 1.2)
                    context.fill(Path(ellipseIn: CGRect(x: end.x - 3.5, y: end.y - 3.5, width: 7, height: 7)), with: .color(color))
                }
            }
            .frame(width: layout.size.width, height: layout.size.height)
            ForEach(schema.tables) { table in
                if let frame = layout.frames[table.id] {
                    TableBox(table: table, keys: Set(schema.foreignKeys.filter { $0.from == table.id }.flatMap { $0.columns.compactMap { $0 } }),
                             focused: focused == table.id, dimmed: focused != nil && focused != table.id && !schema.foreignKeys.contains { ($0.from == table.id && $0.to == focused) || ($0.to == table.id && $0.from == focused) },
                             focus: { focused = focused == table.id ? nil : table.id },
                             open: {
                                 client.selection = DBSelection(connection: connection.id, database: database,
                                                                schema: (table.schema ?? "").isEmpty ? nil : table.schema, table: table.name)
                             })
                        .frame(width: frame.width, height: frame.height)
                        .offset(x: frame.minX, y: frame.minY)
                }
            }
        }
        .frame(width: layout.size.width, height: layout.size.height, alignment: .topLeading)
        .padding(30)
    }
}

private struct TableBox: View {
    let table: DBSchema.Table
    let keys: Set<String>
    let focused: Bool
    let dimmed: Bool
    let focus: () -> Void
    let open: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Button(action: focus) {
                    HStack(spacing: 5) {
                        Image(systemName: Symbols.table).font(.drawing(10))
                        Text(table.name ?? "").font(.drawing(12, weight: .semibold)).lineLimit(1)
                        if let schema = table.schema, !schema.isEmpty, schema != "public" {
                            Text(schema).font(.drawing(10)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.borderless).foregroundStyle(.primary).help(L("db.diagram.focus"))
                .accessibilityIdentifier("db.diagram.table.\(table.name ?? "")")
                Button(action: open) { Label(L("db.diagram.open"), systemImage: Symbols.openTable).labelStyle(.iconOnly).font(.drawing(11)) }
                    .buttonStyle(.borderless).help(L("db.diagram.open"))
                    .accessibilityIdentifier("db.diagram.open.\(table.name ?? "")")
            }
            .padding(.horizontal, 8)
            .frame(height: DiagramLayout.header)
            .background(focused ? Brand.accent.opacity(0.25) : Brand.accent.opacity(0.1))
            ForEach(Array(table.columns.prefix(DiagramLayout.maxRows).enumerated()), id: \.offset) { _, column in
                HStack(spacing: 4) {
                    Image(systemName: column.key == "PRI" ? Symbols.key : (keys.contains(column.name ?? "") ? Symbols.link : Symbols.plainColumn))
                        .font(.drawing(column.key == "PRI" || keys.contains(column.name ?? "") ? 8 : 3))
                        .foregroundStyle(column.key == "PRI" ? Brand.warning : (keys.contains(column.name ?? "") ? Brand.accent : .secondary))
                        .frame(width: 12)
                    Text(column.name ?? "").font(.drawing(11, design: .monospaced)).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(column.type ?? "").font(.drawing(10, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                }
                .padding(.horizontal, 8)
                .frame(height: DiagramLayout.row)
            }
            if table.columns.count > DiagramLayout.maxRows {
                Text(String(format: L("db.diagram.more"), table.columns.count - DiagramLayout.maxRows)).font(.drawing(10)).foregroundStyle(.secondary)
                    .padding(.horizontal, 8).frame(height: DiagramLayout.row)
            }
            Spacer(minLength: 0)
        }
        .background(Brand.surface, in: RoundedRectangle(cornerRadius: Radius.row))
        .clipShape(RoundedRectangle(cornerRadius: Radius.row))
        .overlay(RoundedRectangle(cornerRadius: Radius.row).strokeBorder(focused ? Brand.accent : Color.primary.opacity(0.15), lineWidth: focused ? 2 : 1))
        .opacity(dimmed ? 0.4 : 1)
        .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
    }
}
