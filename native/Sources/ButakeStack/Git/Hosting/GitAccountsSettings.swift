import AppKit
import SwiftUI

/// Ajustes › Cuentas: the GitHub and Bitbucket Cloud accounts of the Git tool. Each provider says
/// how to create a token with the minimum permissions, takes it, checks it with the provider and
/// only then keeps it in the Keychain. A saved token is never shown again, not even in part.
struct GitAccountsSettings: View {
    var hosting = GitHosting.shared

    var body: some View {
        Form {
            ForEach(GitHostingProvider.allCases) { provider in
                GitAccountSection(hosting: hosting, provider: provider)
            }
            Section {
            } footer: {
                SettingsFooter(L("git.accounts.security"))
            }
        }
        .formStyle(.grouped).themedScroll()
        .task { await hosting.loadAccounts() }
        .accessibilityIdentifier("git.accounts")
    }
}

private struct GitAccountSection: View {
    let hosting: GitHosting
    let provider: GitHostingProvider
    @State private var email = ""
    @State private var token = ""
    @State private var working = false
    @State private var result: (ok: Bool, text: String)?
    @State private var disconnecting = false

    var body: some View {
        let account = hosting.account(for: provider)
        Section {
            if let account {
                LabeledContent {
                    HStack {
                        Button { Task { await test(account) } } label: { Label(L("git.accounts.test"), systemImage: Symbols.checkIdentity) }
                            .disabled(working).accessibilityIdentifier("git.accounts.\(provider.rawValue).test")
                        Button(role: .destructive) { disconnecting = true } label: { Label(L("git.accounts.disconnectEllipsis"), systemImage: Symbols.signOut) }
                            .disabled(working).accessibilityIdentifier("git.accounts.\(provider.rawValue).disconnect")
                    }
                } label: {
                    Label { Text(String(format: L("git.accounts.connectedAs"), account.display)) } icon: { IconTile(symbol: Symbols.gitAccounts, color: TileColor.correct, size: 22) }
                    if !account.email.isEmpty { Text(account.email) }
                }
            } else {
                LabeledContent {
                    Button { NSWorkspace.shared.open(provider.tokenPage) } label: { Label(String(format: L("git.accounts.createToken"), provider.title), systemImage: Symbols.openInBrowser) }
                        .accessibilityIdentifier("git.accounts.\(provider.rawValue).createToken")
                } label: {
                    Text(L("git.accounts.step1"))
                    Text(String(format: L("git.accounts.step1Detail"), provider.title))
                }
                LabeledContent {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(0..<GitHostingProvider.permissionCount, id: \.self) { index in
                            Text(provider.permission(index)).font(.uiCaption).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                } label: {
                    Text(L("git.accounts.step2"))
                    Text(L("git.accounts.step2Detail"))
                }
                if provider.needsEmail {
                    TextField(L("git.accounts.email"), text: $email, prompt: Text(L("git.accounts.emailPrompt")))
                        .textContentType(.emailAddress)
                        .accessibilityIdentifier("git.accounts.\(provider.rawValue).email")
                }
                SecureField(L("git.accounts.step3"), text: $token, prompt: Text(L("git.accounts.tokenPrompt")))
                    .accessibilityIdentifier("git.accounts.\(provider.rawValue).token")
                HStack {
                    Spacer()
                    Button { Task { await connect() } } label: { Label(L("git.accounts.connect"), systemImage: Symbols.connect) }
                        .buttonStyle(.borderedProminent)
                        .disabled(working || token.trimmingCharacters(in: .whitespaces).isEmpty || (provider.needsEmail && !email.contains("@")))
                        .accessibilityIdentifier("git.accounts.\(provider.rawValue).connect")
                }
            }
            if working {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, alignment: .leading)
            } else if let result {
                Label(result.text, systemImage: result.ok ? Symbols.success : Symbols.warning)
                    .foregroundStyle(result.ok ? Brand.success : Brand.danger)
                    .accessibilityIdentifier("git.accounts.\(provider.rawValue).result")
            }
        } header: {
            Text(provider.title)
        }
        .confirmationDialog(String(format: L("git.accounts.disconnectTitle"), provider.title), isPresented: $disconnecting, titleVisibility: .visible) {
            Button(L("git.accounts.disconnect"), role: .destructive) {
                if let account { Task { await hosting.disconnect(account); result = nil } }
            }
            .accessibilityIdentifier("git.accounts.\(provider.rawValue).disconnectConfirm")
            Button(L("common.cancel"), role: .cancel) {}.accessibilityIdentifier("git.accounts.\(provider.rawValue).disconnectCancel")
        } message: {
            Text(String(format: L("git.accounts.disconnectDetail"), provider.title))
        }
    }

    /// The token is kept only once the provider accepts it; the field is emptied right away.
    private func connect() async {
        working = true
        defer { working = false }
        let typed = token
        token = ""
        do {
            let account = try await hosting.connect(provider, email: email, token: typed)
            result = (true, String(format: L("git.accounts.connectedAs"), account.display))
        } catch {
            result = (false, (error as? GitHostingFailure ?? GitHostingFailure(.offline, provider: provider)).errorDescription ?? "")
        }
    }

    private func test(_ account: GitHostingAccount) async {
        working = true
        defer { working = false }
        do {
            let checked = try await hosting.test(account)
            result = (true, String(format: L("git.accounts.testOk"), checked.display))
        } catch {
            result = (false, (error as? GitHostingFailure ?? GitHostingFailure(.offline, provider: provider)).errorDescription ?? "")
        }
    }
}
