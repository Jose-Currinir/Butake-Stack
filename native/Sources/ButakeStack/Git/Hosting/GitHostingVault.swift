import Foundation

/// Where the tokens of the accounts live: the Keychain only, one item per account (P-32), this
/// device only, never synchronized. Account `<provider>/<login>`; data: the token; attributes: the
/// account (`GitHostingAccount` as JSON, no secret), so the accounts are listed without reading a
/// token and without asking macOS for anything. A token is read the first time a request needs
/// it, then kept in memory for the session.
///
/// Never on disk, in a log, in the engine (it does not see them: the app calls the provider's API
/// itself), in a process's arguments or on screen. Tests and QA windows use a store in memory.
final class GitHostingVault: @unchecked Sendable {
    let items: KeychainItems
    private let lock = NSLock()
    private var tokens: [String: String] = [:]

    /// A QA store (BUTAKE_STACK_HOME) keeps its items apart from the real ones.
    static let service = "cl.butake.stack.git.accounts" + (ProcessInfo.processInfo.environment["BUTAKE_STACK_HOME"] == nil ? "" : ".qa")

    init(items: KeychainItems) { self.items = items }

    /// The accounts, from the items' attributes: no token is read.
    func accounts() -> [GitHostingAccount] {
        items.list(prefix: "").compactMap { entry in
            entry.attributes.flatMap { try? JSONDecoder().decode(GitHostingAccount.self, from: $0) }.flatMap { $0.id == entry.account ? $0 : nil }
        }
        .sorted { ($0.provider.rawValue, $0.login) < ($1.provider.rawValue, $1.login) }
    }

    /// Saves the account with its token (read back before returning) and removes any other
    /// account of the same provider: one account per provider.
    func save(_ account: GitHostingAccount, credentials: GitHostingCredentials) throws {
        guard let attributes = try? JSONEncoder().encode(account) else { throw GitHostingFailure(.keychain, provider: account.provider) }
        let data = Data(credentials.token.utf8)
        guard items.write(data, account: account.id, label: "Stack · Git · \(account.provider.title) · \(account.login)", attributes: attributes),
              case .found(let back) = items.read(account.id), back == data else {
            throw GitHostingFailure(.keychain, provider: account.provider)
        }
        lock.withLock { tokens[account.id] = credentials.token }
        for other in accounts() where other.provider == account.provider && other.id != account.id { remove(other) }
    }

    /// The account's token and email: from memory, or read once from its item.
    func credentials(for account: GitHostingAccount) throws -> GitHostingCredentials {
        if let token = lock.withLock({ tokens[account.id] }) { return GitHostingCredentials(email: account.email, token: token) }
        switch items.read(account.id) {
        case .found(let data):
            let token = String(decoding: data, as: UTF8.self)
            guard !token.isEmpty else { throw GitHostingFailure(.keychain, provider: account.provider) }
            lock.withLock { tokens[account.id] = token }
            return GitHostingCredentials(email: account.email, token: token)
        case .missing: throw GitHostingFailure(.noAccount, provider: account.provider)
        case .failed: throw GitHostingFailure(.keychain, provider: account.provider)
        }
    }

    /// «Desconectar»: the item and the token in memory.
    func remove(_ account: GitHostingAccount) {
        lock.withLock { tokens[account.id] = nil }
        items.remove(account.id, quietly: false)
    }
}
