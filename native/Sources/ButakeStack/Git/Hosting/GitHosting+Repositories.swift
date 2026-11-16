import Foundation

/// Cloning and publishing, apart from their sheets so tests run them as the buttons do. Git does
/// the transfer through the engine. Over SSH it uses the Mac's keys; over HTTPS with a connected
/// provider, the account's token goes with that one request (`transferCredentials`).
extension GitHosting {
    /// The user name Git gives with a token: Bitbucket Cloud's fixed one for API tokens, the
    /// account's on GitHub (where any name goes with the token).
    static func gitUser(_ account: GitHostingAccount) -> String {
        account.provider == .bitbucket ? "x-bitbucket-api-token-auth" : account.login
    }

    /// What the engine needs to answer Git when `remote` is an HTTPS address of a connected
    /// provider: the provider's own origin, the user name and the token. Nil for SSH, for any
    /// other server and without an account: Git then works with what the Mac has. The engine
    /// keeps it in memory for that one command and answers only that origin (R19).
    func transferCredentials(for remote: String) async -> [String: String]? {
        guard remote.lowercased().hasPrefix("https://"), let hosted = hosted(remote) else { return nil }
        if !accountsLoaded { await loadAccounts() }
        guard let account = account(for: hosted.provider), let credentials = try? await credentials(for: account) else { return nil }
        return ["origin": "https://\(endpoints.webHost(hosted.provider))", "username": Self.gitUser(account), "password": credentials.token]
    }

    /// `request` with the credentials for `remote`, when it has them.
    func transfer(_ request: [String: Any], remote: String) async -> [String: Any] {
        guard let credentials = await transferCredentials(for: remote) else { return request }
        return request.merging(["credentials": credentials]) { _, new in new }
    }

    /// The same for a repository known only by its folder (the menu bar, a project of several
    /// parts): its remote is read first, and only when an account is connected.
    func transfer(_ request: [String: Any], path: String, store: StackStore) async -> [String: Any] {
        if !accountsLoaded { await loadAccounts() }
        guard !accounts.isEmpty, let snapshot: GitSnapshot = try? await store.call(["method": "gitSnapshot", "path": path, "limit": 1]) else { return request }
        return await transfer(request, remote: snapshot.remote)
    }

    /// Clones `url` into `parent/name` (stoppable: cancelling the task ends Git and removes what it
    /// left). Returns the new repository's folder.
    func clone(url: String, parent: String, name: String, store: StackStore) async throws -> String {
        try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
        return try await store.stoppableCall(await transfer(["method": "gitClone", "path": parent, "url": url, "name": name], remote: url))
    }

    /// What «Publicar» does once confirmed: creates `owner/name` on the provider (or, when it
    /// exists already and the account sees it, uses it), adds it as `origin` and sends `branches`
    /// without forcing. `resuming`: `origin` already is that repository, only the branches go.
    /// Returns `owner/name` and the branches sent.
    func publish(_ repository: GitRepository, provider: GitHostingProvider, owner: String, name: String, summary: String,
                 isPrivate: Bool, useSSH: Bool, branches: [String], resuming: Bool) async throws -> (path: String, pushed: [String]) {
        let credentials = try await credentials(for: provider)
        let slug = provider == .bitbucket ? name.lowercased() : name
        var path = "\(owner)/\(slug)"
        let url: String
        if resuming {
            let pair = GitHostedRepository.cloneAddresses(provider: provider, path: path, endpoints: endpoints)
            url = useSSH ? pair.ssh : pair.https
        } else {
            let made: GitHostingRemoteRepository
            do {
                made = try await client.createRepository(provider, owner: owner, name: name, isPrivate: isPrivate, summary: summary, credentials: credentials)
            } catch let failure as GitHostingFailure where failure.code == .rejected {
                // It exists already (an earlier attempt made it): go on only when the account sees it.
                guard let existing = await client.repository(provider, owner: owner, name: name, credentials: credentials) else { throw failure }
                made = existing
            }
            url = useSSH ? made.ssh : made.https
            path = made.fullName
        }
        let request = await transfer(["method": "gitPublish", "path": repository.root, "url": url, "branches": branches, "replaceOrigin": resuming, "confirmed": true],
                                     remote: url)
        let pushed: [String] = try await repository.store.stoppableCall(request)
        await repository.refresh()
        let session = session(for: repository)
        await session.readRemote()
        await session.syncProtection()
        return (path, pushed)
    }
}
