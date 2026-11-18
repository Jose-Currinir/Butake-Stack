import AppKit
import SwiftUI

/// The column of connections: Stack's services and the saved ones, each a tree of databases and
/// tables. Selecting a row shows it beside; the arrows and ← → move and fold it with the keyboard.
struct DatabaseConnectionList: View {
    @Bindable var client: DatabaseClient
    var body: some View {
        let builtin = client.connections.filter(\.builtin)
        let saved = client.connections.filter { !$0.builtin }
        VStack(spacing: 0) {
            // A branch that reloads drops its rows for a moment: the list must not clear the selection then.
            List(selection: Binding(get: { client.selection }, set: { if let value = $0 { client.selection = value } })) {
                Section(L("db.section.stack")) {
                    if builtin.isEmpty {
                        Text(L("db.noEngines")).font(.uiCaption).foregroundStyle(.secondary).lineLimit(2...4).selectionDisabled()
                    }
                    ForEach(builtin) { ConnectionNode(client: client, connection: $0) }
                }
                Section(L("db.section.saved")) {
                    if saved.isEmpty {
                        Text(L("db.noSaved")).font(.uiCaption).foregroundStyle(.secondary).lineLimit(2...4).selectionDisabled()
                    }
                    ForEach(saved) { ConnectionNode(client: client, connection: $0) }
                }
            }
            .listStyle(.sidebar)
            .themedScroll()
            .accessibilityIdentifier("db.list")
            // The height and the line of the window's status bar beside it, so both run as one.
            HStack {
                Spacer()
                Button { SettingsRouter.shared.open(.keys) } label: { Label(L("settings.manageKeys"), systemImage: Symbols.key).labelStyle(.iconOnly) }
                    .buttonStyle(.borderless).help(L("settings.manageKeys")).accessibilityIdentifier("keys.open")
            }
            .padding(.horizontal, 10).frame(height: 29)
            .overlay(alignment: .top) { Divider() }
        }
    }
}

/// Opens and closes a branch of the tree through the client, which loads what it holds.
@MainActor private func expansion(_ client: DatabaseClient, _ key: String, load: @escaping () async -> Void) -> Binding<Bool> {
    Binding(get: { client.expanded.contains(key) }, set: { open in
        if open != client.expanded.contains(key) { client.toggle(key, load: load) }
    })
}

private struct ConnectionNode: View {
    @Bindable var client: DatabaseClient
    let connection: DBConnection
    var body: some View {
        let key = connection.id
        DisclosureGroup(isExpanded: expansion(client, key) { await client.loadDatabases(connection) }) {
            if let error = client.errors[key] {
                Label(error.kind == .offline ? L("db.noConnection") : error.title, systemImage: error.symbol)
                    .font(.uiCaption).foregroundStyle(Brand.dangerText).lineLimit(2)
                    .help(error.message).selectionDisabled()
                    .accessibilityIdentifier("db.list.error.\(key)")
            }
            ForEach(client.databases[key] ?? []) { database in
                DatabaseNode(client: client, connection: connection, database: database)
            }
        } label: {
            label
        }
        .tag(DBSelection(connection: key))
        .accessibilityIdentifier("db.list.connection.\(key)")
        .contextMenu {
            if client.isConnected(key) {
                Button { Task { await client.disconnect(connection) } } label: { Label(L("db.disconnect"), systemImage: Symbols.disconnect) }
                    .accessibilityIdentifier("db.list.menu.disconnect")
            } else {
                Button { Task { client.selection = DBSelection(connection: key); await client.connect(connection) } } label: {
                    Label(L("db.connect"), systemImage: Symbols.connect)
                }
                .accessibilityIdentifier("db.list.menu.connect")
            }
            Button { client.copyURL(connection) } label: { Label(L("db.copyURL"), systemImage: Symbols.copy) }
                .accessibilityIdentifier("db.list.menu.copyURL")
            if !connection.builtin {
                Divider()
                Button { client.editing = connection } label: { Label(L("db.editConnectionEllipsis"), systemImage: Symbols.edit) }
                    .accessibilityIdentifier("db.list.menu.edit")
                Button(role: .destructive) { Task { await client.delete(connection) } } label: {
                    Label(L("db.deleteConnection"), systemImage: Symbols.delete)
                }
                .accessibilityIdentifier("db.list.menu.delete")
            }
        }
    }

    private var label: some View {
        HStack(spacing: 8) {
            TechLogo(tech: connection.tech, size: 20)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(connection.title).font(.uiBody).lineLimit(1)
                    if client.isConnected(connection.id) {
                        StatusDot(color: Brand.success, symbol: Symbols.success, label: L("db.connected"))
                    }
                    if connection.production {
                        Text(L("db.mode.productionShort")).font(.uiCaption2.weight(.bold)).foregroundStyle(.white)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Brand.danger, in: RoundedRectangle(cornerRadius: 3))  // radius 3: outside the Radius scale, kept as it was
                            .help(L("db.mode.production"))
                    }
                    if connection.readOnly {
                        Image(systemName: Symbols.readOnly).font(.uiCaption2).foregroundStyle(.secondary).help(L("db.mode.readOnly"))
                            .accessibilityLabel(L("db.mode.readOnly"))
                    }
                }
                Text(address).font(.uiCaption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(address)
            }
            Spacer(minLength: 0)
            if client.loading.contains(connection.id) { ProgressView().controlSize(.mini) }
        }
    }

    private var address: String {
        if connection.kind == "sqlite" { return connection.path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "" }
        return "\(connection.ssh != nil ? "SSH · " : "")\(connection.host):\(connection.port)"
    }
}

private struct DatabaseNode: View {
    @Bindable var client: DatabaseClient
    let connection: DBConnection
    let database: DBDatabase
    @State private var dropTargeted = false
    var body: some View {
        let key = "\(connection.id)/\(database.name)"
        let selection = DBSelection(connection: connection.id, database: database.name)
        if connection.isSQL {
            DisclosureGroup(isExpanded: expansion(client, key) { await client.loadObjects(connection, database.name) }) {
                if let error = client.errors[key] {
                    Label(error.title, systemImage: error.symbol).font(.uiCaption).foregroundStyle(Brand.dangerText).lineLimit(2)
                        .help(error.message).selectionDisabled()
                        .accessibilityIdentifier("db.list.error.\(key)")
                }
                objects(key)
            } label: {
                label
            }
            .tag(selection)
            .contextMenu { menu(key) }
            .dropDestination(for: URL.self) { urls, _ in
                guard connection.allowsWrites, let file = urls.first(where: DatabaseClient.isSQLDump) else {
                    client.store.notify(L("db.drop.rejected"))
                    return false
                }
                Task { await client.restore(file, into: database.name, of: connection) }
                return true
            } isTargeted: { dropTargeted = $0 }
            .background(RoundedRectangle(cornerRadius: Radius.small).fill(dropTargeted ? Brand.accent.opacity(0.15) : .clear).padding(.horizontal, -4))
            .accessibilityIdentifier("db.list.database.\(database.name)")
        } else {
            label.tag(selection).accessibilityIdentifier("db.list.database.\(database.name)")
        }
    }

    /// The same as what the row offers: reload what it holds, copy its name and, where the connection
    /// writes, restore a file into it (a file dropped on the row does the same).
    @ViewBuilder private func menu(_ key: String) -> some View {
        Button { Task { await client.loadObjects(connection, database.name) } } label: { Label(L("menu.reload"), systemImage: Symbols.reload) }
            .accessibilityIdentifier("db.list.menu.database.reload")
        Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(database.name, forType: .string) } label: {
            Label(L("db.copyName"), systemImage: Symbols.copy)
        }
        .accessibilityIdentifier("db.list.menu.database.copy")
        if connection.allowsWrites {
            Divider()
            Button { Task { await client.chooseAndRestore(into: database.name, of: connection) } } label: {
                Label(L("db.restoreFileEllipsis"), systemImage: Symbols.restore)
            }
            .accessibilityIdentifier("db.list.menu.database.restore")
        }
    }

    private var label: some View {
        HStack(spacing: 6) {
            Label {
                Text(connection.isRedis ? String(format: L("db.redis.database"), database.name) : database.name).font(.uiBody).lineLimit(1)
                    .foregroundStyle(database.system ? .secondary : .primary)
            } icon: {
                Image(systemName: connection.isRedis ? Symbols.database : Symbols.database)
            }
            Spacer(minLength: 0)
            if connection.isRedis, let keys = database.tables { Text("\(keys)").font(.uiCaption.monospacedDigit()).foregroundStyle(.secondary) }
            if client.loading.contains("\(connection.id)/\(database.name)") { ProgressView().controlSize(.mini) }
        }
    }

    @ViewBuilder private func objects(_ key: String) -> some View {
        let list = client.objects[key] ?? []
        let schemas = Array(Set(list.compactMap(\.schema).filter { !$0.isEmpty })).sorted()
        if schemas.count > 1 || (schemas.first.map { $0 != "public" } ?? false) {
            ForEach(schemas, id: \.self) { schema in
                Text(schema).font(.uiCaption.weight(.semibold)).foregroundStyle(.secondary).selectionDisabled()
                ForEach(list.filter { $0.schema == schema }) { ObjectNode(client: client, connection: connection, database: database.name, object: $0) }
            }
        } else {
            ForEach(list) { ObjectNode(client: client, connection: connection, database: database.name, object: $0) }
        }
    }
}

private struct ObjectNode: View {
    let client: DatabaseClient
    let connection: DBConnection
    let database: String
    let object: DBObject
    private var selection: DBSelection {
        DBSelection(connection: connection.id, database: database, schema: object.schema.flatMap { $0.isEmpty ? nil : $0 },
                    table: object.name, isView: object.view)
    }
    var body: some View {
        let unsaved = client.pendingCount(DatabaseClient.pendingKey(selection))
        Label(object.name, systemImage: object.view ? Symbols.databaseView : Symbols.table)
            .font(.uiBody).lineLimit(1)
            .tag(selection)
            .badge(unsaved)
            .help(unsaved > 0 ? String(format: L("db.unsavedHelp"), unsaved) : "")
            .contextMenu {
                Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(object.name, forType: .string) } label: {
                    Label(L("db.copyName"), systemImage: Symbols.copy)
                }
                .accessibilityIdentifier("db.list.menu.table.copy")
            }
            .accessibilityIdentifier("db.list.table.\(object.name)")
    }
}
