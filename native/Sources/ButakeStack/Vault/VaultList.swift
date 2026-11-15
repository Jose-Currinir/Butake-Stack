import SwiftUI

/// The vault's column: what is about to expire, then its apps and services. The search looks inside
/// the items (names, kinds, files, fields, notes); an app or service without matches is dimmed.
struct VaultList: View {
    @Bindable var vault = VaultSession.shared

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
        .accessibilityIdentifier("vault.list")
        .onAppear {
            if vault.selection == nil, let first = apps.first ?? services.first { vault.selection = .container(first.id) }
        }
        .simultaneousGesture(TapGesture().onEnded { vault.touch() })
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
        .dropDestination(for: URL.self) { urls, _ in
            Task { await vault.add(files: urls, to: container.id, section: nil) }
            return true
        }
    }

    private func count(_ value: Int, tint: Color) -> some View {
        Text("\(value)").font(.uiSubheadline.weight(.medium)).foregroundStyle(tint).monospacedDigit()
    }
}
