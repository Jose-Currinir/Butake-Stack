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


/// Sections of a `.env`, by the usual prefixes, so long files read like settings.
enum EnvSection: String, CaseIterable, Identifiable {
    case app, database, cache, mail, storage, frontend, services, other
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .app: "app.badge"
        case .database: Symbols.database
        case .cache: "bolt.horizontal"
        case .mail: "envelope"
        case .storage: "externaldrive"
        case .frontend: "paintbrush"
        case .services: "puzzlepiece.extension"
        case .other: "ellipsis.curlybraces"
        }
    }
    static func of(_ key: String) -> EnvSection {
        let k = key.dataCapitals
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
/// locked by default (privacy requirements R1 to R12).
struct EnvironmentsView: View {
    @Bindable var store: StackStore
    let project: Project
    @State var selected: String?
    @State var draft: [Row] = []
    @State var dirty = false
    /// Text mode (`EnvTextMode.swift`): the environment as one `.env` text, with ⌘F.
    @AppStorage("env.textMode") var textMode = false
    @State var text = ""
    @State var findRequests = 0
    @State var creating = false
    @State var confirmProduction = false
    @State var confirmDelete = false
    @State var renaming = false
    /// A `.env` dropped while environments exist: the preview that asks before creating a new one.
    @State var dropPreview: EnvDropPreview?
    @State private var showAudit = false
    @State private var revealed: [String: String] = [:]
    /// The 30 s timer of each revealed value; hiding it or leaving the page cancels it.
    @State private var hideTimers: [String: Task<Void, Never>] = [:]
    @State private var editingSecret: Row?
    /// Which secrets have a value in the Keychain, read once per load (not on every redraw: a long
    /// .env made every keystroke query the Keychain dozens of times).
    @State var storedSecrets: Set<String> = []
    /// The environment just applied while processes run: they take it only when restarted.
    @State private var offerRestart: EnvEnvironment?
    @State private var creatingDatabase = false
    @State private var changingPassword = false
    @State var dropTargeted = false

    struct Row: Identifiable, Hashable {
        let id = UUID()
        var key: String
        var value: String
        var secret: Bool
        /// A new secret value typed by the user, written to the Keychain on save.
        var newSecret: String?
        var original: String?
        /// Typed in text mode and not classified yet (see `classifyTyped`).
        var fromText = false
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
        Group {
            if environments.isEmpty { emptyState } else if textMode { textContent } else { content }
        }
        // A `.env` dropped here: «Local» when there are no environments (as «Importar»), else a new one.
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: Radius.card).strokeBorder(Brand.accent, lineWidth: 2).padding(8).allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            dropEnv(url)
            return true
        } isTargeted: { dropTargeted = $0 }
        .onChange(of: draft) { _, _ in followDraft() }
        .onChange(of: environments.map(\.id)) { _, _ in reconcileSelection() }
        .onChange(of: storedSecrets) { _, _ in if textMode, !dirty { renderText() } }
        .onChange(of: textMode) { _, _ in modeChanged() }
        .task(id: project.id) { await store.loadEnvs(project.id); load() }
        .onDisappear { hideTimers.values.forEach { $0.cancel() }; hideTimers = [:]; revealed = [:] }
        .onChange(of: selected) { _, _ in load() }
        .sheet(isPresented: $creating) {
            NewEnvironmentSheet(store: store, project: project, current: current) { id in selected = id; load() }.themedSheet()
        }
        .sheet(item: $editingSecret) { row in SecretEditor(key: row.key) { value in set(row.id) { $0.newSecret = value }; dirty = true }.themedSheet() }
        .sheet(isPresented: $renaming) {
            if let current { RenameEnvironmentSheet(store: store, project: project, env: current).themedSheet() }
        }
        .sheet(item: $dropPreview) { preview in
            EnvDropSheet(store: store, project: project, preview: preview) { id in adopt(id) }.themedSheet()
        }
        .sheet(isPresented: $confirmProduction) {
            if let current { ProductionConfirm(store: store, project: project, env: current).themedSheet() }
        }
        .sheet(isPresented: $showAudit) { EnvAuditSheet(store: store, project: project).themedSheet() }
        .sheet(isPresented: $creatingDatabase) {
            NewDatabaseSheet(store: store, suggested: project.id.replacingOccurrences(of: "-", with: "_")) { fill($0) }.themedSheet()
        }
        .sheet(isPresented: $changingPassword) {
            DatabasePasswordSheet(store: store, accounts: databaseAccounts) { account, password in
                set(draftID(account.passwordKey)) { $0.secret = true; $0.newSecret = password }
                dirty = true
                store.notify(String(format: L("db.password.changed"), account.user))
            }.themedSheet()
        }
        .confirmationDialog(String(format: L("env.deleteConfirm"), current?.title ?? ""), isPresented: $confirmDelete) {
            Button(L("env.delete"), role: .destructive) {
                if let current { Task { await store.deleteEnvironment(project, current.id); selected = nil; load() } }
            }
            Button(L("common.cancel"), role: .cancel) {}
        } message: { Text(L("env.deleteDetail")) }
        .confirmationDialog(String(format: L("env.restartConfirm"), project.title), isPresented: Binding(get: { offerRestart != nil }, set: { if !$0 { offerRestart = nil } }),
                            presenting: offerRestart) { _ in
            Button(L("env.restartProcesses")) { Task { await store.restartProcesses(project) } }
                .accessibilityIdentifier("env.restartProcesses")
            Button(L("common.cancel"), role: .cancel) {}
        } message: { env in Text(String(format: L("env.restartDetail"), env.title)) }
    }
    /// Projects named with `{port:<id>}` in this environment that no longer exist.
    private var missingPorts: [String] {
        let known = Set(store.projects.map(\.id))
        var out: [String] = []
        for row in draft {
            var rest = Substring(row.value)
            while let start = rest.range(of: "{port:"), let end = rest[start.upperBound...].firstIndex(of: "}") {
                let id = String(rest[start.upperBound..<end])
                if !known.contains(id), !out.contains(id) { out.append(id) }
                rest = rest[rest.index(after: end)...]
            }
        }
        return out
    }
    private func projectTitle(_ id: String) -> String { store.projects.first { $0.id == id }?.title ?? id }
    /// Projects whose port another value can name with `{port:<id>}`.
    private var ports: [Project] { store.projects.filter { $0.upstream != nil }.sorted { $0.title < $1.title } }

    /// The `.env` is not ignored or is tracked: secrets are not written until that is fixed.
    var guardProblem: String? {
        guard let guardState = state?.gitGuard, !guardState.ignored || guardState.tracked else { return nil }
        return guardState.tracked ? L("env.guard.tracked") : L("env.guard.notIgnored")
    }

    @ViewBuilder var guardNotice: some View {
        if let guardProblem { EnvGuardNotice(store: store, project: project, message: guardProblem, tracked: state?.gitGuard.tracked == true) }
    }

    // MARK: Empty: import the current .env or start from .env.example
    private var emptyState: some View {
        VStack(spacing: 0) {
            if guardProblem != nil { guardNotice.padding(.horizontal, 20).padding(.top, 14) }
            ContentUnavailableView {
                Label(L("env.title"), systemImage: Symbols.environments)
            } description: {
                Text(L("env.emptyDetail"))
            } actions: {
                HStack(spacing: 10) {
                    Button { creating = true } label: { Label(L("env.new"), systemImage: Symbols.add) }
                        .buttonStyle(.bordered).accessibilityIdentifier("env.newEmpty")
                    if state?.hasEnv == true {
                        Button { Task { await store.importCurrentEnv(project); selected = "local"; load() } } label: {
                            Label(L("env.import"), systemImage: Symbols.importing)
                        }.buttonStyle(.borderedProminent).accessibilityIdentifier("env.import")
                    }
                }
            }
            .frame(maxHeight: .infinity)
            .help(L("env.securityNote"))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// What is wrong with this environment, one notice each; both modes show them.
    @ViewBuilder var notices: some View {
        guardNotice
        if !missingPorts.isEmpty {
            Notice(.error, String(format: L("env.portMissing"), missingPorts.joined(separator: ", ")), detail: L("env.portMissingDetail"))
        }
        if let pending = state?.publicPending, !pending.isEmpty {
            Notice(.warning, String(format: L("env.publicPending"), pending.map(projectTitle).joined(separator: ", ")), detail: L("env.publicPendingDetail"))
        }
        if let active = state?.site.activeEnvironment, let outdated = state?.site.outdated, !outdated.isEmpty {
            Notice(.warning, String(format: L("env.portOutdated"), outdated.map(projectTitle).joined(separator: ", ")), detail: L("env.portOutdatedDetail")) {
                Button {
                    if active.kind == .production { selected = active.id; confirmProduction = true } else { Task { await activate(active) } }
                } label: { Label(L("env.reapply"), systemImage: Symbols.reload) }
                .buttonStyle(.bordered).disabled(store.busy != nil || missingPorts.contains { outdated.contains($0) })
                .accessibilityIdentifier("env.reapply")
            }
        }
    }
    @ViewBuilder var missingNotice: some View {
        if !missing.isEmpty {
            Notice(.warning, String(format: L("env.missing"), missing.count), detail: missing.joined(separator: ", ")) {
                Button { Task { await addMissing() } } label: { Label(L("env.addMissing"), systemImage: Symbols.add) }
                    .buttonStyle(.bordered).accessibilityIdentifier("env.addMissing")
            }
        }
    }
    var environmentPicker: some View {
        HStack(spacing: 6) {
            environmentSelector
            environmentMenu
        }
        .contextMenu { environmentActions }
    }
    private var environmentSelector: some View {
        Picker(L("env.editing"), selection: Binding(get: { current?.id }, set: { id in if !dirty || confirmDiscard() { selected = id } })) {
            ForEach(environments) { env in
                Label(env.title, systemImage: env.kind.symbol).tag(Optional(env.id))
            }
        }
        .help(L("env.securityNote"))
        .accessibilityIdentifier("env.select")
    }

    // MARK: The environment, its status and its variables by section
    private var content: some View {
        Form {
            ForEach(subviews: notices) { notice in Section { notice } }
            Section {
                environmentPicker
                modePicker(labeled: true)
                LabeledContent(L("env.activeLabel")) {
                    if let active = state?.site.activeEnvironment { Chip(env: active) } else { Text(L("env.none")) }
                }
                if !project.processes.isEmpty {
                    Toggle(L("env.passToProcesses"), isOn: Binding(get: { state?.site.passes ?? true },
                                                                   set: { on in Task { await store.setPassToProcesses(project, on) } }))
                        .help(L("env.passToProcessesHelp")).disabled(store.busy != nil)
                        .accessibilityIdentifier("env.passToProcesses")
                }
                if store.pluginEnabled("aws") { AWSProfilePicker(rows: $draft, production: current?.kind == .production) { dirty = true } }
                if let current, current.kind == .production, state?.site.active == current.id {
                    Notice(.error, L("env.productionActive"), symbol: EnvKind.production.symbol)
                }
                actions
            }
            if !missing.isEmpty { Section { missingNotice } }
            ForEach(sections, id: \.0) { section, rows in
                Section(L("env.section.\(section.rawValue)")) {
                    ForEach(rows, id: \.wrappedValue.id) { row in
                        EnvRowView(row: row, revealed: revealed[row.wrappedValue.key], hasSecret: hasSecret(row.wrappedValue),
                                   changed: { if !dirty { dirty = true } },
                                   reveal: { Task { await reveal(row.wrappedValue) } },
                                   copy: { Task { await copy(row.wrappedValue) } },
                                   edit: { editingSecret = row.wrappedValue },
                                   toggleSecret: { set(row.wrappedValue.id) { $0.secret.toggle() }; dirty = true },
                                   remove: { draft.removeAll { $0.id == row.wrappedValue.id }; dirty = true },
                                   ports: ports)
                    }
                }
            }
            Section {
                Button { draft.append(Row(key: "", value: "", secret: false)); dirty = true } label: { Label(L("env.addKey"), systemImage: Symbols.add) }
                    .buttonStyle(.bordered).accessibilityIdentifier("env.addKey")
            }
        }
        .formStyle(.grouped).themedScroll()
    }

    /// The environment's actions: more (new, database, history, download, export, delete), save and
    /// activate, the one prominent action of the tab.
    var actions: some View {
        HStack(spacing: 10) {
            Menu {
                Button { creating = true } label: { Label(L("env.new"), systemImage: Symbols.add) }.accessibilityIdentifier("env.new")
                Divider()
                Button { creatingDatabase = true } label: { Label(L("env.createDatabase"), systemImage: Symbols.database) }
                    .disabled(store.engineVersion("postgres") == nil && store.engineVersion("mysql") == nil)
                    .accessibilityIdentifier("env.createDatabase")
                Button { changingPassword = true } label: { Label(L("env.changeDatabasePassword"), systemImage: Symbols.key) }
                    .disabled(databaseAccounts.isEmpty).accessibilityIdentifier("env.changeDatabasePassword")
                Button { showAudit = true } label: { Label(L("env.audit"), systemImage: Symbols.history) }
                    .accessibilityIdentifier("env.audit")
                if let current {
                    Button { Task { await store.downloadEnv(project, current) } } label: { Label(String(format: L("env.downloadMenu"), current.id), systemImage: Symbols.dump) }
                        .help(String(format: L("env.downloadHelp"), current.title)).disabled(store.busy != nil || dirty)
                        .accessibilityIdentifier("env.download")
                    Button { Task { await store.exportTemplate(project, current) } } label: { Label(L("env.export"), systemImage: Symbols.share) }
                        .accessibilityIdentifier("env.exportTemplate")
                    Divider()
                    Button(role: .destructive) { confirmDelete = true } label: { Label(L("env.delete"), systemImage: Symbols.delete) }
                        .disabled(state?.site.active == current.id)
                }
            } label: {
                Label(L("env.more"), systemImage: Symbols.more)
            }
            .fixedSize().accessibilityIdentifier("env.more")
            Spacer()
            if dirty { Text(L("env.unsaved")).font(.uiCaption).foregroundStyle(Brand.warningText) }
            Button { Task { await save() } } label: { Label(L("common.save"), systemImage: Symbols.save) }
                .buttonStyle(.bordered).disabled(!dirty || store.busy != nil).accessibilityIdentifier("env.save")
            if let current {
                Button {
                    if current.kind == .production { confirmProduction = true } else { Task { await activate(current) } }
                } label: {
                    Label(String(format: L("env.activate"), current.title), systemImage: current.kind == .production ? Symbols.locked : Symbols.active)
                }
                .buttonStyle(.borderedProminent).tint(current.kind == .production ? Brand.danger : nil)
                .disabled(store.busy != nil || state?.site.active == current.id && !dirty)
                .accessibilityIdentifier("env.activate").help(L("env.activateHelp"))
            }
        }
    }

    // MARK: Actions
    /// Saves, applies and, when processes are running, asks before restarting them.
    func activate(_ env: EnvEnvironment) async {
        let previous = store.activeEnvironment(project.id)
        // A save that did not happen keeps what was typed: nothing is reloaded or applied over it.
        guard await save() else { return }
        await store.activateEnvironment(project, env, restart: false)
        load()
        if store.activeEnvironment(project.id)?.id == env.id { undoActivation(from: previous, to: env) }
        if store.activeEnvironment(project.id)?.id == env.id, !store.liveProcessIDs(project).isEmpty { offerRestart = env }
    }
    func load() {
        if selected == nil || !environments.contains(where: { $0.id == selected }) { selected = state?.site.active ?? environments.first?.id }
        draft = (current?.entries ?? []).map { Row(key: $0.key, value: $0.value, secret: $0.secret, original: $0.key) }
        hideTimers.values.forEach { $0.cancel() }; hideTimers = [:]
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
    /// Which secrets have a value, from the Keychain item's attributes only (no value is read, so
    /// opening the tab never asks for access), off the main thread, once.
    private func loadStoredSecrets() async {
        guard let current else { storedSecrets = []; return }
        let site = project.id, env = current.id
        storedSecrets = await Task.detached { EnvSecrets.keychain.storedKeys(site: site, env: env) }.value
    }
    func confirmDiscard() -> Bool {
        let alert = NSAlert()
        alert.messageText = L("env.discardTitle"); alert.informativeText = L("env.discardDetail")
        alert.addButton(withTitle: L("env.discard")); alert.addButton(withTitle: L("common.cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }
    private func reveal(_ row: Row) async {
        guard let current else { return }
        if revealed[row.key] != nil { hideTimers[row.key]?.cancel(); revealed[row.key] = nil; return }
        guard await EnvVault.authenticate(String(format: L("env.authReveal"), row.key)) else { return }
        guard let values = await store.secretValues(project.id, current.id) else { return }
        // The reveal is audited first: without the entry the value is not shown.
        guard await store.envAudit(project.id, env: current.id, action: "revelar", key: row.key) else { return }
        revealed[row.key] = values[row.key] ?? ""
        let key = row.key
        hideTimers[key]?.cancel()
        hideTimers[key] = Task {
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled else { return }
            revealed[key] = nil
        }
    }
    private func copy(_ row: Row) async {
        guard let current, await EnvVault.authenticate(String(format: L("env.authCopyKey"), row.key)),
              let value = await store.secretValues(project.id, current.id)?[row.key] else { return }
        guard await store.envAudit(project.id, env: current.id, action: "copiar", key: row.key) else { return }
        EnvVault.copy(value)
        store.notify(L("env.copied"))
    }
    /// Database logins this environment names (`DB_USERNAME`, `DATABASE_USER`…) that have a password
    /// key next to them: the accounts whose password can be changed from here.
    private var databaseAccounts: [DatabasePasswordSheet.Account] {
        draft.compactMap { row in
            guard !row.secret, !row.value.isEmpty, let suffix = ["USERNAME", "USER"].first(where: { row.key.hasSuffix($0) }) else { return nil }
            let key = String(row.key.dropLast(suffix.count)) + "PASSWORD"
            return draft.contains { $0.key == key } ? .init(user: row.value, passwordKey: key) : nil
        }
    }
    private func draftID(_ key: String) -> UUID {
        if let row = draft.first(where: { $0.key == key }) { return row.id }
        draft.append(Row(key: key, value: "", secret: true))
        return draft[draft.count - 1].id
    }
    private func addMissing() async {
        let keys = missing
        let secret = await store.classify(keys)
        for (index, key) in keys.enumerated() { draft.append(Row(key: key, value: "", secret: secret[index])) }
        dirty = true
    }
    /// The Keychain changes of a save: typed secrets, or values just marked secret, to write, and
    /// the stored ones no longer secret to delete. Keys are trimmed once, as the entries keep them.
    static func secretChanges(_ rows: [Row], current: [EnvEntry], stored: Set<String>) -> (set: [String: String], remove: Set<String>) {
        var set: [String: String] = [:]
        for row in rows where row.secret {
            let key = row.key.trimmingCharacters(in: .whitespaces)
            if let value = row.newSecret { set[key] = value } else if !row.value.isEmpty { set[key] = row.value }
        }
        let kept = Set(rows.filter(\.secret).map { $0.key.trimmingCharacters(in: .whitespaces) })
        let remove = Set(current.filter { $0.secret && !kept.contains($0.key) }.map(\.key)).intersection(stored)
        return (set, remove)
    }

    /// Secrets to the Keychain first, then keys and plain values to the store. Whether it was
    /// saved (nothing to save counts); a failure leaves the edits on screen.
    @discardableResult
    private func save() async -> Bool {
        await classifyTyped()
        guard dirty else { return true }
        guard let current, var site = state?.site, let index = site.environments.firstIndex(where: { $0.id == current.id }) else { return false }
        let keys = draft.map { $0.key.trimmingCharacters(in: .whitespaces) }
        guard !keys.contains(where: \.isEmpty), Set(keys).count == keys.count else { store.errorMessage = L("env.invalidKeys"); return false }
        // One write in all.
        let changes = Self.secretChanges(draft, current: current.entries, stored: storedSecrets)
        if !changes.set.isEmpty || !changes.remove.isEmpty {
            guard await store.updateSecrets(project.id, current.id, set: changes.set, remove: changes.remove) else { return false }
        }
        site.environments[index].entries = draft.map { EnvEntry(key: $0.key.trimmingCharacters(in: .whitespaces), value: $0.secret ? "" : $0.value, secret: $0.secret) }
        guard await store.saveEnvs(project.id, site) else { return false }
        load()
        return true
    }
}
