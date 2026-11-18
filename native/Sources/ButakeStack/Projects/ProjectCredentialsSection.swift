import SwiftUI

/// «Firma y credenciales» in a project's Resumen: what the vault holds for the apps linked to this
/// project, by name, kind, stage and expiry, each row leading to its item in the vault. Nothing is
/// revealed and the vault is never unlocked here: its index is encrypted, so while it is locked the
/// section is one line with «Desbloquear…», and while the tool is off, one with «Activar en Ajustes…».
/// Without a vault, or unlocked with nothing linked, the section is not shown.
/// Of a part, it also lists the apps linked to its project of several parts; of a project of
/// several parts, the apps linked to it.
struct ProjectCredentialsSection: View {
    @Bindable var store: StackStore
    /// The link of the apps it lists: a project's id, or a project of several parts' link.
    let link: String
    /// The project of several parts the project is a part of.
    let composite: String?
    @Bindable var vault = VaultSession.shared

    init(store: StackStore, project: Project) {
        self.store = store
        link = project.id
        composite = store.composite(of: project.id)?.id
    }

    init(store: StackStore, composite group: ProjectGroup) {
        self.store = store
        link = VaultProjects.link(composite: group.id)
        composite = nil
    }

    var body: some View {
        Group {
            if vault.disk.exists {
                if !store.pluginEnabled("vault") {
                    Section(L("project.credentials")) {
                        line(L("project.credentials.off"), action: L("project.credentials.enable"), symbol: Symbols.settings, id: "project.credentials.enable") {
                            SettingsRouter.shared.open(.tools, tool: "vault")
                        }
                    }
                } else if vault.isUnlocked {
                    let items = VaultProjects.items(of: link, composite: composite, in: vault.index)
                    let apps = VaultProjects.apps(of: link, composite: composite, in: vault.index)
                    if !items.isEmpty || !apps.isEmpty {
                        Section(L("project.credentials")) {
                            // What signing needs, by stage, first; then each item.
                            ForEach(apps) { app in
                                VaultSigningLink(vault: vault, container: app, title: String(format: L("vault.signing.heading"), app.name),
                                                 identifier: "project.credentials.signing.\(app.folderName)") { VaultProjects.openSigning(app) }
                            }
                            ForEach(items) { ProjectCredentialRow(item: $0) }
                        }
                    }
                } else if vault.state == .locked {
                    Section(L("project.credentials")) {
                        line(L("project.credentials.locked"), action: L("project.credentials.unlock"), symbol: Symbols.unlock, id: "project.credentials.unlock") {
                            Task {
                                await vault.unlock()
                                if let message = vault.message { store.errorMessage = message; vault.message = nil }
                                // The import a link proposed opens in the vault, not here: say it waits there.
                                if vault.linkedPreviewWaiting { store.notify(L("vault.link.previewWaiting")) }
                            }
                        }
                    }
                }
            }
        }
        .task { vault.refreshState() }
    }

    private func line(_ text: String, action: String, symbol: String, id: String, run: @escaping () -> Void) -> some View {
        LabeledContent {
            Button(action: run) { Label(action, systemImage: symbol) }.buttonStyle(.bordered).accessibilityIdentifier(id)
        } label: {
            HStack(spacing: 10) {
                IconTile(symbol: Symbols.vault, size: 24)
                Text(text).foregroundStyle(.secondary)
            }
        }
    }
}

/// One item: its kind's tile, name and kind, its stage and its expiry; the row opens it in the vault.
private struct ProjectCredentialRow: View {
    let item: VaultItem
    var body: some View {
        Button { VaultProjects.open(item) } label: {
            HStack(spacing: 10) {
                IconTile(symbol: item.kind.symbol, color: VaultStyle.tint(item.kind), size: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.name).lineLimit(1).truncationMode(.middle).help(item.name)
                    Text(L("vault.kind.\(item.kind.rawValue)")).font(.uiCaption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                if let kind = item.environment.envKind { Chip(text: item.environment.title, symbol: kind.symbol, tint: kind.color) }
                if let expires = item.metadata.expires { Chip(expiry: item, date: expires) }
                Image(systemName: Symbols.forward).font(.uiCaption).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(HighlightButtonStyle())
        .help(L("project.credentials.open"))
        .accessibilityIdentifier("project.credentials.item.\(item.name)")
    }
}
