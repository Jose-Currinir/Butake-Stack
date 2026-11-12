import AppKit
import SwiftUI

extension EnvKind {
    @MainActor var color: Color {
        switch self {
        case .local: Brand.success
        case .development: Brand.accent
        case .testing: Brand.info
        case .staging: Brand.warning
        case .production: Brand.danger
        case .other: Brand.special
        }
    }
    var symbol: String {
        switch self {
        case .local: "laptopcomputer"
        case .development: "hammer"
        case .testing: "checkmark.diamond"
        case .staging: "shippingbox"
        case .production: "exclamationmark.shield.fill"
        case .other: "square.stack"
        }
    }
}

/// The active environment of a site, as a small colored chip.
struct EnvChip: View {
    let env: EnvEnvironment
    var body: some View {
        Chip(text: env.title, symbol: env.kind.symbol, tint: env.kind.color)
            .help(String(format: L("env.activeHelp"), env.title))
    }
}

/// Sections of a `.env`, by the usual prefixes, so long files read like settings.
enum EnvSection: String, CaseIterable, Identifiable {
    case app, database, cache, mail, storage, frontend, services, other
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .app: "app.badge"
        case .database: "cylinder.split.1x2"
        case .cache: "bolt.horizontal"
        case .mail: "envelope"
        case .storage: "externaldrive"
        case .frontend: "paintbrush"
        case .services: "puzzlepiece.extension"
        case .other: "ellipsis.curlybraces"
        }
    }
    static func of(_ key: String) -> EnvSection {
        let k = key.uppercased()
        func any(_ prefixes: [String]) -> Bool { prefixes.contains { k.hasPrefix($0) } }
        if any(["APP_", "LOG_", "BCRYPT_", "PHP_CLI", "DEBUGBAR_", "TELESCOPE_"]) { return .app }
        if any(["DB_", "DATABASE_", "MONGO", "SCOUT_", "MEILISEARCH_", "TYPESENSE_"]) { return .database }
        if any(["SESSION_", "CACHE_", "QUEUE_", "REDIS_", "MEMCACHED_", "BROADCAST_", "REVERB_", "PUSHER_", "HORIZON_", "OCTANE_"]) { return .cache }
        if any(["MAIL_", "RESEND_", "POSTMARK_", "SES_", "MAILGUN_", "SENDGRID_"]) { return .mail }
        if any(["FILESYSTEM_", "AWS_", "S3_", "R2_", "MINIO_", "RUSTFS_"]) { return .storage }
        if any(["VITE_", "MIX_", "NODE_", "NEXT_PUBLIC_"]) { return .frontend }
        if k.contains("_") { return .services }
        return .other
    }
}

/// Entornos: each site keeps several `.env` (local, development, testing, staging, production).
/// Keys and plain values are stored by Stack; secret values only in the Keychain. Activating one
/// writes the site's `.env`, clears Laravel's caches and restarts its processes. Production is
/// locked by default (see `.compliance/docs/21719-gestor-entornos-requisitos.md`).
struct EnvironmentsView: View {
    @Bindable var store: StackStore
    let project: Project
    @State private var selected: String?
    @State private var draft: [Row] = []
    @State private var dirty = false
    @State private var creating = false
    @State private var confirmProduction = false
    @State private var confirmDelete = false
    @State private var showAudit = false
    @State private var revealed: [String: String] = [:]
    @State private var editingSecret: Row?
    /// Which secrets have a value in the Keychain, read once per load (not on every redraw: a long
    /// .env made every keystroke query the Keychain dozens of times).
    @State private var storedSecrets: Set<String> = []

    struct Row: Identifiable, Hashable {
        let id = UUID()
        var key: String
        var value: String
        var secret: Bool
        /// A new secret value typed by the user, written to the Keychain on save.
        var newSecret: String?
        var original: String?
    }

    var state: EnvState? { store.envs[project.id] }
    var environments: [EnvEnvironment] { state?.site.environments ?? [] }
    var current: EnvEnvironment? { environments.first { $0.id == selected } ?? environments.first }
    var missing: [String] {
        guard current != nil, let keys = state?.exampleKeys else { return [] }
        let have = Set(draft.map(\.key))
        return keys.filter { !have.contains($0) }
    }
    var sections: [(EnvSection, [Binding<Row>])] {
        EnvSection.allCases.compactMap { section in
            let rows = $draft.filter { EnvSection.of($0.wrappedValue.key) == section || ($0.wrappedValue.key.isEmpty && section == .other) }
            return rows.isEmpty ? nil : (section, rows)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let state, !state.gitGuard.ignored || state.gitGuard.tracked {
                banner(state.gitGuard.tracked ? L("env.guard.tracked") : L("env.guard.notIgnored"), tint: Brand.danger, symbol: "exclamationmark.octagon.fill")
            }
            if environments.isEmpty { emptyState } else { content }
        }
        .task(id: project.id) { await store.loadEnvs(project.id); load() }
        .onChange(of: selected) { _, _ in load() }
        .sheet(isPresented: $creating) {
            NewEnvironmentSheet(store: store, project: project, current: current) { id in selected = id; load() }.themedSheet()
        }
        .sheet(item: $editingSecret) { row in SecretEditor(key: row.key) { value in set(row.id) { $0.newSecret = value }; dirty = true }.themedSheet() }
        .sheet(isPresented: $confirmProduction) {
            if let current { ProductionConfirm(store: store, project: project, env: current).themedSheet() }
        }
        .sheet(isPresented: $showAudit) { EnvAuditSheet(store: store, project: project).themedSheet() }
        .confirmationDialog(String(format: L("env.deleteConfirm"), current?.title ?? ""), isPresented: $confirmDelete) {
            Button(L("site.delete"), role: .destructive) {
                if let current { Task { await store.deleteEnvironment(project, current.id); selected = nil; load() } }
            }
        } message: { Text(L("env.deleteDetail")) }
    }

    // MARK: Empty: import the current .env or start from .env.example
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                IconTile(symbol: "square.stack.3d.down.right", size: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text(L("env.title")).font(.ui(size: 17, weight: .semibold))
                    Text(L("env.emptyDetail")).font(.uiCallout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 10) {
                if state?.hasEnv == true {
                    Button { Task { await store.importCurrentEnv(project); selected = "local"; load() } } label: {
                        Label(L("env.import"), systemImage: "square.and.arrow.down")
                    }.buttonStyle(.borderedProminent).accessibilityIdentifier("env.import")
                }
                Button { creating = true } label: { Label(L("env.new"), systemImage: "plus") }.accessibilityIdentifier("env.newEmpty")
            }
            Label(L("env.securityNote"), systemImage: "lock.shield").font(.uiCaption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .glassCard(radius: 18)
    }

    // MARK: Environments bar, status and sections
    private var content: some View {
        VStack(alignment: .leading, spacing: 18) {
            environmentsBar
            statusBar
            if let current, current.kind == .production, state?.site.active == current.id {
                banner(L("env.productionActive"), tint: Brand.danger, symbol: "exclamationmark.shield.fill")
            }
            if !missing.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Brand.warning)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(format: L("env.missing"), missing.count)).font(.uiCallout.weight(.medium))
                        Text(missing.joined(separator: ", ")).font(.uiCaption.monospaced()).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer()
                    Button(L("env.addMissing")) { Task { await addMissing() } }.controlSize(.small)
                }
                .padding(12)
                .background(Brand.warning.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            LazyVGrid(columns: pageColumns, alignment: .leading, spacing: 18) {
                ForEach(sections, id: \.0) { section, rows in
                    CardBlock(title: L("env.section.\(section.rawValue)"), symbol: section.symbol) {
                        ForEach(Array(rows.enumerated()), id: \.element.wrappedValue.id) { index, row in
                            if index > 0 { Divider() }
                            EnvRowView(row: row, revealed: revealed[row.wrappedValue.key], hasSecret: hasSecret(row.wrappedValue),
                                       changed: { if !dirty { dirty = true } },
                                       reveal: { Task { await reveal(row.wrappedValue) } },
                                       copy: { Task { await copy(row.wrappedValue) } },
                                       edit: { editingSecret = row.wrappedValue },
                                       toggleSecret: { set(row.wrappedValue.id) { $0.secret.toggle() }; dirty = true },
                                       remove: { draft.removeAll { $0.id == row.wrappedValue.id }; dirty = true })
                        }
                    }
                }
            }
            Button { draft.append(Row(key: "", value: "", secret: false)); dirty = true } label: { Label(L("env.addKey"), systemImage: "plus.circle") }
                .buttonStyle(.borderless).accessibilityIdentifier("env.addKey")
        }
    }

    private var environmentsBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(environments) { env in
                    let isSelected = env.id == current?.id
                    Button { if !dirty || confirmDiscard() { selected = env.id } } label: {
                        HStack(spacing: 9) {
                            Image(systemName: env.kind.symbol).font(.system(size: 14, weight: .semibold)).foregroundStyle(env.kind.color)
                            Text(env.title).font(.ui(size: 13, weight: .semibold))
                            if state?.site.active == env.id {
                                Circle().fill(Brand.success).frame(width: 7, height: 7).help(L("env.isActive"))
                            }
                        }
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(isSelected ? env.kind.color.opacity(0.16) : Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(isSelected ? env.kind.color.opacity(0.6) : Color.primary.opacity(0.08), lineWidth: isSelected ? 1.5 : 1))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("env.select.\(env.id)")
                }
                Button { creating = true } label: {
                    Label(L("env.new"), systemImage: "plus").font(.ui(size: 12.5, weight: .medium))
                        .padding(.horizontal, 12).padding(.vertical, 12)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Brand.accent.opacity(0.5), style: StrokeStyle(lineWidth: 1.2, dash: [5, 4])))
                }
                .buttonStyle(.plain).foregroundStyle(Brand.accent).accessibilityIdentifier("env.new")
            }
            .padding(1)
        }
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            Text(L("env.activeLabel")).foregroundStyle(.secondary)
            if let active = state?.site.activeEnvironment { EnvChip(env: active) } else { Text(L("env.none")).foregroundStyle(.secondary) }
            Spacer()
            if dirty { Text(L("env.unsaved")).font(.uiCaption).foregroundStyle(Brand.warning) }
            Button(L("env.save")) { Task { await save() } }.disabled(!dirty || store.busy != nil).accessibilityIdentifier("env.save")
            if let current {
                Button { Task { await store.downloadEnv(project, current) } } label: { Label(".env.\(current.id)", systemImage: "arrow.down.doc") }
                    .help(String(format: L("env.downloadHelp"), current.title)).disabled(store.busy != nil || dirty)
                    .accessibilityIdentifier("env.download")
            }
            Menu {
                Button { Task { await createDatabase() } } label: { Label(L("env.createDatabase"), systemImage: "cylinder.split.1x2") }
                    .disabled(store.engineVersion("postgres") == nil)
                Button { showAudit = true } label: { Label(L("env.audit"), systemImage: "clock.arrow.circlepath") }
                if let current {
                    Button { Task { await store.downloadEnv(project, current) } } label: { Label(String(format: L("env.downloadMenu"), current.id), systemImage: "arrow.down.doc") }
                    Button { Task { await store.exportTemplate(project, current) } } label: { Label(L("env.export"), systemImage: "square.and.arrow.up") }
                    Divider()
                    Button(role: .destructive) { confirmDelete = true } label: { Label(L("env.delete"), systemImage: "trash") }
                        .disabled(state?.site.active == current.id)
                }
            } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityIdentifier("env.more")
            if let current {
                Button {
                    if current.kind == .production { confirmProduction = true } else { Task { await save(); await store.activateEnvironment(project, current); load() } }
                } label: {
                    Label(String(format: L("env.activate"), current.title), systemImage: current.kind == .production ? "lock.fill" : "bolt.fill")
                }
                .buttonStyle(.borderedProminent).tint(current.kind == .production ? Brand.danger : Brand.accent)
                .disabled(store.busy != nil || state?.site.active == current.id && !dirty)
                .accessibilityIdentifier("env.activate").help(L("env.activateHelp"))
            }
        }
        .padding(12)
        .glassCard(radius: 14)
    }

    // MARK: Actions
    private func load() {
        if selected == nil || !environments.contains(where: { $0.id == selected }) { selected = state?.site.active ?? environments.first?.id }
        draft = (current?.entries ?? []).map { Row(key: $0.key, value: $0.value, secret: $0.secret, original: $0.key) }
        revealed = [:]
        dirty = false
        Task { await loadStoredSecrets() }
    }
    private func set(_ id: UUID, _ change: (inout Row) -> Void) {
        guard let index = draft.firstIndex(where: { $0.id == id }) else { return }
        change(&draft[index])
    }
    private func hasSecret(_ row: Row) -> Bool {
        row.secret && row.original != nil && storedSecrets.contains(row.key)
    }
    /// Keychain lookups off the main thread, once.
    private func loadStoredSecrets() async {
        guard let current else { storedSecrets = []; return }
        let keys = current.entries.filter(\.secret).map(\.key)
        let site = project.id, env = current.id
        storedSecrets = await Task.detached { Set(keys.filter { EnvVault.has(site: site, env: env, key: $0) }) }.value
    }
    private func confirmDiscard() -> Bool {
        let alert = NSAlert()
        alert.messageText = L("env.discardTitle"); alert.informativeText = L("env.discardDetail")
        alert.addButton(withTitle: L("env.discard")); alert.addButton(withTitle: L("action.cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }
    private func reveal(_ row: Row) async {
        guard let current else { return }
        if revealed[row.key] != nil { revealed[row.key] = nil; return }
        guard await EnvVault.authenticate(String(format: L("env.authReveal"), row.key)) else { return }
        revealed[row.key] = EnvVault.get(site: project.id, env: current.id, key: row.key) ?? ""
        await store.envAudit(project.id, env: current.id, action: "revelar", key: row.key)
        let key = row.key
        Task { try? await Task.sleep(for: .seconds(30)); revealed[key] = nil }
    }
    private func copy(_ row: Row) async {
        guard let current, await EnvVault.authenticate(String(format: L("env.authCopyKey"), row.key)),
              let value = EnvVault.get(site: project.id, env: current.id, key: row.key) else { return }
        EnvVault.copy(value)
        await store.envAudit(project.id, env: current.id, action: "copiar", key: row.key)
        store.notify(L("env.copied"))
    }
    /// A database in the stack's PostgreSQL with two roles (migrations and app); the connection goes
    /// into this environment, passwords as secrets that land in the Keychain on save.
    private func createDatabase() async {
        struct Created: Decodable {
            let jdbc: String; let host: String; let port: Int; let database: String
            let user: String; let password: String; let migrationUser: String; let migrationPassword: String
        }
        let name = project.id.replacingOccurrences(of: "-", with: "_")
        guard let created: Created = try? await store.call(["method": "createDatabase", "engine": "postgres", "name": name]) else {
            store.errorMessage = L("env.createDatabaseFailed"); return
        }
        func upsert(_ key: String, _ value: String, secret: Bool = false) {
            if let i = draft.firstIndex(where: { $0.key == key }) {
                if secret { draft[i].secret = true; draft[i].newSecret = value } else { draft[i].value = value }
            } else {
                draft.append(Row(key: key, value: secret ? "" : value, secret: secret, newSecret: secret ? value : nil))
            }
        }
        if draft.contains(where: { $0.key == "DB_CONNECTION" || $0.key == "DB_DATABASE" }) {
            // Laravel-style: one connection that also runs the migrations, so it gets the owner role.
            upsert("DB_CONNECTION", "pgsql")
            upsert("DB_HOST", created.host)
            upsert("DB_PORT", String(created.port))
            upsert("DB_DATABASE", created.database)
            upsert("DB_USERNAME", created.migrationUser)
            upsert("DB_PASSWORD", created.migrationPassword, secret: true)
        } else {
            // JDBC style (KMP backends): the app role for runtime, the owner role for Flyway.
            upsert("DATABASE_URL", created.jdbc)
            upsert("DATABASE_USER", created.user)
            upsert("DATABASE_PASSWORD", created.password, secret: true)
            upsert("DATABASE_MIGRATION_URL", created.jdbc)
            upsert("DATABASE_MIGRATION_USER", created.migrationUser)
            upsert("DATABASE_MIGRATION_PASSWORD", created.migrationPassword, secret: true)
        }
        dirty = true
        store.notify(String(format: L("env.databaseCreated"), created.database))
    }
    private func addMissing() async {
        let keys = missing
        let secret = await store.classify(keys)
        for (index, key) in keys.enumerated() { draft.append(Row(key: key, value: "", secret: secret[index])) }
        dirty = true
    }
    /// Secrets to the Keychain first, then keys and plain values to the store.
    private func save() async {
        guard dirty, let current, var site = state?.site, let index = site.environments.firstIndex(where: { $0.id == current.id }) else { return }
        let keys = draft.map { $0.key.trimmingCharacters(in: .whitespaces) }
        guard !keys.contains(where: \.isEmpty), Set(keys).count == keys.count else { store.errorMessage = L("env.invalidKeys"); return }
        for row in draft where row.secret {
            // A typed secret, or a plain value just marked secret, goes to the Keychain.
            if let value = row.newSecret { EnvVault.set(value, site: project.id, env: current.id, key: row.key) }
            else if !row.value.isEmpty { EnvVault.set(row.value, site: project.id, env: current.id, key: row.key) }
        }
        let kept = Set(draft.filter(\.secret).map(\.key))
        for entry in current.entries where entry.secret && !kept.contains(entry.key) {
            EnvVault.delete(site: project.id, env: current.id, key: entry.key)
        }
        site.environments[index].entries = draft.map { EnvEntry(key: $0.key.trimmingCharacters(in: .whitespaces), value: $0.secret ? "" : $0.value, secret: $0.secret) }
        if await store.saveEnvs(project.id, site) { load() }
    }
    private func banner(_ text: String, tint: Color, symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.uiCallout.weight(.medium)).foregroundStyle(tint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(tint.opacity(0.3)))
    }
}

/// One variable: its name, its value (masked when secret) and, on hover, its actions.
private struct EnvRowView: View {
    @Binding var row: EnvironmentsView.Row
    let revealed: String?
    let hasSecret: Bool
    let changed: () -> Void
    let reveal: () -> Void
    let copy: () -> Void
    let edit: () -> Void
    let toggleSecret: () -> Void
    let remove: () -> Void
    @State private var hovering = false
    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                if row.original == nil {
                    TextField("NOMBRE", text: $row.key).textFieldStyle(.plain).font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                        .onChange(of: row.key) { _, _ in changed() }
                } else {
                    Text(row.key).font(.system(size: 11.5, weight: .semibold, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if row.secret {
                    HStack(spacing: 6) {
                        Image(systemName: "lock.fill").font(.system(size: 10)).foregroundStyle(Brand.accent)
                        Text(revealed ?? (row.newSecret != nil ? L("env.secretChanged") : (hasSecret ? "••••••••••••" : L("env.secretEmpty"))))
                            .font(.system(size: 12.5, design: .monospaced)).foregroundStyle(revealed == nil ? .secondary : .primary)
                            .textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                    }
                } else {
                    TextField(L("env.valuePlaceholder"), text: $row.value).textFieldStyle(.plain).font(.system(size: 12.5, design: .monospaced))
                        .onChange(of: row.value) { _, _ in changed() }
                }
            }
            Spacer(minLength: 6)
            HStack(spacing: 8) {
                if row.secret {
                    Button(action: reveal) { Image(systemName: revealed == nil ? "eye" : "eye.slash") }.help(L("env.reveal")).disabled(!hasSecret)
                    Button(action: copy) { Image(systemName: "doc.on.doc") }.help(L("env.copy")).disabled(!hasSecret)
                    Button(action: edit) { Image(systemName: "pencil") }.help(L("env.setSecret"))
                } else {
                    Button(action: toggleSecret) { Image(systemName: "lock.open") }.help(L("env.makeSecret"))
                }
                Button(role: .destructive, action: remove) { Image(systemName: "minus.circle") }.help(L("env.removeKey"))
            }
            .buttonStyle(.borderless)
            .opacity(hovering || row.original == nil ? 1 : 0.35)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

/// New environment: a standard kind (its name is the standard APP_ENV value), or a custom one, and
/// where its variables start from.
private struct NewEnvironmentSheet: View {
    let store: StackStore
    let project: Project
    let current: EnvEnvironment?
    let created: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var kind: EnvKind = .development
    @State private var customName = ""
    @State private var base = "__example__"
    var taken: Set<String> { Set(store.envs[project.id]?.site.environments.map(\.id) ?? []) }
    var hasExample: Bool { store.envs[project.id]?.exampleKeys.isEmpty == false }
    var name: String { kind == .other ? customName : L("env.kind.\(kind.rawValue)") }
    var identifier: String { kind.standard ?? StackStore.slug(customName) }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                IconTile(symbol: "square.stack.3d.down.right", size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("env.new")).font(.ui(size: 17, weight: .semibold))
                    Text(L("env.newDetail")).font(.uiCaption).foregroundStyle(.secondary)
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                ForEach(EnvKind.allCases, id: \.self) { item in
                    let used = item.standard.map { taken.contains($0) } ?? false
                    Button { kind = item } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Image(systemName: item.symbol).foregroundStyle(item.color)
                                Spacer()
                                if used { Text(L("env.exists")).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary) }
                            }
                            Text(L("env.kind.\(item.rawValue)")).font(.ui(size: 13, weight: .semibold))
                            Text(item.standard.map { "APP_ENV=\($0)" } ?? L("env.customId")).font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                            Text(L("env.kindDetail.\(item.rawValue)")).font(.uiCaption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(10).frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
                        .background(kind == item ? item.color.opacity(0.14) : Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(kind == item ? item.color : .clear, lineWidth: 1.5))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).disabled(used).opacity(used ? 0.45 : 1)
                    .accessibilityIdentifier("env.kind.\(item.rawValue)")
                }
            }
            if kind == .other {
                TextField(L("env.name"), text: $customName).textFieldStyle(.roundedBorder).accessibilityIdentifier("env.name")
            }
            Picker(L("env.startFrom"), selection: $base) {
                if hasExample { Text(".env.example").tag("__example__") }
                if let current { Text(String(format: L("env.base.copy"), current.title)).tag(current.id) }
                Text(L("env.base.empty")).tag("")
            }
            .pickerStyle(.segmented)
            Label(String(format: L("env.appEnvNote"), identifier.isEmpty ? "…" : identifier), systemImage: "info.circle").font(.uiCaption).foregroundStyle(.secondary)
            if kind == .production {
                Label(L("env.productionNote"), systemImage: "exclamationmark.shield.fill").font(.uiCaption).foregroundStyle(Brand.danger).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button(L("action.cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L("env.create")) {
                    Task {
                        if let id = await store.createEnvironment(project, name: name, kind: kind, from: base.isEmpty ? nil : base) { created(id); dismiss() }
                    }
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                .disabled(identifier.isEmpty || taken.contains(identifier)).accessibilityIdentifier("env.create")
            }
        }
        .padding(22).frame(width: 560)
        .onAppear {
            kind = EnvKind.allCases.first { $0.standard.map { !taken.contains($0) } ?? true } ?? .other
            if !hasExample { base = current?.id ?? "" }
        }
    }
}

/// A new value for a secret, typed and never shown.
private struct SecretEditor: View {
    let key: String
    let save: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var value = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(format: L("env.secretTitle"), key)).font(.ui(size: 15, weight: .semibold))
            SecureField(L("env.secretValue"), text: $value).textFieldStyle(.roundedBorder).accessibilityIdentifier("env.secretValue")
            Label(L("env.secretNote"), systemImage: "lock.shield").font(.uiCaption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(L("action.cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L("env.save")) { save(value); dismiss() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 420)
    }
}

/// Production: type the site's name, then Touch ID or the Mac's password (R4).
struct ProductionConfirm: View {
    let store: StackStore
    let project: Project
    let env: EnvEnvironment
    @Environment(\.dismiss) private var dismiss
    @State private var typed = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(String(format: L("env.productionTitle"), project.title), systemImage: "exclamationmark.shield.fill")
                .font(.ui(size: 16, weight: .semibold)).foregroundStyle(Brand.danger)
            Text(L("env.productionDetail")).font(.uiCallout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField(project.title, text: $typed).textFieldStyle(.roundedBorder).accessibilityIdentifier("env.productionName")
            HStack {
                Spacer()
                Button(L("action.cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L("env.productionActivate")) {
                    Task { dismiss(); await store.activateEnvironment(project, env, confirmedProduction: true) }
                }
                .buttonStyle(.borderedProminent).tint(Brand.danger)
                .disabled(typed != project.title).accessibilityIdentifier("env.productionConfirm")
            }
        }
        .padding(22).frame(width: 460)
    }
}

/// Who did what with this site's environments; never values (R7).
private struct EnvAuditSheet: View {
    let store: StackStore
    let project: Project
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [EnvAuditEntry] = []
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label(L("env.audit"), systemImage: "clock.arrow.circlepath").font(.ui(size: 15, weight: .semibold))
                Spacer()
                Button(L("action.close")) { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(16)
            Divider()
            List(entries, id: \.self) { entry in
                HStack {
                    Text(Date(timeIntervalSince1970: TimeInterval(entry.ts)).formatted(date: .abbreviated, time: .shortened)).monospacedDigit().foregroundStyle(.secondary)
                    Text(L("env.action.\(entry.action)")).fontWeight(.medium)
                    Text([entry.env, entry.key].filter { !$0.isEmpty }.joined(separator: " · ")).font(.system(size: 12, design: .monospaced))
                    Spacer()
                    Text(entry.user).foregroundStyle(.secondary)
                }
            }
            .themedScroll()
            HStack {
                Text(L("env.auditNote")).font(.uiCaption).foregroundStyle(.secondary)
                Spacer()
                // R11: what to do if the Mac is lost or a secret leaks.
                Link(L("env.incident"), destination: URL(string: "https://github.com/Jose-Currinir/Butake-Stack/blob/main/.compliance/docs/21719-gestor-entornos-incidentes.md")!)
                    .font(.uiCaption.weight(.medium))
            }
            .padding(12)
        }
        .frame(width: 620, height: 440)
        .task { entries = (try? await store.call(["method": "envAuditLog", "id": project.id])) ?? [] }
    }
}
