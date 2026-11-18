import SwiftUI

/// Shows exactly what will run and where; the worst cases ask for the name typed again. The run
/// button is never the default one: Return does not confirm a change.
struct ConfirmChangeSheet: View {
    let pending: PendingConfirmation
    @State private var typed = ""
    @State private var typedConnection = ""
    @Environment(\.dismiss) private var dismiss
    var ready: Bool {
        (pending.typedName.map { typed == $0 } ?? true) && (pending.typedConnection.map { typedConnection == $0 } ?? true)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if pending.typedConnection != nil {
                Label(L("db.mode.productionBanner"), systemImage: Symbols.error)
                    .font(.uiCallout.weight(.bold)).foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 6).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Brand.danger, in: RoundedRectangle(cornerRadius: Radius.row))
                    .accessibilityIdentifier("db.confirm.productionBanner")
            }
            HStack(spacing: 12) {
                IconTile(symbol: Symbols.warning, color: pending.typedConnection != nil ? TileColor.error : TileColor.warning, size: 30)
                Text(pending.title).font(.uiTitle3.weight(.semibold)).frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("db.confirm.title")
            }
            if !pending.statements.isEmpty {
                Text(L("db.confirm.willRun")).foregroundStyle(.secondary)
                ScrollView {
                    Text(pending.statements.joined(separator: ";\n\n") + ";")
                        .font(.uiMonospaced).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                }
                .frame(minHeight: 60, maxHeight: 260)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: Radius.row))
                .accessibilityIdentifier("db.confirm.statements")
            }
            if let name = pending.typedName {
                Text(String(format: L("db.confirm.typeName"), name)).foregroundStyle(.secondary)
                TextField(name, text: $typed).textFieldStyle(.roundedBorder).accessibilityIdentifier("db.confirm.typed")
            }
            if let connection = pending.typedConnection {
                Text(String(format: L("db.confirm.typeConnection"), connection)).foregroundStyle(Brand.dangerText)
                TextField(connection, text: $typedConnection).textFieldStyle(.roundedBorder).accessibilityIdentifier("db.confirm.typedConnection")
            }
            HStack {
                Spacer()
                Button(L("common.cancel")) { pending.resume(false, ""); dismiss() }.keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("db.confirm.cancel")
                Button(role: .destructive) {
                    pending.typed.connection = typedConnection
                    pending.resume(true, typed)
                    dismiss()
                } label: {
                    Label(pending.statements.isEmpty ? L("db.confirm.continue") : L("db.confirm.run"), systemImage: pending.statements.isEmpty ? Symbols.forward : Symbols.start)
                }
                .buttonStyle(.borderedProminent).tint(Brand.danger)
                .disabled(!ready)
                .accessibilityIdentifier("db.confirm.run")
            }
        }
        .padding(22)
        .frame(minWidth: 520, idealWidth: 560)
    }
}

/// An SSH server seen for the first time: its fingerprints, to compare before trusting it.
struct HostCheckSheet: View {
    let client: DatabaseClient
    let check: DatabaseClient.HostCheck
    var body: some View {
        SheetFrame(title: L("db.ssh.unknownTitle"), symbol: Symbols.hostKey,
                   detail: String(format: L("db.ssh.unknownDetail"), check.connection.ssh?.host ?? ""),
                   width: 540, actionTitle: L("db.ssh.trust"), actionSymbol: Symbols.certificate, actionID: "db.hostCheck.trust",
                   cancelID: "db.hostCheck.cancel", action: {
                       await client.trust(check)
                       return true
                   }) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(check.fingerprints, id: \.self) { Text($0).font(.uiMonospaced).textSelection(.enabled) }
            }
            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: Radius.row))
            .accessibilityIdentifier("db.hostCheck.fingerprints")
        }
        .onDisappear { client.hostCheck = nil }
    }
}
