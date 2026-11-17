import AppKit
import SwiftUI

/// A host and its forwards, in a grouped form like the rest of the app's sheets.
struct SSHHostEditor: View {
    @Bindable var terminal: SSHTerminal
    @Bindable var keys: SSHKeyring
    let original: SSHHost
    @State private var host: SSHHost
    @State private var auth: String
    /// A group typed in «Nuevo grupo…» that no saved host has yet.
    @State private var newGroup: String?
    @State private var naming: SSHNameRequest?
    /// One identity per forward, kept in step with `host.forwards`: a new forward has no id yet and
    /// an index is not an identity (removing one would leave the form reading past the end).
    @State private var forwardTokens: [UUID]
    init(terminal: SSHTerminal, keys: SSHKeyring, original: SSHHost) {
        self.terminal = terminal
        self.keys = keys
        self.original = original
        _host = State(initialValue: original)
        _forwardTokens = State(initialValue: original.forwards.map { _ in UUID() })
        _auth = State(initialValue: original.key != nil ? "stack" : original.identity != nil ? "file" : "agent")
    }
    var isNew: Bool { original.id.isEmpty }
    /// Hosts this one may jump through: saved, not itself, without a jump of their own; and
    /// none at all while others jump through this one.
    var jumpChoices: [SSHHost] {
        guard terminal.jumpers(of: original).isEmpty || isNew else { return [] }
        return terminal.hosts.filter { $0.id != original.id && $0.jump == nil }
    }
    /// Existing groups, the one typed for this host and the host's own.
    var groups: [String] {
        Array(Set(terminal.groups + [newGroup, host.group].compactMap { $0 }).filter { !$0.isEmpty })
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
    var valid: Bool {
        !host.name.trimmingCharacters(in: .whitespaces).isEmpty && !host.host.trimmingCharacters(in: .whitespaces).isEmpty
            && !host.user.trimmingCharacters(in: .whitespaces).isEmpty && (1...65535).contains(host.port)
            && (auth != "stack" || host.key != nil) && (auth != "file" || !(host.identity ?? "").isEmpty)
            && host.forwards.allSatisfy { (1024...65535).contains($0.listenPort) && ($0.kind == "dynamic" || (!$0.targetHost.isEmpty && (1...65535).contains($0.targetPort))) }
    }

    var body: some View {
        SheetFrame(title: isNew ? L("ssh.editor.new") : L("ssh.editor.edit"), symbol: Symbols.server, note: L("ssh.editorPrivacy"),
                   width: 620, height: 640, actionTitle: L("common.save"), actionID: "ssh.editor.save", canAct: valid,
                   cancelID: "ssh.editor.cancel", action: save) {
            Form {
                Section {
                    TextField(L("ssh.namePlaceholder"), text: $host.name).formField(L("common.name"))
                        .accessibilityIdentifier("ssh.editor.name")
                    TextField(L("ssh.descriptionPlaceholder"), text: $host.description, axis: .vertical).lineLimit(1...3)
                        .formField(L("ssh.description")).accessibilityIdentifier("ssh.editor.description")
                    Picker(L("ssh.group"), selection: Binding(get: { host.group }, set: { value in
                        if value == Self.newGroupTag {
                            naming = .newGroup { name in newGroup = name; host.group = name }
                        } else {
                            host.group = value
                        }
                    })) {
                        Text(L("ssh.noGroup")).tag("")
                        ForEach(groups, id: \.self) { Text($0).tag($0) }
                        Divider()
                        Text(L("ssh.groups.newEllipsis")).tag(Self.newGroupTag)
                    }
                    .accessibilityIdentifier("ssh.editor.group")
                    LabeledContent(L("ssh.tags")) {
                        SSHTagField(tags: $host.tags, suggestions: terminal.tags, prompt: L("ssh.tagsPrompt"))
                    }
                    .help(L("ssh.tagsHelp"))
                }
                Section {
                    TextField(L("ssh.serverPlaceholder"), text: $host.host).formField(L("ssh.server"))
                        .accessibilityIdentifier("ssh.editor.host")
                    TextField(L("ssh.port"), value: $host.port, format: .number.grouping(.never)).formField(L("ssh.port"))
                        .accessibilityIdentifier("ssh.editor.port")
                    TextField(L("ssh.userPlaceholder"), text: $host.user).formField(L("common.user"))
                        .accessibilityIdentifier("ssh.editor.user")
                } header: {
                    Text(L("ssh.connection"))
                }
                Section {
                    Picker(L("ssh.auth.method"), selection: $auth) {
                        Text(L("ssh.auth.agent")).tag("agent")
                        Text(L("ssh.auth.stackKey")).tag("stack")
                        Text(L("ssh.auth.file")).tag("file")
                    }
                    .accessibilityIdentifier("ssh.editor.auth")
                    if auth == "stack" {
                        Picker(L("ssh.auth.stackKey"), selection: Binding(get: { host.key ?? "" }, set: { host.key = $0.isEmpty ? nil : $0 })) {
                            Text(L("ssh.pickKey")).tag("")
                            ForEach(keys.sshKeys) { key in
                                Text(key.group.isEmpty ? key.name : "\(key.group) › \(key.name)").tag(key.id)
                            }
                        }
                        .accessibilityIdentifier("ssh.editor.key")
                        LabeledContent {
                            Button { SettingsRouter.shared.open(.keys) } label: { Label(L("settings.manageKeys"), systemImage: Symbols.key) }
                                .buttonStyle(.bordered).accessibilityIdentifier("ssh.editor.manageKeys")
                        } label: { EmptyView() }
                    } else if auth == "file" {
                        LabeledContent(L("ssh.auth.file")) {
                            HStack(spacing: 8) {
                                TextField(L("ssh.identityPlaceholder"), text: Binding(get: { host.identity ?? "" }, set: { host.identity = $0.isEmpty ? nil : $0 }))
                                    .labelsHidden().textFieldStyle(.roundedBorder).accessibilityIdentifier("ssh.editor.identity")
                                Button { chooseIdentity() } label: { Label(L("common.choose"), systemImage: Symbols.folder) }
                                    .buttonStyle(.bordered).fixedSize().accessibilityIdentifier("ssh.editor.chooseIdentity")
                            }
                        }
                    }
                    Picker(L("ssh.jump"), selection: Binding(get: { host.jump ?? "" }, set: { host.jump = $0.isEmpty ? nil : $0 })) {
                        Text(L("ssh.jumpNone")).tag("")
                        ForEach(jumpChoices) { choice in Text(verbatim: "\(choice.name) · \(choice.address)").tag(choice.id) }
                    }
                    .disabled(jumpChoices.isEmpty && host.jump == nil).accessibilityIdentifier("ssh.editor.jump")
                } header: {
                    Text(L("ssh.auth"))
                } footer: {
                    SettingsFooter(L("ssh.authHelp.\(auth)") + " " + (jumpChoices.isEmpty && !isNew && !terminal.jumpers(of: original).isEmpty ? L("ssh.jumpHelpUsed") : L("ssh.jumpHelp")))
                }
                ForEach(forwardTokens, id: \.self) { token in
                    if let index = forwardTokens.firstIndex(of: token), host.forwards.indices.contains(index) {
                        SSHForwardEditor(forward: forwardBinding(token), index: index) { removeForward(token) }
                    }
                }
                Section {
                    Button {
                        host.forwards.append(SSHForward(kind: "local", listenPort: 0, targetHost: "127.0.0.1"))
                        forwardTokens.append(UUID())
                    } label: {
                        Label(L("ssh.addForward"), systemImage: Symbols.add)
                    }
                    .buttonStyle(.bordered).accessibilityIdentifier("ssh.editor.addForward")
                } header: {
                    if host.forwards.isEmpty { Text(L("ssh.forwards")) }
                } footer: {
                    if host.forwards.isEmpty { SettingsFooter(L("ssh.noForwardsEditor")) }
                }
            }
            .formStyle(.grouped).themedScroll()
            .frame(minHeight: 420)
        }
        .sheet(item: $naming) { request in SSHNameSheet(request: request, terminal: terminal).themedSheet() }
    }

    private func forwardBinding(_ token: UUID) -> Binding<SSHForward> {
        Binding(get: { forwardTokens.firstIndex(of: token).flatMap { host.forwards.indices.contains($0) ? host.forwards[$0] : nil } ?? SSHForward() },
                set: { if let index = forwardTokens.firstIndex(of: token), host.forwards.indices.contains(index) { host.forwards[index] = $0 } })
    }

    private func removeForward(_ token: UUID) {
        guard let index = forwardTokens.firstIndex(of: token), host.forwards.indices.contains(index) else { return }
        host.forwards.remove(at: index)
        forwardTokens.remove(at: index)
    }

    private static let newGroupTag = "\u{0}new"

    private func save() async -> Bool {
        var value = host
        value.group = SSHHost.cleanGroup(value.group)
        value.tags = SSHHost.cleanTags(value.tags)
        if auth != "stack" { value.key = nil }
        if auth != "file" { value.identity = nil }
        if let identity = value.identity, identity.hasPrefix("~/") {
            value.identity = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(String(identity.dropFirst(2))).path
        }
        return await terminal.save(value)
    }

    private func chooseIdentity() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        panel.message = L("ssh.chooseMessage")
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        if panel.runModal() == .OK, let url = panel.url { host.identity = url.path }
    }
}

/// One forward of the host being edited: its own section of the form.
private struct SSHForwardEditor: View {
    @Binding var forward: SSHForward
    let index: Int
    let remove: () -> Void
    var body: some View {
        Section {
            Picker(L("ssh.forward.kind"), selection: $forward.kind) {
                Text(L("ssh.forward.kind.local")).tag("local")
                Text(L("ssh.forward.kind.remote")).tag("remote")
                Text(L("ssh.forward.kind.dynamic")).tag("dynamic")
            }
            .accessibilityIdentifier("ssh.editor.forward.\(index).kind")
            TextField(L("ssh.forward.namePlaceholder"), text: $forward.name).formField(L("common.name"))
                .accessibilityIdentifier("ssh.editor.forward.\(index).name")
            TextField(L("ssh.forward.portPlaceholder"), value: $forward.listenPort, format: .number.grouping(.never))
                .formField(forward.kind == "remote" ? L("ssh.forward.serverPort") : L("ssh.forward.localPort"))
                .accessibilityIdentifier("ssh.editor.forward.\(index).listen")
            if forward.kind != "dynamic" {
                LabeledContent(L("ssh.forward.target")) {
                    HStack(spacing: 6) {
                        TextField(L("ssh.forward.targetPlaceholder"), text: $forward.targetHost).labelsHidden().textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("ssh.editor.forward.\(index).targetHost")
                        TextField(L("ssh.port"), value: $forward.targetPort, format: .number.grouping(.never)).labelsHidden()
                            .textFieldStyle(.roundedBorder).frame(width: 80)
                            .accessibilityIdentifier("ssh.editor.forward.\(index).targetPort")
                    }
                }
            }
            Toggle(L("ssh.forward.autostartShort"), isOn: $forward.autostart).help(L("ssh.forward.autostart"))
                .accessibilityIdentifier("ssh.editor.forward.\(index).autostart")
            Toggle(L("ssh.forward.keepAliveShort"), isOn: $forward.keepAlive).help(L("ssh.forward.keepAlive"))
                .accessibilityIdentifier("ssh.editor.forward.\(index).keepAlive")
        } header: {
            HStack {
                Text(String(format: L("ssh.forward.number"), index + 1))
                Spacer()
                Button(role: .destructive, action: remove) { Label(L("ssh.forward.remove"), systemImage: Symbols.remove).labelStyle(.iconOnly) }
                    .buttonStyle(.borderless).help(L("ssh.forward.remove")).accessibilityIdentifier("ssh.editor.forward.\(index).remove")
            }
        } footer: {
            if forward.listenPort != 0 && !(1024...65535).contains(forward.listenPort) {
                Text(L("ssh.forward.lowPort")).font(.uiCaption).foregroundStyle(Brand.danger)
            } else {
                SettingsFooter(L("ssh.forward.help.\(forward.kind)"))
            }
        }
    }
}
