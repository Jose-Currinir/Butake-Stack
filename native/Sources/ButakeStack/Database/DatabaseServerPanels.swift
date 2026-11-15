import AppKit
import SwiftUI

// MARK: - Users

extension DBUser {
    var account: String { host.map { $0.isEmpty ? (name ?? "") : "\(name ?? "")@\($0)" } ?? (name ?? "") }
    var grantsText: String { grants.joined(separator: " · ") }
}

struct UsersPanel: View {
    @Bindable var client: DatabaseClient
    let connection: DBConnection
    @State private var users: [DBUser] = []
    @State private var error: DBProblem?
    @State private var showSystem = false
    @State private var creating = false
    @State private var picked: DBUser.ID?
    @State private var order = [KeyPathComparator(\DBUser.account)]
    var shown: [DBUser] { (showSystem ? users : users.filter { !$0.system || $0.name == "root" || $0.name == "postgres" }).sorted(using: order) }
    var body: some View {
        VStack(spacing: 0) {
            if let error { DBProblemCard(problem: error).padding(14) }
            Table(shown, selection: $picked, sortOrder: $order) {
                TableColumn(L("common.user"), value: \.account) { user in
                    Label {
                        Text(user.account).foregroundStyle(user.system ? .secondary : .primary)
                    } icon: {
                        Image(systemName: Symbols.user)
                    }
                    .help(user.locked ? L("db.userLocked") : user.account)
                }
                .width(min: 140, ideal: 200)
                TableColumn(L("db.col.grants"), value: \.grantsText) { user in
                    Text(user.grantsText).font(.uiSubheadline.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                        .truncationMode(.tail).help(user.grants.joined(separator: "\n"))
                }
                .width(min: 160, ideal: 300)
                TableColumn("") { user in
                    if !user.system && connection.allowsWrites {
                        Button { Task { await drop(user) } } label: {
                            Label(L("db.dropUser"), systemImage: Symbols.delete).labelStyle(.iconOnly)
                        }
                        .buttonStyle(.borderless).help(L("db.dropUser"))
                        .accessibilityIdentifier("db.users.drop.\(user.account)")
                    }
                }
                .width(28)
            }
            .contextMenu(forSelectionType: DBUser.ID.self) { ids in
                if connection.allowsWrites, let user = users.first(where: { ids.contains($0.id) }), !user.system {
                    Button(role: .destructive) { Task { await drop(user) } } label: { Label(L("db.dropUser"), systemImage: Symbols.delete) }
                        .accessibilityIdentifier("db.users.menu.drop")
                }
            }
            .overlay {
                if shown.isEmpty && error == nil {
                    ContentUnavailableView(L("db.noUsers"), systemImage: Symbols.users).accessibilityIdentifier("db.users.empty")
                }
            }
            .accessibilityIdentifier("db.users.table")
            Divider()
            HStack {
                if users.contains(where: { $0.system && $0.name != "root" && $0.name != "postgres" }) {
                    Toggle(L("db.showSystemUsers"), isOn: $showSystem).toggleStyle(.checkbox)
                        .accessibilityIdentifier("db.users.showSystem")
                }
                Spacer()
                if connection.allowsWrites {
                    Button { creating = true } label: { Label(L("db.newUserEllipsis"), systemImage: Symbols.newUser) }
                        .buttonStyle(.bordered).accessibilityIdentifier("db.users.new")
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .task(id: client.reloads) { await load() }
        .sheet(isPresented: $creating) {
            NewUserSheet(client: client, connection: connection) { await load() }.themedSheet()
        }
    }
    func load() async {
        do { users = try await client.read("dbUsers", connection); error = nil } catch { self.error = DBProblem.from(error) }
        if client.databases[connection.id] == nil { await client.loadDatabases(connection) }
    }
    func drop(_ user: DBUser) async {
        if let _: DBRunOutput = await client.change("dbDropUser", connection, ["name": user.name ?? "", "host": user.host ?? ""], title: String(format: L("db.confirm.dropUser"), user.name ?? "")) {
            await load()
        }
    }
}

/// A new account: its name, where it connects from and what it may touch. The password is
/// generated, kept in the Keychain and copied to the clipboard.
private struct NewUserSheet: View {
    let client: DatabaseClient
    let connection: DBConnection
    let done: () async -> Void
    @State private var name = ""
    @State private var host = "%"
    @State private var database = ""
    @State private var access = "all"
    var body: some View {
        SheetFrame(title: L("db.newUser"), symbol: Symbols.newUser, note: L("db.newUserHelp"), width: 520,
                   actionTitle: L("common.create"), actionSymbol: Symbols.add, actionID: "db.newUser.create",
                   canAct: !name.trimmingCharacters(in: .whitespaces).isEmpty, cancelID: "db.newUser.cancel", action: create) {
            Form {
                TextField(L("common.user"), text: $name).accessibilityIdentifier("db.newUser.name").formField(L("common.user"))
                if connection.kind != "postgres" {
                    TextField(L("db.userHost"), text: $host).accessibilityIdentifier("db.newUser.host").formField(L("db.userHost"))
                }
                Picker(L("db.database"), selection: $database) {
                    Text(L("db.noAccess")).tag("")
                    ForEach((client.databases[connection.id] ?? []).filter { !$0.system }) { Text($0.name).tag($0.name) }
                }
                .accessibilityIdentifier("db.newUser.database")
                Picker(L("db.access"), selection: $access) {
                    Text(L("db.access.all")).tag("all")
                    Text(L("db.access.read")).tag("read")
                }
                .pickerStyle(.segmented).disabled(database.isEmpty)
                .accessibilityIdentifier("db.newUser.access")
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .frame(minHeight: 190)
        }
    }
    func create() async -> Bool {
        let password = DatabaseVault.generate()
        let request: [String: Any] = ["name": name, "host": host, "newPassword": password, "database": database, "access": access]
        guard let _: Bool = await client.change("dbCreateUser", connection, request, title: String(format: L("db.confirm.user"), name, connection.title)) else { return false }
        DatabaseVault.set(password, for: "user:\(connection.id)/\(name)", label: "\(connection.title) · \(name)")
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(password, forType: .string)
        client.store.notify(String(format: L("db.userCreated"), name))
        await done()
        return true
    }
}

// MARK: - Sessions (processes, Redis clients)

extension DBProcess {
    var sortID: Int { Int(pid ?? "") ?? 0 }
    var sortUser: String { user ?? "" }
    var sortDatabase: String { database ?? "" }
    var sortState: String { state ?? "" }
    var sortSeconds: Int { seconds ?? -1 }
    var sortQuery: String { query ?? "" }
}

struct ProcessesPanel: View {
    @Bindable var client: DatabaseClient
    let connection: DBConnection
    @State private var list: [DBProcess] = []
    @State private var error: DBProblem?
    @State private var picked: DBProcess.ID?
    @State private var order = [KeyPathComparator(\DBProcess.sortID)]
    var body: some View {
        let rows = list.sorted(using: order)
        VStack(spacing: 0) {
            if let error { DBProblemCard(problem: error).padding(14) }
            Table(rows, selection: $picked, sortOrder: $order) {
                TableColumn(L("db.col.id"), value: \.sortID) { p in Text(p.pid ?? "").monospacedDigit() }
                    .width(min: 40, ideal: 60)
                TableColumn(L("common.user"), value: \.sortUser) { p in Text(p.user ?? "").lineLimit(1).help(p.host ?? "") }
                    .width(min: 60, ideal: 90)
                TableColumn(L("db.database"), value: \.sortDatabase) { p in Text(p.database ?? "—").lineLimit(1) }
                    .width(min: 60, ideal: 90)
                TableColumn(L("db.col.state"), value: \.sortState) { p in Text(p.state ?? "").foregroundStyle(.secondary).lineLimit(1) }
                    .width(min: 60, ideal: 90)
                TableColumn(L("db.col.seconds"), value: \.sortSeconds) { p in Text(p.seconds.map(String.init) ?? "").monospacedDigit() }
                    .width(min: 40, ideal: 60).alignment(.trailing)
                TableColumn(L("db.col.query"), value: \.sortQuery) { p in
                    Text(p.query ?? "").font(.uiSubheadline.monospaced()).lineLimit(1).help(p.query ?? "")
                }
                .width(min: 120, ideal: 260)
                TableColumn("") { p in
                    if connection.allowsWrites {
                        Button { Task { await kill(p) } } label: { Label(L("db.kill"), systemImage: Symbols.kill).labelStyle(.iconOnly) }
                            .buttonStyle(.borderless).help(L("db.kill"))
                            .accessibilityIdentifier("db.processes.kill.\(p.pid ?? "")")
                    }
                }
                .width(28)
            }
            .contextMenu(forSelectionType: DBProcess.ID.self) { ids in
                if connection.allowsWrites, let process = list.first(where: { ids.contains($0.id) }) {
                    Button(role: .destructive) { Task { await kill(process) } } label: { Label(L("db.kill"), systemImage: Symbols.kill) }
                        .accessibilityIdentifier("db.processes.menu.kill")
                }
            }
            .overlay {
                if list.isEmpty && error == nil {
                    ContentUnavailableView(L("db.noProcesses"), systemImage: Symbols.processes).accessibilityIdentifier("db.processes.empty")
                }
            }
            .accessibilityIdentifier("db.processes.table")
            Divider()
            HStack {
                Text(String(format: L("db.processCount"), list.count)).font(.uiCaption).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .task(id: client.reloads) {
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }
    func load() async {
        do { list = try await client.read("dbProcesses", connection); error = nil } catch { self.error = DBProblem.from(error) }
    }
    func kill(_ process: DBProcess) async {
        if connection.isRedis {
            guard await client.confirmSimple(String(format: L("db.confirm.kill"), process.pid ?? "")) else { return }
            let _: Bool? = try? await client.read("dbKill", connection, ["id": process.pid ?? "", "confirmed": true])
        } else {
            let _: DBRunOutput? = await client.change("dbKill", connection, ["id": process.pid ?? ""], title: String(format: L("db.confirm.kill"), process.pid ?? ""))
        }
        await load()
    }
}
