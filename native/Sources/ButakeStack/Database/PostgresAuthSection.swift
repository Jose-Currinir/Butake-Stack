import SwiftUI

/// How Stack's PostgreSQL lets people in. A cluster Stack creates asks for a password; one made by
/// an earlier version may let any local program in as any user (`trust`) and stays so until the
/// user chooses «Exigir contraseña…», which can be undone.
struct PostgresAuthSection: View {
    @Bindable var client: DatabaseClient
    struct Auth: Decodable, Equatable { let state: String; let running: Bool; let canUndo: Bool; let rolesWithoutPassword: [String] }
    @State private var auth: Auth?
    @State private var confirmRequire = false
    @State private var confirmUndo = false

    var body: some View {
        Section {
            if let auth {
                HStack(spacing: 10) {
                    IconTile(symbol: auth.state == "trust" ? Symbols.noRootPassword : Symbols.certificate,
                             color: auth.state == "trust" ? TileColor.warning : TileColor.correct, size: 26)
                    Text(L("db.pgAuth.\(auth.state)")).frame(maxWidth: .infinity, alignment: .leading)
                    Spacer()
                    if auth.state == "trust" {
                        Button { confirmRequire = true } label: { Label(L("db.pgAuth.require"), systemImage: Symbols.locked) }
                            .buttonStyle(.borderedProminent).disabled(!auth.running)
                            .help(auth.running ? L("db.pgAuth.requireHelp") : L("db.pgAuth.notRunning"))
                            .accessibilityIdentifier("db.pgAuth.require")
                    } else if auth.canUndo {
                        Button { confirmUndo = true } label: { Label(L("db.pgAuth.undo"), systemImage: Symbols.rollback) }
                            .buttonStyle(.bordered).disabled(!auth.running)
                            .help(auth.running ? L("db.pgAuth.undoHelp") : L("db.pgAuth.notRunning"))
                            .accessibilityIdentifier("db.pgAuth.undo")
                    }
                }
            }
        } header: {
            Text(L("db.pgAuth.title"))
        } footer: {
            Text(L("db.pgAuth.help")).font(.uiCaption).foregroundStyle(.secondary)
        }
        .task { await load() }
        .confirmationDialog(L("db.pgAuth.requireConfirm"), isPresented: $confirmRequire) {
            Button(L("db.pgAuth.require")) { Task { await change("postgresRequirePassword", done: L("db.pgAuth.required")) } }
                .accessibilityIdentifier("db.pgAuth.requireConfirm")
            Button(L("common.cancel"), role: .cancel) {}
        } message: {
            Text(L("db.pgAuth.requireDetail") + (auth?.rolesWithoutPassword.isEmpty == false
                ? " " + String(format: L("db.pgAuth.rolesWithoutPassword"), auth?.rolesWithoutPassword.joined(separator: ", ") ?? "") : ""))
        }
        .confirmationDialog(L("db.pgAuth.undoConfirm"), isPresented: $confirmUndo) {
            Button(L("db.pgAuth.undo"), role: .destructive) { Task { await change("postgresAllowTrust", done: L("db.pgAuth.undone")) } }
                .accessibilityIdentifier("db.pgAuth.undoConfirm")
            Button(L("common.cancel"), role: .cancel) {}
        } message: { Text(L("db.pgAuth.undoDetail")) }
    }

    private func load() async {
        auth = try? await client.store.call(["method": "postgresAuth"])
    }

    private func change(_ method: String, done: String) async {
        do {
            auth = try await client.store.call(["method": method, "confirmed": true])
            client.store.notify(done)
            await client.loadConnections()
        } catch let failure as EngineFailure {
            client.store.errorMessage = failure.errorDescription ?? L("engine.requestFailed")
        } catch {
            client.store.errorMessage = L("engine.requestFailed")
        }
    }
}
