import SwiftUI

/// «Firma» of an app, in place of its page: by stage, what is ready to sign and publish, what is
/// missing and what does not fit, each row leading to its item or to adding what is missing. Nothing
/// here reveals a value.
struct VaultSigningDetail: View {
    @Bindable var vault: VaultSession
    let container: VaultContainer
    @State private var rereading = false

    var body: some View {
        let rows = VaultSigning.rows(for: container, environment: vault.signingEnvironment, in: vault.index)
        Form {
            Section {
                HStack(spacing: 12) {
                    IconTile(symbol: Symbols.certificate, color: VaultSigningStyle.tile(VaultSigning.worst(rows)), size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(format: L("vault.signing.heading"), container.name)).font(.uiTitle3.weight(.semibold)).lineLimit(2)
                        Text(VaultSigning.summary(rows)).font(.uiCallout).foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("vault.signing.header")
                Picker(L("vault.environment"), selection: $vault.signingEnvironment) {
                    ForEach(VaultSigning.environments) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("vault.signing.environment")
            }
            ForEach(VaultSigning.Platform.allCases) { platform in
                let list = rows.filter { $0.platform == platform }
                if !list.isEmpty {
                    Section(L("vault.part.\(platform.rawValue)")) {
                        ForEach(list) { VaultSigningRow(vault: vault, container: container, row: $0) }
                    }
                }
            }
            Section {
                HStack {
                    Button { Task { await reread() } } label: { Label(L("vault.signing.reread"), systemImage: Symbols.reload) }
                        .buttonStyle(.bordered).disabled(rereading)
                        .help(L("vault.signing.rereadHelp")).accessibilityIdentifier("vault.signing.reread")
                    Spacer()
                }
            } footer: {
                Text(L("vault.signing.footer")).font(.uiCaption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .font(.uiBody)
        .themedScroll()
        .accessibilityIdentifier("vault.signing")
        .simultaneousGesture(TapGesture().onEnded { vault.touch() })
    }

    private func reread() async {
        rereading = true
        defer { rereading = false }
        let count = await vault.reread(container.id)
        vault.notice = String(format: L("vault.signing.reread.done"), count)
    }
}

/// A row: its state's tile, what it is, what was found and what to do; it opens its item, and what is
/// missing has «Agregar…» at its end.
struct VaultSigningRow: View {
    @Bindable var vault: VaultSession
    let container: VaultContainer
    let row: VaultSigning.Row

    var body: some View {
        HStack(spacing: 8) {
            if let item = row.item {
                Button { vault.inspected = item } label: {
                    HStack(spacing: 8) {
                        content
                        Image(systemName: Symbols.forward).font(.uiCaption).foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(HighlightButtonStyle())
                .help(L("vault.openItem"))
                .accessibilityIdentifier("vault.signing.row.\(row.id)")
            } else {
                content.accessibilityIdentifier("vault.signing.row.\(row.id)")
            }
            if let kind = row.add {
                Button {
                    var draft = VaultActions.draft(kind, in: container, section: row.platform == .android ? .android : .ios)
                    draft.environment = vault.signingEnvironment
                    vault.sheet = .item(draft)
                } label: { Label(L("vault.signing.add"), systemImage: Symbols.add) }
                    .buttonStyle(.bordered)
                    .help(row.advice ?? L("vault.signing.add"))
                    .accessibilityIdentifier("vault.signing.add.\(row.id)")
            }
        }
    }

    private var content: some View {
        HStack(spacing: 10) {
            IconTile(symbol: VaultSigningStyle.symbol(row.status), color: VaultSigningStyle.tile(row.status), size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title).font(.uiBody.weight(.medium)).lineLimit(1).truncationMode(.middle).help(row.title)
                Text(row.detail).font(.uiCaption).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle).help(row.detail)
                if let advice = row.advice {
                    Text(advice).font(.uiCaption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 6)
            Chip(text: L("vault.signing.status.\(row.status.key)"), tint: VaultSigningStyle.tint(row.status))
        }
    }
}

/// One tile and chip per state: green only when ready.
enum VaultSigningStyle {
    static func symbol(_ status: VaultSigning.Status) -> String {
        switch status {
        case .ready: Symbols.success
        case .expiring: Symbols.expiring
        case .missing: Symbols.pending
        case .mismatch: Symbols.error
        }
    }

    @MainActor static func tile(_ status: VaultSigning.Status?) -> Color {
        switch status {
        case .ready?: TileColor.correct
        case .expiring?: TileColor.warning
        case .mismatch?: TileColor.error
        default: TileColor.system
        }
    }

    @MainActor static func tint(_ status: VaultSigning.Status) -> Color {
        switch status {
        case .ready: Brand.success
        case .expiring: Brand.warning
        case .missing: .secondary
        case .mismatch: Brand.danger
        }
    }
}

/// «Firma» in an app's page and in a project's Resumen: both stages in one row that opens it.
struct VaultSigningLink: View {
    @Bindable var vault: VaultSession
    let container: VaultContainer
    var title: String = L("vault.signing.title")
    let identifier: String
    let open: () -> Void

    var body: some View {
        let reports = VaultSigning.environments.map { ($0, VaultSigning.rows(for: container, environment: $0, in: vault.index)) }
        Button(action: open) {
            HStack(spacing: 10) {
                IconTile(symbol: Symbols.certificate, color: VaultSigningStyle.tile(reports.compactMap { VaultSigning.worst($0.1) }.max()), size: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).lineLimit(1).truncationMode(.middle)
                    ForEach(reports, id: \.0) { environment, rows in
                        Text("\(environment.title): \(VaultSigning.summary(rows))").font(.uiCaption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: Symbols.forward).font(.uiCaption).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(HighlightButtonStyle())
        .help(L("vault.signing.openHelp"))
        .accessibilityIdentifier(identifier)
    }
}
