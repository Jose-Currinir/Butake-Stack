import AppKit
import SwiftUI

/// New environment: a standard kind (its name is the standard APP_ENV value), or a custom one, and
/// where its variables start from.
struct NewEnvironmentSheet: View {
    let store: StackStore
    let project: Project
    let current: EnvEnvironment?
    let created: (String) -> Void
    @State private var kind: EnvKind = .development
    @State private var customName = ""
    @State private var base = "__example__"
    var taken: Set<String> { Set(store.envs[project.id]?.site.environments.map(\.id) ?? []) }
    var hasExample: Bool { store.envs[project.id]?.exampleKeys.isEmpty == false }
    var name: String { kind == .other ? customName : L("env.kind.\(kind.rawValue)") }
    var identifier: String { kind.standard ?? StackStore.slug(customName) }
    var body: some View {
        SheetFrame(title: L("env.new"), symbol: Symbols.environments, detail: L("env.newDetail"), width: 520, height: 420,
                   actionTitle: L("common.create"), actionID: "env.create", canAct: !identifier.isEmpty && !taken.contains(identifier),
                   cancelID: "env.cancel") {
            guard let id = await store.createEnvironment(project, name: name, kind: kind, from: base.isEmpty ? nil : base) else { return false }
            created(id)
            return true
        } content: {
            Form {
                Section {
                    Picker(L("common.type"), selection: $kind) {
                        ForEach(EnvKind.allCases, id: \.self) { item in
                            let used = item.standard.map { taken.contains($0) } ?? false
                            Text(used ? "\(L("env.kind.\(item.rawValue)")) · \(L("env.exists"))" : L("env.kind.\(item.rawValue)"))
                                .tag(item).selectionDisabled(used)
                        }
                    }
                    .pickerStyle(.radioGroup).accessibilityIdentifier("env.kind")
                    if kind == .other {
                        TextField(L("common.name"), text: $customName).accessibilityIdentifier("env.name")
                    }
                    Picker(L("env.startFrom"), selection: $base) {
                        if hasExample { Text(verbatim: ".env.example").tag("__example__") }
                        if let current { Text(String(format: L("env.base.copy"), current.title)).tag(current.id) }
                        Text(L("env.base.empty")).tag("")
                    }
                    .accessibilityIdentifier("env.base")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L("env.kindDetail.\(kind.rawValue)") + " " + String(format: L("env.appEnvNote"), identifier.isEmpty ? "…" : identifier))
                        if kind == .production { Text(L("env.productionNote")).foregroundStyle(Brand.danger) }
                    }
                    .font(.uiCaption).foregroundStyle(.secondary).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .formStyle(.grouped).themedScroll()
        }
        .onAppear {
            kind = EnvKind.allCases.first { $0.standard.map { !taken.contains($0) } ?? true } ?? .other
            if !hasExample { base = current?.id ?? "" }
        }
    }
}

/// A new value for a secret, typed and never shown.
struct SecretEditor: View {
    let key: String
    let save: (String) -> Void
    @State private var value = ""
    var body: some View {
        SheetFrame(title: String(format: L("env.secretTitle"), key), symbol: Symbols.key, note: L("env.secretNote"), width: 440,
                   actionTitle: L("common.save"), actionID: "env.secretSave", cancelID: "env.secretCancel") {
            save(value)
            return true
        } content: {
            SecureField(L("env.secretValue"), text: $value).textFieldStyle(.roundedBorder).accessibilityIdentifier("env.secretValue")
        }
    }
}

/// Production: type the project's name, then Touch ID or the Mac's password (R4).
struct ProductionConfirm: View {
    let store: StackStore
    let project: Project
    let env: EnvEnvironment
    @Environment(\.dismiss) private var dismiss
    @State private var typed = ""
    var body: some View {
        SheetFrame(title: String(format: L("env.productionTitle"), project.title), symbol: EnvKind.production.symbol,
                   detail: L("env.productionDetail"), width: 480,
                   actionTitle: L("env.productionActivate"), actionID: "env.productionConfirm", canAct: typed == project.title,
                   cancelID: "env.productionCancel") {
            dismiss()
            await store.activateEnvironment(project, env, confirmedProduction: true)
            return false
        } content: {
            TextField(project.title, text: $typed).textFieldStyle(.roundedBorder).accessibilityIdentifier("env.productionName")
        }
        .tint(Brand.danger)
    }
}

/// Who did what with this project's environments; never values (R7).
struct EnvAuditSheet: View {
    let store: StackStore
    let project: Project
    @State private var entries: [AuditRow] = []
    struct AuditRow: Identifiable {
        let id: Int
        let entry: EnvAuditEntry
        var date: String { Format.shortDateTime(Date(timeIntervalSince1970: TimeInterval(entry.ts))) }
        var what: String { [entry.env, entry.key].filter { !$0.isEmpty }.joined(separator: " · ") }
    }
    var body: some View {
        SheetFrame(title: L("env.audit"), symbol: Symbols.history, note: L("env.auditNote"), width: 640, height: 440,
                   actionTitle: L("common.close"), actionID: "env.auditClose", action: { true }) {
            Table(entries) {
                TableColumn(L("env.audit.date"), value: \.date).width(min: 120, ideal: 150)
                TableColumn(L("env.audit.action")) { Text(L("env.action.\($0.entry.action)")) }.width(min: 70, ideal: 90)
                TableColumn(L("env.audit.what")) { Text($0.what).font(.uiCallout.monospaced()) }
                TableColumn(L("common.user"), value: \.entry.user).width(min: 70, ideal: 100)
            }
            .accessibilityIdentifier("env.auditTable")
        } status: {
            // R11: what to do if the Mac is lost or a secret leaks.
            Link(L("env.incident"), destination: URL(string: "https://github.com/Jose-Currinir/Butake-Stack/blob/main/.compliance/docs/21719-gestor-entornos-incidentes.md")!)
                .font(.uiCaption.weight(.medium))
        }
        .task {
            let list: [EnvAuditEntry] = (try? await store.call(["method": "envAuditLog", "id": project.id])) ?? []
            entries = list.enumerated().map { AuditRow(id: $0.offset, entry: $0.element) }
        }
    }
}
