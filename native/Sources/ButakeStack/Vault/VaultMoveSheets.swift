import SwiftUI

/// «Mover a Entornos de…»: a `.env` kept in the vault goes to an environment of a project. The sheet
/// shows only the names of the variables (and which ones it creates or replaces); moving asks for a
/// confirmation and the vault's presence check, writes the values to the Keychain, reads them back,
/// and only then offers to delete the original.
struct VaultMoveEnvSheet: View {
    @Bindable var vault: VaultSession
    let item: VaultItem
    @Environment(\.dismiss) private var dismiss
    @State private var project: String?
    @State private var target: String?
    @State private var names: [String] = []
    @State private var problem: String?
    @State private var confirming = false
    @State private var moved: Int?
    private var store: StackStore { .shared }

    private var projects: [Project] { store.projects.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending } }
    private var environments: [EnvEnvironment] { project.flatMap { store.envs[$0]?.site.environments } ?? [] }
    private var targets: [VaultMove.EnvTarget] { VaultMove.targets(environments) }
    private var chosen: VaultMove.EnvTarget? { targets.first { $0.id == target } }
    private var preview: VaultMove.EnvPreview { VaultMove.preview(names: names, existing: environments.first { $0.id == target }) }
    private var projectTitle: String { projects.first { $0.id == project }?.title ?? "" }

    var body: some View {
        SheetFrame(title: L("vault.move.env.title"), symbol: Symbols.environments, detail: String(format: L("vault.move.env.detail"), item.name),
                   width: 560, height: 560,
                   actionTitle: moved == nil ? L("vault.move.action") : L("common.done"),
                   actionID: moved == nil ? "vault.sheet.moveEnv.confirm" : "vault.sheet.moveEnv.done",
                   canAct: moved != nil || (chosen != nil && !names.isEmpty),
                   cancelID: moved == nil ? "vault.sheet.moveEnv.cancel" : nil,
                   action: { if moved != nil { return true }; confirming = true; return false }) {
            if let moved {
                VaultMoveDone(vault: vault, item: item, title: String(format: L("vault.move.env.done"), moved, projectTitle, chosen?.name ?? ""), prefix: "vault.sheet.moveEnv") {
                    Button { dismiss(); if let project { VaultProjects.openProject(project, tab: .envs) } } label: {
                        Label(L("vault.project.openEnvironments"), systemImage: Symbols.environments)
                    }
                    .buttonStyle(.bordered).accessibilityIdentifier("vault.sheet.moveEnv.openEnvironments")
                }
            } else {
                form
            }
        } status: {
            Label(L("vault.move.valuesNote"), systemImage: Symbols.locked).font(.uiCaption).foregroundStyle(.secondary)
        }
        .confirmationDialog(String(format: L("vault.move.env.confirmTitle"), names.count, projectTitle, chosen?.name ?? ""), isPresented: $confirming) {
            Button(L("vault.move.action"), role: preview.replaced.isEmpty ? nil : .destructive) { Task { await run() } }
            Button(L("common.cancel"), role: .cancel) {}
        } message: {
            Text(preview.replaced.isEmpty ? L("vault.move.env.confirmDetail") : String(format: L("vault.move.env.confirmReplace"), preview.replaced.count))
        }
        .task {
            do { names = try VaultMove.envNames(item, vault: vault) } catch { problem = L((error as? VaultMove.Failure)?.messageKey ?? VaultError.io.messageKey) }
            project = vault.index.container(item.container)?.project.flatMap { id in projects.contains { $0.id == id } ? id : nil }
            #if DEBUG
            await VaultQA.moveStage(confirming: $confirming) { await run() }
            #endif
        }
        .onChange(of: project, initial: true) { _, id in
            guard let id else { target = nil; return }
            Task {
                await store.loadEnvs(id)
                target = VaultMove.suggestedTarget(for: item, in: targets, active: store.envs[id]?.site.active)?.id
            }
        }
    }

    private var form: some View {
        Form {
            Section {
                Picker(L("vault.project"), selection: $project) {
                    Text(L("vault.move.chooseProject")).tag(String?.none)
                    ForEach(projects) { Text($0.title).tag(String?.some($0.id)) }
                }
                .accessibilityIdentifier("vault.sheet.moveEnv.project")
                Picker(L("vault.environment"), selection: $target) {
                    if project == nil { Text(L("vault.project.none")).tag(String?.none) }
                    ForEach(targets) { target in
                        Label(target.exists ? target.name : String(format: L("vault.move.env.new"), target.name), systemImage: target.kind.symbol)
                            .tag(String?.some(target.id))
                    }
                }
                .disabled(project == nil)
                .accessibilityIdentifier("vault.sheet.moveEnv.environment")
            }
            if let problem { Section { Notice(.warning, problem) } }
            if !names.isEmpty {
                Section(String(format: L("vault.move.env.variables"), names.count)) {
                    ForEach(names, id: \.self) { name in
                        LabeledContent {
                            if chosen != nil {
                                let replaces = preview.replaced.contains(name)
                                Chip(text: L(replaces ? "vault.move.replaces" : "vault.move.creates"), tint: replaces ? Brand.warning : Brand.info)
                            }
                        } label: {
                            Text(name).font(.uiCallout.monospaced()).lineLimit(1).truncationMode(.middle).help(name)
                        }
                        .accessibilityIdentifier("vault.sheet.moveEnv.variable.\(name)")
                    }
                }
            }
        }
        .formStyle(.grouped).themedScroll()
    }

    /// Where the values go: the Keychain (an isolated memory store in a QA window).
    private var secrets: EnvSecretStore {
        #if DEBUG
        if let qa = VaultQA.envSecrets { return qa }
        #endif
        return EnvSecrets.keychain
    }

    private func run() async {
        guard let project, let chosen else { return }
        problem = nil
        guard await vault.confirmPresence(L("vault.auth.move"), fresh: true) else { return }
        do {
            moved = try await VaultMove.moveEnv(item, vault: vault, project: project, target: chosen, engine: store.engine, secrets: secrets, actor: store.actor)
            await store.loadEnvs(project)
        } catch {
            problem = VaultMove.message(error)
        }
    }
}

/// «Mover a Claves SSH»: an SSH key kept in the vault becomes one of Stack's keys (Ajustes › Claves SSH).
struct VaultMoveKeySheet: View {
    @Bindable var vault: VaultSession
    let item: VaultItem
    @Environment(\.dismiss) private var dismiss
    @State private var problem: String?
    @State private var confirming = false
    @State private var moved: SSHKey?
    @State private var hasKey = false

    var body: some View {
        SheetFrame(title: L("vault.move.key.title"), symbol: Symbols.key, detail: String(format: L("vault.move.key.detail"), item.name),
                   width: 520, height: 420,
                   actionTitle: moved == nil ? L("vault.move.action") : L("common.done"),
                   actionID: moved == nil ? "vault.sheet.moveKey.confirm" : "vault.sheet.moveKey.done",
                   canAct: moved != nil || hasKey,
                   cancelID: moved == nil ? "vault.sheet.moveKey.cancel" : nil,
                   action: { if moved != nil { return true }; confirming = true; return false }) {
            if let moved {
                VaultMoveDone(vault: vault, item: item, title: String(format: L("vault.move.key.done"), moved.name), prefix: "vault.sheet.moveKey") {
                    Button { dismiss(); SettingsRouter.shared.open(.keys) } label: { Label(L("settings.manageKeys"), systemImage: Symbols.key) }
                        .buttonStyle(.bordered).accessibilityIdentifier("vault.sheet.moveKey.openKeys")
                }
            } else {
                Form {
                    Section {
                        LabeledContent(L("common.name"), value: item.name)
                        if let fingerprint = item.metadata.value("vault.meta.fingerprint") {
                            InfoRow(title: L("vault.meta.fingerprint"), value: fingerprint, mono: true)
                        }
                        LabeledContent(L("vault.field.passphrase")) {
                            Text(L(item.field(.passphrase)?.value.isEmpty == false ? "vault.move.key.withPassphrase" : "vault.move.key.noPassphrase"))
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let problem { Section { Notice(.warning, problem) } }
                }
                .formStyle(.grouped).themedScroll()
            }
        } status: {
            Label(L("vault.move.valuesNote"), systemImage: Symbols.locked).font(.uiCaption).foregroundStyle(.secondary)
        }
        .confirmationDialog(String(format: L("vault.move.key.confirmTitle"), item.name), isPresented: $confirming) {
            Button(L("vault.move.action")) { Task { await run() } }
            Button(L("common.cancel"), role: .cancel) {}
        } message: { Text(L("vault.move.key.confirmDetail")) }
        .task {
            hasKey = (try? VaultMove.privateKey(item, vault: vault)) != nil
            if !hasKey { problem = L(VaultMove.Failure.noFile.messageKey) }
            #if DEBUG
            await VaultQA.moveStage(confirming: $confirming) { await run() }
            #endif
        }
    }

    private func run() async {
        problem = nil
        guard await vault.confirmPresence(L("vault.auth.move"), fresh: true) else { return }
        do {
            moved = try await VaultMove.moveKey(item, vault: vault, engine: StackStore.shared.engine)
            await SSHKeyring.shared.load()
        } catch {
            problem = VaultMove.message(error)
        }
    }
}

/// After a move, checked: what moved and where, the way there, and the offer (never more) to delete
/// the original from the vault, with its own confirmation.
private struct VaultMoveDone<Go: View>: View {
    @Bindable var vault: VaultSession
    let item: VaultItem
    let title: String
    let prefix: String
    @ViewBuilder let go: Go
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingDelete = false

    var body: some View {
        Form {
            Section { Notice(.info, title, symbol: Symbols.success) }
            Section {
                LabeledContent(L("vault.move.original")) {
                    Button(role: .destructive) { confirmingDelete = true } label: { Label(L("vault.deleteItemEllipsis"), systemImage: Symbols.delete) }
                        .buttonStyle(.bordered).accessibilityIdentifier("\(prefix).deleteOriginal")
                }
                LabeledContent(L("vault.move.goThere")) { go }
            } footer: {
                Text(L("vault.move.keepHint")).font(.uiCaption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped).themedScroll()
        .confirmationDialog(String(format: L("vault.deleteItemTitle"), item.name), isPresented: $confirmingDelete) {
            Button(L("common.delete"), role: .destructive) { VaultActions.delete(item, vault); dismiss() }
            Button(L("common.cancel"), role: .cancel) {}
        } message: { Text(L("vault.deleteItemDetail")) }
    }
}
