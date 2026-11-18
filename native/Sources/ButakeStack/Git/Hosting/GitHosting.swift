import AppKit
import SwiftUI

/// The Git tool's link with GitHub and Bitbucket Cloud: the connected accounts, the API client,
/// the sheets to clone, create and publish a repository, and the pull requests of each open
/// repository (`session(for:)`). The app uses `shared` (the real providers and the Keychain);
/// tests make their own with a fake server and a store in memory, and a QA window gets one too
/// (`GitHostingQA`).
@MainActor @Observable final class GitHosting {
    static let shared: GitHosting = {
        #if DEBUG
        // A QA window with BUTAKE_QA_GIT_HOSTING talks to a fake server with a store in memory.
        if let fake = GitHostingQA.hosting() { return fake }
        #endif
        return GitHosting(endpoints: .production, vault: GitHostingVault(items: KeychainItemStore(service: GitHostingVault.service)))
    }()

    let endpoints: GitHostingEndpoints
    @ObservationIgnored let vault: GitHostingVault
    @ObservationIgnored let client: GitHostingClient

    /// The connected accounts (from the Keychain's attributes: no token is read for this).
    private(set) var accounts: [GitHostingAccount] = []
    private(set) var accountsLoaded = false

    /// The sheets of the tool: clone, create a repository here, publish the open one.
    var cloning = false
    var creating = false
    var publishing = false

    @ObservationIgnored private var sessions: [String: GitHostingSession] = [:]

    /// A provider page was opened in the browser: back in Stack, the open repository is brought up
    /// to date once (a pull request merged there with its branch deleted stops being listed).
    @ObservationIgnored var awaitingReturn = false
    @ObservationIgnored private var activation: NSObjectProtocol?

    init(endpoints: GitHostingEndpoints, vault: GitHostingVault) {
        self.endpoints = endpoints
        self.vault = vault
        client = GitHostingClient(endpoints: endpoints)
        activation = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.returnedFromBrowser() }
        }
    }

    /// Stack is in front again after a page of the provider: «Actualizar» (it prunes the branches
    /// deleted there) and the pull requests read again. Once per page opened, never on its own.
    func returnedFromBrowser(in repository: GitRepository? = GitTool.shared.repository) async {
        guard awaitingReturn else { return }
        awaitingReturn = false
        guard let repository, repository.operation == nil else { return }
        // `origin` as configured (the snapshot's address has Git's rewrites applied).
        let session = session(for: repository)
        await session.readRemote()
        guard session.hosted != nil else { return }
        await repository.perform(.fetch, notify: false)
        await session.load()
    }

    // MARK: Accounts

    /// Reads which accounts exist, off the main thread (the Keychain call may wait).
    func loadAccounts() async {
        let vault = self.vault
        let found = await Task.detached(priority: .userInitiated) { vault.accounts() }.value
        if found != accounts { accounts = found }
        accountsLoaded = true
    }

    func account(for provider: GitHostingProvider) -> GitHostingAccount? { accounts.first { $0.provider == provider } }
    var connectedProviders: [GitHostingProvider] { GitHostingProvider.allCases.filter { account(for: $0) != nil } }

    /// «Probar y guardar»: the token is saved only after the provider accepts it. Returns the account.
    func connect(_ provider: GitHostingProvider, email: String, token: String) async throws -> GitHostingAccount {
        let credentials = GitHostingCredentials(email: email.trimmingCharacters(in: .whitespacesAndNewlines),
                                                token: token.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !credentials.token.isEmpty, !provider.needsEmail || credentials.email.contains("@") else { throw GitHostingFailure(.invalid, provider: provider) }
        let account = try await client.verify(provider, credentials: credentials)
        let vault = self.vault
        try await Task.detached { try vault.save(account, credentials: credentials) }.value
        await loadAccounts()
        return account
    }

    /// «Probar conexión» of a saved account.
    func test(_ account: GitHostingAccount) async throws -> GitHostingAccount {
        try await client.verify(account.provider, credentials: try await credentials(for: account))
    }

    /// «Desconectar…», confirmed: the Keychain item goes away.
    func disconnect(_ account: GitHostingAccount) async {
        let vault = self.vault
        await Task.detached { vault.remove(account) }.value
        await loadAccounts()
    }

    /// The token of an account, read from the Keychain off the main thread the first time.
    func credentials(for account: GitHostingAccount) async throws -> GitHostingCredentials {
        let vault = self.vault
        return try await Task.detached(priority: .userInitiated) { try vault.credentials(for: account) }.value
    }

    /// The account and its token for a provider, or `noAccount`.
    func credentials(for provider: GitHostingProvider) async throws -> GitHostingCredentials {
        if !accountsLoaded { await loadAccounts() }
        guard let account = account(for: provider) else { throw GitHostingFailure(.noAccount, provider: provider) }
        return try await credentials(for: account)
    }

    // MARK: Repositories

    /// The provider and `owner/name` of a remote address, when it is GitHub's or Bitbucket's.
    func hosted(_ remote: String) -> GitHostedRepository? { GitHostedRepository(remote: remote, endpoints: endpoints) }

    /// The pull requests and checks of an open repository, kept while the tool is open.
    func session(for repository: GitRepository) -> GitHostingSession {
        if let session = sessions[repository.root], session.repository === repository { return session }
        let session = GitHostingSession(repository: repository, hosting: self)
        sessions[repository.root] = session
        return session
    }

    /// Forgets the session of a repository that was closed: it keeps the repository alive otherwise.
    func release(_ repository: GitRepository) {
        if sessions[repository.root]?.repository === repository { sessions[repository.root] = nil }
    }

    /// Opens a page of the provider in the browser.
    func open(_ url: URL?) {
        guard let url, url.scheme == "https" else { return }
        awaitingReturn = true
        NSWorkspace.shared.open(url)
    }
}
