import SwiftUI

/// The vault's column: what is about to expire, then its apps and services. The search looks inside
/// the items (names, kinds, files, fields, notes); an app or service without matches is dimmed.
struct VaultList: View {
    @Bindable var vault = VaultSession.shared
    @State private var confirmingDelete: VaultContainer?

    private var apps: [VaultContainer] { sorted(.app) }
    private var services: [VaultContainer] { sorted(.service) }
    private var filtering: Bool { vault.kindFilter != nil || !vault.search.isEmpty || vault.expiryFilter != .all }

    var body: some View {
        List(selection: $vault.selection) {
            if !vault.expiringItems.isEmpty {
                Label {
                    HStack { Text(L("vault.expiring")); Spacer(); count(vault.expiringItems.count, tint: Brand.warning) }
                } icon: {
                    IconTile(symbol: Symbols.expiring, color: TileColor.warning, size: 20)
                }
                .tag(VaultSession.Selection.expiring)
                .accessibilityIdentifier("vault.list.expiring")
            }
            Section(L("vault.apps")) {
                ForEach(apps) { row($0) }
                if apps.isEmpty { placeholder(L("vault.noApps")) }
            }
            Section(L("vault.services")) {
                ForEach(services) { row($0) }
                if services.isEmpty { placeholder(L("vault.noServices")) }
            }
        }
        .listStyle(.sidebar)
        .font(.uiBody)
        .themedScroll()
        .searchable(text: $vault.search, placement: .sidebar, prompt: L("vault.search"))
        // ⌫ on the selected app or service, like the menu's «Eliminar» (which confirms).
        .onDeleteCommand {
            if case .container(let id) = vault.selection, let container = (apps + services).first(where: { $0.id == id }) { confirmingDelete = container }
        }
        .accessibilityIdentifier("vault.list")
        .onAppear {
            if vault.selection == nil, let first = apps.first ?? services.first { vault.selection = .container(first.id) }
        }
        .simultaneousGesture(TapGesture().onEnded { vault.touch() })
        .confirmationDialog(String(format: L("vault.deleteContainerTitle"), confirmingDelete?.title ?? ""),
                            isPresented: Binding(get: { confirmingDelete != nil }, set: { if !$0 { confirmingDelete = nil } }),
                            presenting: confirmingDelete) { container in
            Button(L("common.delete"), role: .destructive) {
                do { try vault.deleteContainer(container.id) } catch { vault.message = L((error as? VaultError)?.messageKey ?? "vault.error.io") }
            }
            Button(L("common.cancel"), role: .cancel) {}
        } message: { _ in Text(L("vault.deleteContainerDetail")) }
    }

    private func sorted(_ kind: VaultContainer.Kind) -> [VaultContainer] {
        vault.index.containers.filter { $0.kind == kind }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text).font(.uiCaption).foregroundStyle(.secondary).selectionDisabled()
    }

    private func row(_ container: VaultContainer) -> some View {
        let visible = vault.visibleItems(in: container.id).count
        let total = vault.index.items(in: container.id).count
        return Label {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(container.title).font(.uiBody).lineLimit(1)
                    if let detail = container.bundleId ?? container.subtitlePath {
                        Text(detail).font(.uiCaption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(detail)
                    }
                }
                Spacer(minLength: 4)
                if let worst = vault.worstExpiry(in: container.id) {
                    Image(systemName: Symbols.warning).foregroundStyle(worst == .expired ? Brand.danger : Brand.warning)
                        .help(worst == .expired ? L("vault.hasExpired") : L("vault.hasExpiring"))
                        .accessibilityLabel(worst == .expired ? L("vault.hasExpired") : L("vault.hasExpiring"))
                }
                count(filtering ? visible : total, tint: .secondary)
            }
        } icon: {
            IconTile(symbol: container.kind == .app ? Symbols.app : Symbols.server, size: 20)
        }
        .tag(VaultSession.Selection.container(container.id))
        .opacity(visible == 0 && filtering ? 0.45 : 1)
        .accessibilityIdentifier("vault.container.\(container.folderName)")
        .vaultFileDrop(vault, container: container.id)
        .contextMenu { containerMenu(container) }
    }

    /// The same actions as the toolbar's menu for the app or service, with Eliminar last.
    @ViewBuilder private func containerMenu(_ container: VaultContainer) -> some View {
        Button { VaultActions.chooseFiles(vault, container: container.id, section: nil) } label: { Label(L("vault.addFiles"), systemImage: Symbols.addFiles) }
            .accessibilityIdentifier("vault.menu.addFiles")
        Button { vault.sheet = .editContainer(container.id) } label: { Label(L("vault.editContainer"), systemImage: Symbols.edit) }
            .accessibilityIdentifier("vault.menu.edit")
        if let bundle = container.bundleId {
            Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(bundle, forType: .string) } label: {
                Label(L("vault.copyBundle"), systemImage: Symbols.copy)
            }
            .accessibilityIdentifier("vault.menu.copyBundle")
        }
        Divider()
        Button { vault.sheet = .exportArchive(container.id) } label: { Label(L("vault.backupOne"), systemImage: Symbols.backup) }
            .accessibilityIdentifier("vault.menu.backup")
        Button { vault.sheet = .download(container.id) } label: { Label(L("vault.downloadOne"), systemImage: Symbols.dump) }
            .accessibilityIdentifier("vault.menu.download")
        Divider()
        Button(role: .destructive) { confirmingDelete = container } label: { Label(L("vault.deleteContainer"), systemImage: Symbols.delete) }
            .accessibilityIdentifier("vault.menu.delete")
    }

    private func count(_ value: Int, tint: Color) -> some View {
        Text("\(value)").font(.uiSubheadline.weight(.medium)).foregroundStyle(tint).monospacedDigit()
    }
}

extension View {
    /// Files dropped from Finder are encrypted into the app or service, with the same notice as «Agregar archivos…».
    /// The destination takes the accent border while a drag is over it.
    func vaultFileDrop(_ vault: VaultSession, container: UUID) -> some View { modifier(VaultFileDrop(vault: vault, container: container)) }
}

private struct VaultFileDrop: ViewModifier {
    let vault: VaultSession
    let container: UUID
    @State private var targeted = false
    func body(content: Content) -> some View {
        content
            .dropDestination(for: URL.self) { urls, _ in
                Task {
                    let added = await vault.add(files: urls, to: container, section: nil)
                    if added > 0 { vault.notice = String(format: L("vault.added"), added) }
                }
                return true
            } isTargeted: { targeted = $0 }
            .overlay { if targeted { RoundedRectangle(cornerRadius: 6).stroke(Brand.accent, lineWidth: 2).allowsHitTesting(false) } }
    }
}
