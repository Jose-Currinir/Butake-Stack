#if DEBUG
import Foundation

/// Screenshots of the AWS tool (debug builds with BUTAKE_QA_WINDOW and a separate
/// BUTAKE_STACK_HOME). The profiles are made-up files the capture script names with
/// AWS_CONFIG_FILE and AWS_SHARED_CREDENTIALS_FILE, and «Comprobar» runs a fake `aws` of the
/// temporary home: nothing reaches the owner's `~/.aws` nor AWS.
///
///     BUTAKE_QA_AWS=<perfil>          the selected profile
///     BUTAKE_QA_AWS_CHECK=1           «Comprobar» on it
///     BUTAKE_QA_AWS_SIGN_IN=1         «Iniciar sesión…» on it (the fake decides how it ends)
///     BUTAKE_QA_AWS_SHEET=<hoja>      new, new-sso, new-role, new-keychain, edit, duplicate, default,
///                                     delete, signout or repair
extension QAHooks {
    private static func awsValue(_ name: String) -> String? {
        let env = ProcessInfo.processInfo.environment
        return StackStore.qaWindow && env["BUTAKE_STACK_HOME"] != nil ? env[name] : nil
    }

    /// The kind the new-profile sheet opens with.
    static var awsSheetKind: AWSProfile.Kind? {
        switch awsValue("BUTAKE_QA_AWS_SHEET") {
        case "new-sso": .sso
        case "new-role": .role
        case "new", "new-keychain": .static
        default: nil
        }
    }
    static var awsSheetKeychain: Bool { awsValue("BUTAKE_QA_AWS_SHEET") == "new-keychain" }

    static func aws(_ tool: AWSTool) async {
        if let name = awsValue("BUTAKE_QA_AWS") { tool.selection = name }
        if awsValue("BUTAKE_QA_AWS_CHECK") == "1", let profile = tool.selected { tool.startCheck(profile) }
        // «Iniciar sesión…» against the fake `aws` of the temporary home (one that waits, or ends).
        if awsValue("BUTAKE_QA_AWS_SIGN_IN") == "1", let profile = tool.selected { tool.startSignIn(profile) }
        guard let sheet = awsValue("BUTAKE_QA_AWS_SHEET") else { return }
        let profile = tool.selected
        switch sheet {
        case "new", "new-sso", "new-role", "new-keychain": tool.sheet = .new
        case "edit": tool.sheet = profile.map { .edit($0) }
        case "duplicate": tool.sheet = profile.map { .duplicate($0) }
        case "default": tool.sheet = profile.map { .makeDefault($0) }
        case "delete": tool.deleting = profile
        case "signout": tool.signingOut = true
        case "repair": tool.repairing = profile
        default: break
        }
    }
}
#endif
