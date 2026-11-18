import SwiftUI

/// What `createDatabase` returns. A password is nil when that account already existed: it keeps
/// the password it had, which Stack never rotates on its own.
struct CreatedDatabase: Decodable {
    let engine: String
    let host: String
    let port: Int
    let database: String
    let jdbc: String?
    let user: String
    let password: String?
    let migrationUser: String?
    let migrationPassword: String?
}

/// The engines of Stack a project's database can live in.
enum DatabaseEngine: String, CaseIterable, Identifiable {
    case postgres, mysql
    var id: String { rawValue }
    var title: String { L("db.new.engine.\(rawValue)") }
}

/// «Crear base…» of Entornos: the database, in which engine, and with which account(s). One user
/// (named freely, owner of the database) or the two roles of migrations and the app (PostgreSQL).
struct NewDatabaseSheet: View {
    let store: StackStore
    let suggested: String
    let created: (CreatedDatabase) -> Void
    @State private var engine: DatabaseEngine = .postgres
    @State private var name = ""
    @State private var split = false
    @State private var user = ""
    @State private var extensions: Set<String> = []

    private var engines: [DatabaseEngine] { DatabaseEngine.allCases.filter { store.engineVersion($0.rawValue) != nil } }
    private static func valid(_ text: String) -> Bool {
        guard let first = text.unicodeScalars.first, !CharacterSet.decimalDigits.contains(first), text.count <= 40 else { return false }
        return text.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_").contains($0) }
    }
    private var account: String { user.isEmpty ? name : user }
    private var canCreate: Bool {
        Self.valid(name) && (split && engine == .postgres || Self.valid(account) && !["postgres", "root"].contains(account))
    }

    var body: some View {
        SheetFrame(title: L("db.new.title"), symbol: Symbols.database, detail: L("db.new.detail"), width: 520,
                   actionTitle: L("common.create"), actionSymbol: Symbols.add, actionID: "db.new.create", canAct: canCreate,
                   cancelID: "db.new.cancel") {
            await create()
        } content: {
            Form {
                Section {
                    Picker(L("db.new.engine"), selection: $engine) {
                        ForEach(engines) { Text($0.title).tag($0) }
                    }
                    .accessibilityIdentifier("db.new.engine")
                    TextField(L("db.new.name"), text: $name, prompt: Text(verbatim: suggested))
                        .accessibilityIdentifier("db.new.name")
                } footer: {
                    Text(L("db.new.nameHelp")).font(.uiCaption).foregroundStyle(.secondary)
                }
                Section {
                    if engine == .postgres {
                        Picker(L("db.new.mode"), selection: $split) {
                            Text(L("db.new.mode.single")).tag(false)
                            Text(L("db.new.mode.split")).tag(true)
                        }
                        .pickerStyle(.radioGroup).accessibilityIdentifier("db.new.mode")
                    }
                    if !split || engine == .mysql {
                        TextField(L("db.new.user"), text: $user, prompt: Text(verbatim: name.isEmpty ? suggested : name))
                            .accessibilityIdentifier("db.new.user")
                    }
                } header: {
                    Text(L("db.new.accounts"))
                } footer: {
                    Text(split && engine == .postgres ? String(format: L("db.new.splitHelp"), name, name) : L("db.new.singleHelp"))
                        .font(.uiCaption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                }
                if engine == .postgres { ExtensionPickerSection(store: store, selected: $extensions, scope: "db.new.extension") }
            }
            .formStyle(.grouped).themedScroll()
        }
        .onAppear {
            name = suggested
            engine = engines.first ?? .postgres
        }
    }

    private func create() async -> Bool {
        var request: [String: Any] = ["method": "createDatabase", "engine": engine.rawValue, "name": name,
                                      "mode": split && engine == .postgres ? "split" : "single", "user": account]
        if engine == .mysql, let root = DatabaseVault.get(DatabaseVault.mysqlRoot) { request["mysqlPassword"] = root }
        do {
            let result: CreatedDatabase = try await store.call(request)
            created(result)
            // The database and its account exist already: an extension that fails is said apart.
            if engine == .postgres && !extensions.isEmpty {
                do { try await store.activateExtensions(extensions.sorted(), in: result.database) } catch { store.report(error) }
            }
            return true
        } catch let failure as EngineFailure {
            store.errorMessage = failure.errorDescription ?? L("env.createDatabaseFailed")
        } catch {
            store.errorMessage = L("env.createDatabaseFailed")
        }
        return false
    }
}

/// «Cambiar contraseña…» of a database account named in this environment: says which projects use
/// it, asks, and only then gives it a new password, which goes into this environment.
struct DatabasePasswordSheet: View {
    struct Account: Hashable { let user: String; let passwordKey: String }
    struct UsedBy: Decodable, Hashable { let id: String; let name: String; let environments: [String] }
    let store: StackStore
    let accounts: [Account]
    let changed: (Account, String) -> Void
    @State private var selected: Account?
    @State private var engine: DatabaseEngine = .postgres
    @State private var usedBy: [UsedBy] = []
    @State private var confirming = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SheetFrame(title: L("db.password.title"), symbol: Symbols.key, detail: L("db.password.detail"), width: 520,
                   actionTitle: L("db.password.change"), actionSymbol: Symbols.key, actionID: "db.password.change",
                   canAct: selected != nil, cancelID: "db.password.cancel") {
            confirming = true
            return false
        } content: {
            Form {
                Section {
                    Picker(L("db.new.engine"), selection: $engine) {
                        ForEach(DatabaseEngine.allCases.filter { store.engineVersion($0.rawValue) != nil }) { Text($0.title).tag($0) }
                    }
                    .accessibilityIdentifier("db.password.engine")
                    Picker(L("db.password.account"), selection: $selected) {
                        ForEach(accounts, id: \.self) { Text(verbatim: $0.user).tag(Optional($0)) }
                    }
                    .accessibilityIdentifier("db.password.account")
                }
                Section(L("db.password.usedBy")) {
                    if usedBy.isEmpty {
                        Text(L("db.password.usedByNone")).foregroundStyle(.secondary)
                    }
                    ForEach(usedBy, id: \.self) { item in
                        LabeledContent(item.name) { Text(item.environments.joined(separator: ", ")).foregroundStyle(.secondary) }
                    }
                }
            }
            .formStyle(.grouped).themedScroll()
        }
        .task(id: selected) { await loadUsers() }
        .onAppear { if selected == nil { selected = accounts.first } }
        .confirmationDialog(String(format: L("db.password.confirm"), selected?.user ?? ""), isPresented: $confirming) {
            Button(L("db.password.change"), role: .destructive) { Task { if await rotate() { dismiss() } } }
                .accessibilityIdentifier("db.password.confirm")
            Button(L("common.cancel"), role: .cancel) {}
        } message: {
            Text(usedBy.count > 1 ? String(format: L("db.password.confirmOthers"), usedBy.map(\.name).joined(separator: ", ")) : L("db.password.confirmDetail"))
        }
    }

    private func loadUsers() async {
        guard let selected else { usedBy = []; return }
        usedBy = (try? await store.call(["method": "databaseAccountUsers", "user": selected.user])) ?? []
    }

    private func rotate() async -> Bool {
        struct Rotated: Decodable { let password: String }
        guard let selected else { return false }
        var request: [String: Any] = ["method": "rotateDatabasePassword", "engine": engine.rawValue, "user": selected.user, "confirmed": true]
        if engine == .mysql, let root = DatabaseVault.get(DatabaseVault.mysqlRoot) { request["mysqlPassword"] = root }
        do {
            let rotated: Rotated = try await store.call(request)
            changed(selected, rotated.password)
            return true
        } catch let failure as EngineFailure {
            store.errorMessage = failure.errorDescription ?? L("engine.requestFailed")
        } catch {
            store.errorMessage = L("engine.requestFailed")
        }
        return false
    }
}

extension EnvironmentsView {
    /// The new database's connection goes into this environment; passwords as secrets that land in
    /// the Keychain on save. An account that already existed keeps its password: its key is left
    /// as it is, and the notice says how to change it.
    func fill(_ created: CreatedDatabase) {
        func upsert(_ key: String, _ value: String?, secret: Bool = false) {
            guard let value else { return }
            if let i = draft.firstIndex(where: { $0.key == key }) {
                if secret { draft[i].secret = true; draft[i].newSecret = value } else { draft[i].value = value }
            } else {
                draft.append(Row(key: key, value: secret ? "" : value, secret: secret, newSecret: secret ? value : nil))
            }
        }
        let owner = created.migrationUser ?? created.user
        let ownerPassword = created.migrationUser == nil ? created.password : created.migrationPassword
        if created.engine == "mysql" || draft.contains(where: { $0.key == "DB_CONNECTION" || $0.key == "DB_DATABASE" }) {
            // Laravel-style: one connection that also runs the migrations, so it gets the owner.
            upsert("DB_CONNECTION", created.engine == "mysql" ? "mysql" : "pgsql")
            upsert("DB_HOST", created.host)
            upsert("DB_PORT", String(created.port))
            upsert("DB_DATABASE", created.database)
            upsert("DB_USERNAME", owner)
            upsert("DB_PASSWORD", ownerPassword, secret: true)
        } else {
            // JDBC style (KMP backends): the app's login for runtime, the owner for migrations.
            upsert("DATABASE_URL", created.jdbc)
            upsert("DATABASE_USER", created.user)
            upsert("DATABASE_PASSWORD", created.password, secret: true)
            if created.migrationUser != nil || draft.contains(where: { $0.key == "DATABASE_MIGRATION_USER" }) {
                upsert("DATABASE_MIGRATION_URL", created.jdbc)
                upsert("DATABASE_MIGRATION_USER", owner)
                upsert("DATABASE_MIGRATION_PASSWORD", ownerPassword, secret: true)
            }
        }
        dirty = true
        var kept: [String] = []
        if created.password == nil { kept.append(created.user) }
        if let owner = created.migrationUser, created.migrationPassword == nil { kept.append(owner) }
        store.notify(kept.isEmpty ? String(format: L("env.databaseCreated"), created.database)
                                  : String(format: L("env.databaseKept"), created.database, kept.joined(separator: ", ")))
    }
}
