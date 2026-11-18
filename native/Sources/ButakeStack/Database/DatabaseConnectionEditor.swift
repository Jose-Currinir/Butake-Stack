import AppKit
import SwiftUI

// MARK: - Connection editor

/// A new or saved connection: what it is, how it is protected, where the server is and the SSH
/// tunnel to reach it. Every field has its border; the password goes to the Keychain.
struct ConnectionEditor: View {
    let client: DatabaseClient
    /// Stack's SSH keys come from the base's session (Ajustes › Claves SSH).
    let keyring = SSHKeyring.shared
    let original: DBConnection
    @State private var draft: DBConnection
    @State private var password = ""
    @State private var useSSH = false
    @State private var sshHost = ""
    @State private var sshPort = 22
    @State private var sshUser = ""
    @State private var identity = ""
    init(client: DatabaseClient, original: DBConnection) {
        self.client = client
        self.original = original
        _draft = State(initialValue: original)
        _useSSH = State(initialValue: original.ssh != nil)
        _sshHost = State(initialValue: original.ssh?.host ?? "")
        _sshPort = State(initialValue: original.ssh?.port ?? 22)
        _sshUser = State(initialValue: original.ssh?.user ?? "")
        _identity = State(initialValue: original.ssh?.key.map { "stack:\($0)" } ?? original.ssh?.identity ?? "")
    }
    /// Private-key files in `~/.ssh`. Computed once off the main thread (`.task`), reading only each file's
    /// first bytes, never the whole key and never on each redraw.
    @State private var keys: [String] = []
    nonisolated static func scanKeys() -> [String] {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        let marker = Data("-----BEGIN".utf8)
        return files.filter { name in
            guard !name.hasSuffix(".pub"), !["known_hosts", "known_hosts.old", "config", "authorized_keys"].contains(name), !name.hasPrefix("."),
                  let handle = try? FileHandle(forReadingFrom: dir.appendingPathComponent(name)) else { return false }
            defer { try? handle.close() }
            return ((try? handle.read(upToCount: marker.count)) ?? Data()) == marker
        }.sorted().map { dir.appendingPathComponent($0).path }
    }
    var body: some View {
        SheetFrame(title: original.id.isEmpty ? L("db.newConnection") : L("db.editConnection"), symbol: Symbols.database,
                   width: 600, height: 640, actionTitle: L("common.save"), actionID: "db.editor.save", canAct: valid,
                   cancelID: "db.editor.cancel", action: {
                       await client.save(built, password: password.isEmpty ? nil : password)
                   }) {
            Form {
                Section(L("db.edit.general")) {
                    TextField(L("common.name"), text: $draft.name, prompt: Text(L("db.edit.namePlaceholder")))
                        .accessibilityIdentifier("db.editor.name").formField(L("common.name"))
                    Picker(L("common.type"), selection: $draft.kind) {
                        ForEach(["mysql", "mariadb", "postgres", "redis", "valkey", "sqlite"], id: \.self) { Text(Self.engineName($0)).tag($0) }
                    }
                    .accessibilityIdentifier("db.editor.engine")
                    .onChange(of: draft.kind) { _, kind in
                        draft.port = DBConnection.defaultPort(kind)
                        if draft.user == "root" || draft.user == "postgres" || draft.user.isEmpty {
                            draft.user = kind == "postgres" ? "postgres" : (kind == "redis" || kind == "valkey" ? "" : "root")
                        }
                    }
                }
                Section(L("db.edit.mode")) {
                    Toggle(isOn: $draft.production) {
                        Label(L("db.mode.production"), systemImage: Symbols.error).foregroundStyle(draft.production ? Brand.dangerText : .primary)
                        Text(L("db.mode.productionHelp")).font(.uiCaption).foregroundStyle(.secondary)
                    }
                    .accessibilityIdentifier("db.editor.production")
                    Toggle(isOn: $draft.readOnly) {
                        Label(L("db.mode.readOnly"), systemImage: Symbols.readOnly)
                        Text(L(draft.isRedis ? "db.mode.readOnlyHelpRedis" : "db.mode.readOnlyHelp")).font(.uiCaption).foregroundStyle(.secondary)
                    }
                    .accessibilityIdentifier("db.editor.readOnly")
                }
                if draft.kind == "sqlite" {
                    Section(L("db.edit.server")) {
                        LabeledContent(L("db.file")) {
                            HStack {
                                TextField(L("db.file"), text: Binding(get: { draft.path ?? "" }, set: { draft.path = $0 }), prompt: Text(L("db.edit.filePlaceholder")))
                                    .labelsHidden().textFieldStyle(.roundedBorder).multilineTextAlignment(.leading).accessibilityIdentifier("db.editor.file")
                                Button {
                                    let panel = NSOpenPanel()
                                    if panel.runModal() == .OK { draft.path = panel.url?.path }
                                } label: { Label(L("common.choose"), systemImage: Symbols.folder) }
                                    .buttonStyle(.bordered).accessibilityIdentifier("db.editor.chooseFile")
                            }
                        }
                    }
                } else {
                    serverSection
                    sshSection
                }
            }
            .formStyle(.grouped)
            .frame(minHeight: 420)
        }
        .task {
            keys = await Task.detached { Self.scanKeys() }.value
            await keyring.loadKeys()
        }
    }

    private var serverSection: some View {
        Section(L("db.edit.server")) {
            TextField(L("db.host"), text: $draft.host, prompt: Text(verbatim: "127.0.0.1"))
                .accessibilityIdentifier("db.editor.host").formField(L("db.host"))
            TextField(L("db.port"), value: $draft.port, format: .number.grouping(.never))
                .accessibilityIdentifier("db.editor.port").formField(L("db.port"))
            TextField(L("common.user"), text: $draft.user, prompt: draft.isRedis ? Text(L("db.edit.optional")) : nil)
                .accessibilityIdentifier("db.editor.user").formField(L("common.user"))
            SecureField(L("db.password"), text: $password, prompt: Text(original.hasPassword ? L("db.passwordKeep") : L("db.edit.passwordPlaceholder")))
                .accessibilityIdentifier("db.editor.password").formField(L("db.password"))
            if !draft.isRedis {
                TextField(L("db.database"), text: $draft.database, prompt: Text(L("db.edit.optional")))
                    .accessibilityIdentifier("db.editor.database").formField(L("db.database"))
            }
            Picker(L("db.tls"), selection: $draft.tls) {
                ForEach(["prefer", "require", "verify", "off"], id: \.self) { Text(L("db.tls.\($0)")).tag($0) }
            }
            .accessibilityIdentifier("db.editor.tls")
            // Verifying the certificate through an SSH tunnel: what each engine checks.
            if draft.tls == "verify" && useSSH && !draft.isRedis {
                Label(L(draft.kind == "postgres" ? "db.tls.verifySSHPostgres" : "db.tls.verifySSHMySQL"), systemImage: Symbols.info)
                    .font(.uiCaption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("db.editor.tlsNote")
            }
        }
    }

    private var sshSection: some View {
        Section {
            Toggle(L("db.edit.useSSH"), isOn: $useSSH).accessibilityIdentifier("db.editor.ssh")
            if useSSH {
                TextField(L("db.sshHost"), text: $sshHost, prompt: Text(L("db.edit.sshHostPlaceholder")))
                    .accessibilityIdentifier("db.editor.sshHost").formField(L("db.sshHost"))
                TextField(L("db.port"), value: $sshPort, format: .number.grouping(.never))
                    .accessibilityIdentifier("db.editor.sshPort").formField(L("db.port"))
                TextField(L("db.sshUser"), text: $sshUser, prompt: Text(L("db.ssh.userPlaceholder")))
                    .accessibilityIdentifier("db.editor.sshUser").formField(L("db.sshUser"))
                LabeledContent(L("db.sshKey")) {
                    HStack(spacing: 8) {
                        Picker(L("db.sshKey"), selection: $identity) {
                            Text(L("db.sshAgent")).tag("")
                            if !keyring.sshKeys.isEmpty {
                                Section(L("keys.stackSection")) {
                                    ForEach(keyring.sshKeys) { key in
                                        Text(key.group.isEmpty ? key.name : "\(key.name) · \(key.group)").tag("stack:\(key.id)")
                                    }
                                }
                            }
                            if !keys.isEmpty {
                                Section(L("keys.homeSection")) {
                                    ForEach(keys, id: \.self) { Text(URL(fileURLWithPath: $0).lastPathComponent).tag($0) }
                                }
                            }
                        }
                        .labelsHidden().fixedSize()
                        .accessibilityIdentifier("db.editor.sshKey")
                        Button { SettingsRouter.shared.open(.keys) } label: { Label(L("settings.manageKeys"), systemImage: Symbols.key) }
                            .accessibilityIdentifier("db.edit.manageKeys")
                    }
                }
                if let key = identity.hasPrefix("stack:") ? keyring.sshKeys.first(where: { "stack:\($0.id)" == identity }) : nil, !key.description.isEmpty {
                    Text(key.description).font(.uiCaption).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text(L("db.ssh"))
        } footer: {
            Text(L("db.sshHelp")).font(.uiCaption).foregroundStyle(.secondary)
        }
    }

    var valid: Bool {
        guard !draft.name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        if draft.kind == "sqlite" { return !(draft.path ?? "").isEmpty }
        if useSSH && (sshHost.isEmpty || sshUser.isEmpty) { return false }
        return !draft.host.isEmpty && draft.port > 0
    }
    static func engineName(_ kind: String) -> String { kind == "sqlite" ? "SQLite" : Tech.of(kind).title }
    var built: DBConnection {
        var c = draft
        if c.id.isEmpty {
            let slug = c.name.lowercased().folding(options: .diacriticInsensitive, locale: nil)
                .map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
                .split(separator: "-").joined(separator: "-")
            c.id = String((slug.isEmpty ? "conexion" : slug).prefix(30)) + "-" + String(UUID().uuidString.prefix(4)).lowercased()
            if c.id.hasPrefix("stack-") { c.id = "c-" + c.id }
        }
        let stackKey = identity.hasPrefix("stack:") ? String(identity.dropFirst(6)) : nil
        c.ssh = useSSH ? DBConnection.SSH(host: sshHost, port: sshPort, user: sshUser,
                                          identity: stackKey == nil && !identity.isEmpty ? identity : nil, key: stackKey) : nil
        if c.kind == "sqlite" { c.host = ""; c.port = 0; c.ssh = nil } else { c.path = nil }
        c.builtin = false
        c.hasPassword = false
        return c
    }
}
