import AppKit
import SwiftUI

/// The host's card: the detail of the selected host while none of its sessions is shown, and the
/// inspector beside a session. Where it is, how it is organized, how it signs in, whether its
/// server's key is known, and its port forwards (the only place they start and stop).
struct SSHHostCard: View {
    @Bindable var terminal: SSHTerminal
    @Bindable var keyring: SSHKeyring
    let host: SSHHost

    var body: some View {
        Form {
            Section {
                header
                if !host.description.isEmpty {
                    Text(host.description).foregroundStyle(.secondary)
                }
            }
            Section(L("ssh.connection")) {
                InfoRow(title: L("ssh.server"), value: host.host, mono: true, lines: 2)
                InfoRow(title: L("ssh.port"), value: String(host.port))
                InfoRow(title: L("common.user"), value: host.user, mono: true)
                InfoRow(title: L("ssh.jump"), value: host.jump.flatMap { terminal.host($0) }.map { "\($0.name) · \($0.address)" } ?? L("ssh.jumpNone"), lines: 2)
            }
            Section(L("ssh.organization")) {
                InfoRow(title: L("ssh.group"), value: host.group.isEmpty ? L("ssh.noGroup") : host.group)
                LabeledContent(L("ssh.tags")) {
                    if host.tags.isEmpty { Text(L("ssh.noTags")).foregroundStyle(.secondary) } else { FlowTags(tags: host.tags) }
                }
            }
            Section {
                authentication
                LabeledContent {
                    Button { SettingsRouter.shared.open(.keys) } label: { Label(L("settings.manageKeys"), systemImage: Symbols.key) }
                        .buttonStyle(.bordered).accessibilityIdentifier("ssh.card.manageKeys")
                } label: { EmptyView() }
            } header: {
                Text(L("ssh.auth"))
            } footer: {
                SettingsFooter(host.key != nil ? L("ssh.authFooter") : host.identity != nil ? L("ssh.authFooterFile") : L("ssh.authFooterAgent"))
            }
            Section(L("ssh.fingerprint")) {
                SSHFingerprintRows(terminal: terminal, host: host)
            }
            Section {
                ForEach(host.forwards) { forward in SSHForwardRow(terminal: terminal, host: host, forward: forward) }
                LabeledContent {
                    HStack(spacing: 8) {
                        if host.forwards.contains(where: \.autostart) {
                            Button { Task { await terminal.startAll(host) } } label: { Label(L("ssh.startAll"), systemImage: Symbols.active) }
                                .buttonStyle(.bordered).accessibilityIdentifier("ssh.card.startAll")
                        }
                        Button { terminal.editing = host } label: { Label(L("ssh.addForwardEllipsis"), systemImage: Symbols.add) }
                            .buttonStyle(.bordered).accessibilityIdentifier("ssh.card.addForward")
                    }
                } label: {
                    if host.forwards.isEmpty { Text(L("ssh.noForwards")).foregroundStyle(.secondary) }
                }
            } header: {
                Text(L("ssh.forwards"))
            } footer: {
                SettingsFooter(L("ssh.forwardsFooter"))
            }
        }
        .formStyle(.grouped).themedScroll()
        .accessibilityIdentifier("ssh.card")
        // The server's key is compared once when the host is shown (a scan, never a login).
        .task(id: host.id) { if terminal.hostStates[host.id] == nil { await terminal.check(host, quiet: true) } }
    }

    private var header: some View {
        HStack(spacing: 12) {
            IconTile(symbol: Symbols.server, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(host.name).font(.uiTitle3.weight(.semibold)).lineLimit(2)
                    .accessibilityIdentifier("ssh.card.name")
                Text(host.address).font(.uiCallout.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    .lineLimit(1).truncationMode(.middle).help(host.address)
            }
            Spacer(minLength: 8)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(host.address, forType: .string)
                StackStore.shared.notify(L("ssh.addressCopied"))
            } label: { Label(L("ssh.copyAddress"), systemImage: Symbols.copy).labelStyle(.iconOnly) }
                .buttonStyle(.borderless).help(L("ssh.copyAddress")).accessibilityIdentifier("ssh.card.copyAddress")
        }
    }

    @ViewBuilder private var authentication: some View {
        if let id = host.key {
            let key = keyring.sshKeys.first { $0.id == id }
            InfoRow(title: L("ssh.auth.stackKey"), value: key?.name ?? id, lines: 2)
            if let key {
                InfoRow(title: L("ssh.auth.fingerprint"), value: "\(key.kind) · \(key.fingerprint)", mono: true, lines: 2)
                if keyring.encrypted(id) {
                    LabeledContent(L("ssh.keys.agent")) {
                        if keyring.loaded(id) {
                            Label(L("ssh.keys.inAgent"), systemImage: Symbols.success).foregroundStyle(Brand.successText)
                        } else {
                            Button { Task { _ = await keyring.ensureAgent(id) } } label: { Label(L("ssh.keys.loadAgent"), systemImage: Symbols.key) }
                                .buttonStyle(.bordered).accessibilityIdentifier("ssh.card.loadAgent")
                        }
                    }
                }
            } else {
                Label(L("error.unknown_ssh_key"), systemImage: Symbols.error).foregroundStyle(Brand.dangerText)
            }
        } else if let identity = host.identity {
            InfoRow(title: L("ssh.auth.file"), value: identity, mono: true, lines: 2)
        } else {
            InfoRow(title: L("ssh.auth.method"), value: L("ssh.auth.agent"))
        }
    }
}

/// A host's tags as chips, wrapping onto more lines when they don't fit.
private struct FlowTags: View {
    let tags: [String]
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 4) { chips }
            VStack(alignment: .trailing, spacing: 4) { chips }
        }
    }
    private var chips: some View {
        ForEach(tags, id: \.self) { Chip(text: $0, symbol: Symbols.tags) }
    }
}

/// Whether the server's key is known: its state, its fingerprints and the action that follows
/// (compare an unknown one before trusting it, or check again). The verification itself is the
/// terminal's (`SSHTerminal.check` and `trust`).
struct SSHFingerprintRows: View {
    @Bindable var terminal: SSHTerminal
    let host: SSHHost
    var body: some View {
        let state = terminal.hostStates[host.id]
        let owner = state?.host.flatMap { $0 == host.id ? nil : terminal.host($0) }
        LabeledContent {
            if terminal.checking.contains(host.id) {
                ProgressView().controlSize(.small)
            } else if state?.state == "unknown" {
                Button {
                    terminal.trustRequest = .init(host: owner ?? host, fingerprints: state?.fingerprints ?? [], then: .none, target: host)
                } label: { Label(L("ssh.compare"), systemImage: Symbols.hostKey) }
                    .buttonStyle(.bordered).accessibilityIdentifier("ssh.card.compare")
            } else {
                Button { Task { await terminal.check(host) } } label: { Label(L("ssh.check"), systemImage: Symbols.reload) }
                    .buttonStyle(.bordered).accessibilityIdentifier("ssh.card.check")
            }
        } label: {
            Label {
                Text(L("ssh.hostState.\(state?.state ?? "unchecked")"))
            } icon: {
                Image(systemName: Self.symbol(state?.state)).foregroundStyle(Self.color(state?.state))
            }
            .accessibilityIdentifier("ssh.card.hostState")
        }
        if let owner {
            Text(String(format: L("ssh.hostState.jumpFirst"), owner.name)).font(.uiCaption).foregroundStyle(Brand.warningText)
        }
        Text(L("ssh.hostState.\(state?.state ?? "unchecked").detail")).font(.uiCaption)
            .foregroundStyle(state?.state == "unreachable" || state?.state == "changed" ? Self.color(state?.state) : .secondary)
        ForEach(state?.fingerprints ?? [], id: \.self) { print in
            Text(print).font(.uiCaption.monospaced()).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle).textSelection(.enabled).help(print)
        }
    }

    static func symbol(_ state: String?) -> String {
        switch state {
        case "known": Symbols.success
        case "unknown", "changed": Symbols.hostKey
        case "unreachable": Symbols.warning
        default: Symbols.info
        }
    }
    static func color(_ state: String?) -> Color {
        switch state {
        case "known": Brand.success
        case "unknown", "unreachable": Brand.warning
        case "changed": Brand.danger
        default: .secondary
        }
    }
}

/// A forward: its name, kind and route, whether it runs (or dropped and when it tries again) and
/// its switch, which starts or stops it.
private struct SSHForwardRow: View {
    @Bindable var terminal: SSHTerminal
    let host: SSHHost
    let forward: SSHForward
    var body: some View {
        let since = terminal.since(host, forward)
        let dropped = since == nil ? terminal.dropped(host, forward) : nil
        let busy = terminal.busyForwards.contains("\(host.id)/\(forward.id)")
        let on = since != nil || dropped?.keepAlive == true
        LabeledContent {
            if busy {
                ProgressView().controlSize(.small)
            } else {
                Toggle(on ? L("ssh.forward.stop") : L("ssh.forward.start"), isOn: Binding(get: { on }, set: { start in
                    Task { if start { await terminal.start(host, forward) } else { await terminal.stop(host, forward) } }
                }))
                .labelsHidden().toggleStyle(.switch)
                .help(on ? L("ssh.forward.stop") : L("ssh.forward.start"))
                .accessibilityIdentifier("ssh.card.forward.toggle.\(forward.id)")
            }
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(forward.title).lineLimit(1).truncationMode(.tail)
                        Text(L("ssh.forward.kind.\(forward.kind)")).font(.uiCaption).foregroundStyle(.secondary)
                        if forward.autostart {
                            Image(systemName: Symbols.active).font(.uiCaption).foregroundStyle(.secondary).help(L("ssh.forward.autostart"))
                                .accessibilityLabel(L("ssh.forward.autostart"))
                        }
                        if forward.keepAlive {
                            Image(systemName: Symbols.keepAlive).font(.uiCaption).foregroundStyle(.secondary).help(L("ssh.forward.keepAlive"))
                                .accessibilityLabel(L("ssh.forward.keepAlive"))
                        }
                    }
                    Text(forward.route).font(.uiCaption.monospaced()).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    if let since {
                        Text(String(format: L("ssh.forward.since"), since.formatted(date: .omitted, time: .shortened)))
                            .font(.uiCaption).foregroundStyle(Brand.successText)
                    } else if let dropped {
                        Text(droppedText(dropped)).font(.uiCaption).foregroundStyle(Brand.warningText)
                    }
                }
            } icon: {
                IconTile(symbol: Symbols.forwards, color: since != nil ? TileColor.correct : dropped != nil ? TileColor.warning : TileColor.network, size: 22)
            }
        }
        .accessibilityIdentifier("ssh.card.forward.\(forward.id)")
    }
    func droppedText(_ down: SSHOverview.Down) -> String {
        guard down.keepAlive else { return L("ssh.forward.dropped") }
        let next = Date(timeIntervalSince1970: TimeInterval(down.retryAt))
        let reason = localized("error.\(down.error)").map { " · " + $0 } ?? ""
        return down.retryAt == 0 ? L("ssh.forward.restarting") : String(format: L("ssh.forward.retrying"), next.formatted(date: .omitted, time: .shortened)) + reason
    }
}
