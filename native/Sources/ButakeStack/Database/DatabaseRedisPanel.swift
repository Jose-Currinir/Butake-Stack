import SwiftUI

/// A Redis key in the list (a table row needs an identity).
struct RedisKeyRow: Identifiable, Hashable {
    let id: String
}

/// The keys of a Redis database that match a pattern, and the value of the one selected.
struct RedisKeysPanel: View {
    @Bindable var client: DatabaseClient
    let connection: DBConnection
    let database: String
    @State private var pattern = "*"
    @State private var searched = "*"
    @State private var keys: [RedisKeyRow] = []
    @State private var selected: RedisKeyRow.ID?
    @State private var order = [KeyPathComparator(\RedisKeyRow.id)]
    /// Column widths, order and visibility the user chose, kept with the window.
    @SceneStorage("table.db.redisKeys") private var redisColumns: TableColumnCustomization<RedisKeyRow> = TableColumnCustomization()
    @State private var value: RedisValue?
    @State private var error: DBProblem?
    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack {
                    TextField(L("db.redis.pattern"), text: $pattern).textFieldStyle(.roundedBorder).onSubmit { Task { await load() } }
                        .accessibilityIdentifier("db.redis.pattern")
                    Button { Task { await load() } } label: { Label(L("db.redis.search"), systemImage: Symbols.search) }
                        .buttonStyle(.bordered).accessibilityIdentifier("db.redis.search")
                }
                .padding(10)
                if let error { DBProblemCard(problem: error).padding(10) }
                Table(keys.sorted(using: order), selection: $selected, sortOrder: $order, columnCustomization: $redisColumns) {
                    TableColumn(L("db.redis.key"), value: \.id) { row in
                        Text(row.id).font(.uiMonospaced).lineLimit(1).truncationMode(.middle).help(row.id)
                    }.customizationID("key")
                }
                .overlay {
                    if keys.isEmpty && error == nil {
                        ContentUnavailableView.search(text: searched).accessibilityIdentifier("db.redis.empty")
                    }
                }
                .accessibilityIdentifier("db.redis.keys")
                Divider()
                Text(String(format: L("db.redis.count"), keys.count)).font(.uiCaption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 8)
            }
            .frame(minWidth: 200, idealWidth: 240)
            Group {
                if let value {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(value.key).font(.uiHeadline.monospaced()).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                            Chip(text: value.type, symbol: Symbols.redisType, tint: Brand.info)
                            Text(String(format: L("db.redis.ttl"), value.ttl.text)).font(.uiCaption.monospacedDigit()).foregroundStyle(.secondary)
                            Spacer()
                            if connection.allowsWrites {
                                Button(role: .destructive) { Task { await delete(value.key) } } label: {
                                    Label(L("db.redis.deleteKey"), systemImage: Symbols.delete)
                                }
                                .buttonStyle(.bordered).accessibilityIdentifier("db.redis.delete")
                            }
                        }
                        ScrollView {
                            Text(value.value.text).font(.uiMonospaced).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .accessibilityIdentifier("db.redis.value")
                    }
                    .padding(14)
                } else {
                    ContentUnavailableView(L("db.redis.pick"), systemImage: Symbols.key)
                }
            }
            .frame(minWidth: 220, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .task(id: client.reloads) { await load() }
        .onChange(of: selected) { _, key in
            value = nil
            if let key { Task { await open(key) } }
        }
    }
    func load() async {
        do {
            let result: RedisKeys = try await client.read("dbRedisKeys", connection, ["database": database, "pattern": pattern])
            keys = result.keys.sorted().map(RedisKeyRow.init(id:)); error = nil
            searched = pattern
        } catch { self.error = DBProblem.from(error) }
    }
    func open(_ key: String) async {
        do { value = try await client.read("dbRedisValue", connection, ["database": database, "key": key]) } catch { self.error = DBProblem.from(error) }
    }
    func delete(_ key: String) async {
        if let _: RedisReply = await client.change("dbRedisDelete", connection, ["database": database, "keys": [key]], title: String(format: L("db.confirm.redisDelete"), key)) {
            value = nil
            selected = nil
            await load()
        }
    }
}
