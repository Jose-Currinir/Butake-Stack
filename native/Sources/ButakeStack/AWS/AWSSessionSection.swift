import SwiftUI

/// What the «Sesión única» row offers, from the session AWS CLI keeps and what is running.
enum AWSSessionMode: Equatable {
    /// Waiting for the browser: a clear text and «Cancelar».
    case waiting
    /// «Cerrar sesión» running for every session of the Mac.
    case endingSessions
    /// A valid session: «Renovar sesión…» as a secondary action.
    case renew
    /// No session or an expired one: «Iniciar sesión…» is the row's main action.
    case signIn

    static func of(_ session: AWSProfile.Session?, waiting: Bool, endingSessions: Bool) -> AWSSessionMode {
        if waiting { return .waiting }
        if endingSessions { return .endingSessions }
        return session?.valid == true ? .renew : .signIn
    }
}

/// The single sign-on session of a profile: how long it lasts, and signing in, renewing, waiting
/// for the browser (cancellable) or signing out.
struct AWSSessionSection: View {
    @Bindable var tool: AWSTool
    let profile: AWSProfile

    private var mode: AWSSessionMode {
        .of(profile.session, waiting: tool.signingIn.contains(profile.name), endingSessions: tool.endingSessions)
    }

    var body: some View {
        Section(L("aws.session")) {
            switch mode {
            case .waiting: waiting
            case .endingSessions: endingSessions
            case .renew, .signIn: status
            }
            if let error = tool.signInErrors[profile.name], mode != .waiting {
                Notice(.warning, error).accessibilityIdentifier("aws.session.error")
            }
        }
    }

    private var waiting: some View {
        LabeledContent {
            Button(role: .cancel) { tool.cancelSignIn(profile.name) } label: { Label(L("common.cancel"), systemImage: Symbols.close) }
                .buttonStyle(.bordered).help(L("aws.session.cancelHelp")).accessibilityIdentifier("aws.session.cancel")
        } label: {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("aws.session.waiting")).accessibilityIdentifier("aws.session.waiting")
                    if let start = tool.signInStarted[profile.name] {
                        Text(String(format: L("aws.session.waitingLimit"), start.addingTimeInterval(tool.signInLimit).formatted(date: .omitted, time: .shortened)))
                            .font(.uiCaption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var endingSessions: some View {
        LabeledContent {
            AWSLateCancelButton(id: "aws.session.cancelSignOut") { tool.cancelSignOut() }
        } label: {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(L("aws.signingOut"))
            }
        }
    }

    private var status: some View {
        LabeledContent {
            HStack(spacing: 8) {
                if mode == .renew {
                    Button { tool.startSignIn(profile) } label: { Label(L("aws.session.renewEllipsis"), systemImage: Symbols.reload) }
                        .buttonStyle(.bordered).disabled(!tool.cliInstalled)
                        .help(L("aws.signInHelp")).accessibilityIdentifier("aws.session.renew")
                } else {
                    Button { tool.startSignIn(profile) } label: { Label(L("aws.signInEllipsis"), systemImage: Symbols.signIn) }
                        .buttonStyle(.borderedProminent).disabled(!tool.cliInstalled)
                        .help(L("aws.signInHelp")).accessibilityIdentifier("aws.session.signIn")
                }
                Button { tool.signingOut = true } label: { Label(L("aws.signOutEllipsis"), systemImage: Symbols.signOut) }
                    .buttonStyle(.bordered).disabled(!tool.cliInstalled || profile.session == nil)
                    .accessibilityIdentifier("aws.session.signOut")
            }
        } label: {
            if let session = profile.session {
                Label(sessionText(session), systemImage: session.valid ? Symbols.success : Symbols.warning)
                    .foregroundStyle(session.valid ? Brand.success : Brand.warning)
                    .accessibilityIdentifier("aws.session.status")
            } else {
                Text(L("aws.session.none")).foregroundStyle(.secondary).accessibilityIdentifier("aws.session.status")
            }
        }
    }

    private func sessionText(_ session: AWSProfile.Session) -> String {
        guard let expiry = session.expiry else { return L(session.valid ? "aws.session.valid" : "aws.session.expired") }
        return String(format: L(session.valid ? "aws.session.until" : "aws.session.expiredAt"), Format.shortDateTime(expiry))
    }
}

/// «Cancelar» for a wait that is usually short: it shows only once the wait passes two seconds.
struct AWSLateCancelButton: View {
    let id: String
    let action: () -> Void
    @State private var shown = false

    var body: some View {
        Group {
            if shown {
                Button(role: .cancel, action: action) { Label(L("common.cancel"), systemImage: Symbols.close) }
                    .buttonStyle(.bordered).accessibilityIdentifier(id)
            }
        }
        .task {
            try? await Task.sleep(for: .seconds(2))
            shown = true
        }
    }
}
