import SwiftUI

/// A problem in the shared notice: what happened and what to do, and the server's own text
/// folded away as a technical detail.
struct DBProblemCard: View {
    let problem: DBProblem
    @State private var showDetail = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Notice(problem.kind == .syntax ? .warning : .error, problem.title, detail: problem.message, symbol: problem.symbol)
            if let detail = problem.detail {
                DisclosureGroup(isExpanded: $showDetail) {
                    Text(detail).font(.uiSubheadline.monospaced()).foregroundStyle(.secondary)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
                } label: {
                    Text(L("db.problem.detail")).font(.uiCaption).foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("db.problem.detail")
            }
        }
        .accessibilityIdentifier("db.problem")
    }
}


/// A connection that does not answer: one clear page with what happened and what to do, instead
/// of empty panels.
struct ConnectionProblemView: View {
    @Bindable var client: DatabaseClient
    let connection: DBConnection
    let problem: DBProblem
    @State private var password = ""
    @State private var trying = false
    @State private var failed: DBProblem?
    var body: some View {
        Form {
            Section {
                DBProblemCard(problem: failed ?? problem)
                if [.needsPassword, .wrongPassword].contains(problem.kind) && connection.builtin {
                    LabeledContent(connection.id == DatabaseVault.mysqlRoot ? L("db.root.existingField") : L("db.password")) {
                        HStack(spacing: 8) {
                            SecureField(L("db.password"), text: $password).labelsHidden().multilineTextAlignment(.leading)
                                .textFieldStyle(.roundedBorder).onSubmit { Task { await tryPassword() } }
                                .accessibilityIdentifier("db.problem.password")
                            Button { Task { await tryPassword() } } label: { Label(L("db.root.existingSave"), systemImage: Symbols.key) }
                                .buttonStyle(.borderedProminent).disabled(password.isEmpty || trying)
                                .accessibilityIdentifier("db.problem.savePassword")
                        }
                    }
                    .help(L("db.problem.keychainNote"))
                } else {
                    HStack {
                        Spacer()
                        if !connection.builtin && [.needsPassword, .wrongPassword, .offline, .tls, .ssh, .unknownDatabase].contains(problem.kind) {
                            Button { client.editing = connection } label: { Label(L("db.editConnectionEllipsis"), systemImage: Symbols.edit) }
                                .buttonStyle(.bordered).accessibilityIdentifier("db.problem.edit")
                        }
                        if let process = stoppedService {
                            Button { Task { await client.store.processAction(process, "start"); await client.check(connection) } } label: {
                                Label(String(format: L("db.problem.startService"), connection.tech.title), systemImage: Symbols.start)
                            }
                            .buttonStyle(.bordered).accessibilityIdentifier("db.problem.startService")
                        }
                        Button { Task { await client.check(connection) } } label: { Label(L("common.retry"), systemImage: Symbols.reload) }
                            .buttonStyle(.borderedProminent).accessibilityIdentifier("db.problem.retry")
                    }
                }
            }
            Section(L("db.connectionData")) {
                ConnectionFacts(client: client, connection: connection)
            }
        }
        .formStyle(.grouped)
        .themedScroll()
    }
    /// The supervised process of a Stack database that is not running (`stack-mysql` → `stack.mysql`).
    private var stoppedService: String? {
        guard connection.builtin, problem.kind == .offline else { return nil }
        let id = connection.id.replacingOccurrences(of: "stack-", with: "stack.")
        guard let process = client.store.status?.processes.first(where: { $0.id == id }), client.store.phase(id) != .running else { return nil }
        return process.id
    }

    /// Kept in the Keychain only if the server accepts it.
    func tryPassword() async {
        trying = true; defer { trying = false }
        let previous = DatabaseVault.read(connection.id)
        // A Keychain that could not answer (the user denied it, it is locked) is not «no password»: nothing is
        // replaced or deleted, because the real password could not be put back afterwards.
        if case .failed = previous { client.store.notify(L("db.keychainReadFailed")); return }
        guard DatabaseVault.set(password, for: connection.id, label: connection.id == DatabaseVault.mysqlRoot ? "MySQL root" : connection.title) else {
            client.store.notify(L("db.keychainSaveFailed")); return
        }
        await client.check(connection)
        if case .failed(let p) = client.status[connection.id] {
            switch previous {
            case .found(let data):
                if !DatabaseVault.set(String(decoding: data, as: UTF8.self), for: connection.id, label: connection.title) { client.store.notify(L("db.keychainRestoreFailed")) }
            default: DatabaseVault.delete(connection.id)
            }
            failed = p
        } else {
            password = ""
            client.store.notify(L("db.root.saved"))
            await client.loadConnections()
            await client.loadDatabases(connection)
        }
    }
}

/// Host, port, user, password, TLS and SSH of a connection, as the rows of a form section.
struct ConnectionFacts: View {
    let client: DatabaseClient
    let connection: DBConnection
    var body: some View {
        if connection.kind == "sqlite" {
            fact(L("db.file"), connection.path ?? "", symbol: Symbols.file, id: "file")
        } else {
            fact(L("db.host"), connection.host, symbol: Symbols.server, id: "host")
            fact(L("db.port"), String(connection.port), symbol: Symbols.port, id: "port")
            fact(L("common.user"), connection.user.isEmpty ? "—" : connection.user, symbol: Symbols.user, id: "user")
            fact(L("db.password"), passwordText, symbol: Symbols.key, id: "password")
            if !connection.database.isEmpty {
                fact(L("db.database"), connection.database, symbol: Symbols.database, id: "database")
            }
            if let ssh = connection.ssh {
                fact(L("db.ssh"), "\(ssh.user)@\(ssh.host):\(ssh.port)", symbol: Symbols.sshTunnel, id: "ssh")
            }
            fact(L("db.tls"), L("db.tls.\(connection.tls)"), symbol: Symbols.certificate, id: "tls")
        }
    }

    /// Long values (a file's path) are cut in the middle and shown whole in the help.
    private func fact(_ title: String, _ value: String, symbol: String, id: String) -> some View {
        LabeledContent {
            Text(value).textSelection(.enabled).lineLimit(1).truncationMode(.middle).help(value)
        } label: {
            Label(title, systemImage: symbol)
        }
        .accessibilityIdentifier("db.facts.\(id)")
    }

    var passwordText: String {
        if connection.builtin && connection.stackPassword { return L("db.passwordStack") }
        if connection.builtin && connection.id != DatabaseVault.mysqlRoot && !connection.hasPassword { return L("db.passwordTrust") }
        return connection.hasPassword ? L("db.passwordKeychain") : L("db.passwordNone")
    }
}
