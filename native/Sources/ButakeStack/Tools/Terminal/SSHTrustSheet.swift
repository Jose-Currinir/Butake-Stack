import SwiftUI

/// An unknown server: its fingerprints to compare before trusting it, and what follows once
/// trusted (open the session, the files, start a forward). The verification is the terminal's.
struct SSHTrustSheet: View {
    @Bindable var terminal: SSHTerminal
    let request: SSHTerminal.TrustRequest
    var body: some View {
        SheetFrame(title: L("db.ssh.unknownTitle"), symbol: Symbols.hostKey, detail: detail, note: L("ssh.trustHow"), width: 560,
                   actionTitle: trustLabel, actionID: "ssh.trust.confirm", cancelID: "ssh.trust.cancel") {
            await terminal.trust(request)
            return true
        } content: {
            Form {
                Section(L("ssh.trust.fingerprints")) {
                    ForEach(request.fingerprints, id: \.self) { print in
                        Text(print).font(.uiCallout.monospaced()).textSelection(.enabled).lineLimit(2).truncationMode(.middle).help(print)
                    }
                }
            }
            .formStyle(.grouped).themedScroll()
            .frame(minHeight: 140)
        }
    }
    private var detail: String {
        let server = String(format: L("ssh.trustDetail"), request.host.host, request.host.port)
        guard let target = request.target, target.id != request.host.id else { return server }
        return String(format: L("ssh.trustJump"), request.host.name, target.name) + " " + server
    }
    private var trustLabel: String {
        if let target = request.target, target.id != request.host.id { return L("ssh.trustContinue") }
        return switch request.then {
        case .open, .external: L("ssh.trustOpen")
        case .sftp: L("ssh.trustFiles")
        case .forward: L("ssh.trustForward")
        case .none: L("ssh.trustOnly")
        }
    }
}

/// Asks for a key's passphrase (it goes to the engine for ssh-add and, if chosen, to the
/// Keychain; it is never shown again or written anywhere else). Closing the sheet in any way
/// answers the request, so whoever waits for it goes on.
struct PassphraseSheet: View {
    let request: SSHKeyring.PassphraseRequest
    @State private var value = ""
    @State private var remember = true
    @State private var answered = false
    var body: some View {
        SheetFrame(title: L("ssh.keys.passphraseTitle"), symbol: Symbols.key, detail: String(format: L("ssh.keys.passphraseDetail"), request.name),
                   note: L("ssh.keys.passphrasePrivacy"), width: 460, actionTitle: L("ssh.keys.passphraseContinue"),
                   actionID: "ssh.keys.passphraseContinue", canAct: !value.isEmpty, cancelID: "ssh.keys.passphraseCancel") {
            let typed = value
            let keep = remember
            value = ""
            answered = true
            SSHKeyring.shared.prompt = nil
            Task { await request.resume(typed, keep) }
            return true
        } content: {
            Form {
                SecureField(L("ssh.keys.passphrase"), text: $value).formField(L("ssh.keys.passphrase"))
                    .accessibilityIdentifier("ssh.keys.passphraseField")
                Toggle(L("ssh.keys.rememberPassphrase"), isOn: $remember).accessibilityIdentifier("ssh.keys.rememberPassphrase")
                if request.wrong {
                    Label(L("ssh.keys.passphraseWrong"), systemImage: Symbols.error).foregroundStyle(Brand.danger)
                }
            }
            .formStyle(.grouped).themedScroll()
            .frame(minHeight: 110)
        }
        .onDisappear {
            guard !answered else { return }
            answered = true
            SSHKeyring.shared.prompt = nil
            Task { await request.resume(nil, false) }
        }
    }
}
