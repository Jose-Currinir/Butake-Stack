import AppKit
import Security

/// Once, on the first launch of a build with a stable signature (a team identity, not ad hoc): macOS
/// asks one last time for each Keychain item an earlier build saved, and «Permitir siempre» is then
/// kept across updates. Shown only when there is something saved; a QA store never shows it.
@MainActor enum KeychainNotice {
    private static let seen = "keychain.stableSignature.noticeSeen"
    /// Every Keychain service of Stack (the app's and the engine's AWS keys).
    private static let services = ["cl.butake.stack.env", "cl.butake.stack.db", "cl.butake.stack.ssh-key", "cl.butake.stack.vault", "cl.butake.stack.aws"]

    static func showIfNeeded() {
        guard ProcessInfo.processInfo.environment["BUTAKE_STACK_HOME"] == nil, !UserDefaults.standard.bool(forKey: seen), stableSignature else { return }
        UserDefaults.standard.set(true, forKey: seen)
        guard services.contains(where: hasItems) else { return }
        let alert = NSAlert()
        alert.messageText = L("keychain.notice.title")
        alert.informativeText = L("keychain.notice.detail")
        alert.addButton(withTitle: L("keychain.notice.ok"))
        NSApp.activate()
        alert.runModal()
    }

    /// Signed with a team identity, so macOS recognizes the next build as the same app.
    static var stableSignature: Bool {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let info = info as? [String: Any] else { return false }
        return info[kSecCodeInfoTeamIdentifier as String] is String
    }

    /// Attributes only: asking whether an item exists never prompts.
    private static func hasItems(_ service: String) -> Bool {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }
}
