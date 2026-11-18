import SwiftUI

/// «Configurar identidad…»: the name and email every commit carries, for this repository or for
/// all of them on this Mac.
struct GitIdentitySheet: View {
    let repository: GitRepository
    @State private var name = ""
    @State private var email = ""
    @State private var everywhere = true
    @FocusState private var focused: Bool

    private var valid: Bool {
        let mail = email.trimmingCharacters(in: .whitespaces)
        let parts = mail.split(separator: "@", omittingEmptySubsequences: false)
        return !name.trimmingCharacters(in: .whitespaces).isEmpty && parts.count == 2 && !parts[0].isEmpty && !parts[1].isEmpty
            && mail.rangeOfCharacter(from: .whitespaces) == nil
    }

    var body: some View {
        SheetFrame(title: L("git.identity.title"), symbol: Symbols.user, detail: L("git.identity.detail"),
                   note: !email.isEmpty && !valid ? L("git.identity.invalid") : nil, width: 460,
                   actionTitle: L("common.save"), actionID: "git.identity.save", canAct: valid && !repository.busy,
                   cancelID: "git.identity.cancel") {
            let value = name.trimmingCharacters(in: .whitespaces) + "\n" + email.trimmingCharacters(in: .whitespaces)
            let done = await repository.perform(everywhere ? .setGlobalIdentity : .setIdentity, value: value)
            if done { repository.checks.reload() }
            return done
        } content: {
            Form {
                TextField(L("git.identity.name"), text: $name).focused($focused)
                    .accessibilityIdentifier("git.identity.name")
                TextField(L("git.identity.email"), text: $email)
                    .accessibilityIdentifier("git.identity.email")
                Picker(L("git.identity.scope"), selection: $everywhere) {
                    Text(L("git.identity.everywhere")).tag(true)
                    Text(String(format: L("git.identity.here"), repository.snapshot.name)).tag(false)
                }
                .pickerStyle(.radioGroup)
                .accessibilityIdentifier("git.identity.scope")
            }
            .formStyle(.grouped).scrollDisabled(true)
        }
        .onAppear { focused = true }
    }
}
