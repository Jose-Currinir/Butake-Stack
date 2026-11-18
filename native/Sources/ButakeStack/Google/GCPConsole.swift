import AppKit
import Foundation

/// What the tool opens outside itself: «Iniciar sesión…» in a console of the Terminal, and the
/// pages of Google's consoles in the browser. Neither changes gcloud's configuration.
@MainActor enum GCPConsole {
    /// gcloud's sign-in: `auth login --no-activate` (with the account, when renewing one). The
    /// browser and the password are the user's; the new account is not made gcloud's active one.
    /// gcloud runs by itself (no shell), first on PATH its own folder; the console's environment
    /// carries no account or project, and the configuration folder only when the app was given
    /// one (QA).
    static func signInLaunch(gcloud: String, account: String?, inherited: [String: String] = ProcessInfo.processInfo.environment) -> LocalLaunch {
        let folder = (gcloud as NSString).deletingLastPathComponent
        var environment = LocalConsoles.environment(shell: LocalConsoles.loginShell(), project: ["PATH": folder])
        if let config = inherited["CLOUDSDK_CONFIG"], config.hasPrefix("/") { environment.append("CLOUDSDK_CONFIG=\(config)") }
        return LocalLaunch(program: "gcloud", executable: gcloud, arguments: ["auth", "login", "--no-activate"] + (account.map { [$0] } ?? []),
                           directory: NSHomeDirectory(), environment: environment)
    }

    /// Opens the sign-in in a tab of the Terminal; with the Terminal off, Ajustes › Herramientas on
    /// its row.
    static func signIn(account: String? = nil) {
        let store = StackStore.shared
        guard let gcloud = GCPTool.shared.cliPath else { return }
        guard store.pluginEnabled("ssh-terminal") else { store.openTool("ssh-terminal"); return }
        store.route = .tool("ssh-terminal")
        SSHWorkspace.shared.openLocal(signInLaunch(gcloud: gcloud, account: account))
    }

    static func open(_ page: GCPConsolePage, project: String, account: String?) {
        if let url = page.url(project: project, account: account) { NSWorkspace.shared.open(url) }
    }
}
