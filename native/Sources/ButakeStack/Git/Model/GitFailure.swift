import Foundation

/// An error of the Git tool as the user reads it: a title from its fixed code (`git.error.<code>`)
/// and a detail. The engine's own messages are already in Spanish; Git's output (English) gets a
/// translation for the usual failures and otherwise stays as Git wrote it, the most precise text.
struct GitFailure: Equatable, Identifiable, Sendable {
    let code: String
    let title: String
    let detail: String
    var id: String { code + detail }

    /// The pull failures the assistant guides from (`pull_diverged`, `pull_local_changes`…).
    var needsPullAssistant: Bool { code.hasPrefix("pull_") && code != "pull_remote_unreachable" }
    /// A stop asked by the user: nothing to tell.
    var cancelled: Bool { code == "cancelled" }

    init(code: String, title: String, detail: String) {
        self.code = code; self.title = title; self.detail = detail
    }

    init(_ error: Error) {
        guard let failure = error as? EngineFailure else {
            self.init(code: error is CancellationError ? "cancelled" : "engine", title: L("engine.requestFailed"), detail: "")
            return
        }
        // A code of another part of the engine (`plugin_disabled`) has its text outside `git.error.`.
        let title = localized("git.error.\(failure.code)") ?? localized(failure.messageKey) ?? L("git.error.git_failed")
        // The pull messages carry Git's own output after a marker: keep only the explanation.
        let raw = (failure.detail ?? "").components(separatedBy: "\n\nDetalle de Git:").first ?? ""
        self.init(code: failure.code, title: title, detail: Self.translate(raw))
    }

    /// Git and SSH speak English on stderr: the usual failures in plain Spanish.
    static func translate(_ raw: String) -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let match = known.first(where: { text.localizedCaseInsensitiveContains($0.needle) }) else { return text }
        return L(match.key)
    }

    private static let known: [(needle: String, key: String)] = [
        ("not a git repository", "git.message.notRepository"),
        ("Could not resolve host", "git.message.offline"),
        ("Connection refused", "git.message.offline"),
        ("Could not read from remote repository", "git.message.remoteAccess"),
        ("Permission denied (publickey)", "git.message.sshKey"),
        ("Authentication failed", "git.message.authentication"),
        ("Repository not found", "git.message.remoteNotFound"),
        ("does not appear to be a git repository", "git.message.remoteNotFound"),
        ("would be overwritten by merge", "git.message.localChanges"),
        ("would be overwritten by checkout", "git.message.localChanges"),
        ("Your local changes to the following files would be overwritten", "git.message.localChanges"),
        ("[rejected]", "git.message.rejected"),
        ("non-fast-forward", "git.message.rejected"),
        ("Unable to create '", "git.message.locked"),
        ("index.lock", "git.message.locked"),
        ("Operation timed out", "git.message.timeout"),
        ("Connection timed out", "git.message.timeout"),
        ("No space left on device", "git.message.diskFull"),
        ("gpg failed to sign the data", "git.message.signing"),
        ("Couldn't load public key", "git.message.signing"),
        ("Please tell me who you are", "git.message.identity"),
        ("nothing to commit", "git.message.nothingToCommit"),
        ("no changes added to commit", "git.message.nothingToCommit"),
        ("already exists", "git.message.branchExists"),
    ]
}
