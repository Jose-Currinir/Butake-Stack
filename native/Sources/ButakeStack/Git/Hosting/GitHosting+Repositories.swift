import Foundation

/// Cloning and publishing, apart from their sheets so tests run them as the buttons do. Git does
/// the transfer through the engine with the Mac's SSH keys and credential managers; the token only
/// goes to the provider's API (listing, creating the repository).
extension GitHosting {
    /// Clones `url` into `parent/name` (stoppable: cancelling the task ends Git and removes what it
    /// left). Returns the new repository's folder.
    func clone(url: String, parent: String, name: String, store: StackStore) async throws -> String {
        try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
        return try await store.stoppableCall(["method": "gitClone", "path": parent, "url": url, "name": name])
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
        let pushed: [String] = try await repository.store.stoppableCall(["method": "gitPublish", "path": repository.root, "url": url, "branches": branches,
                                                                         "replaceOrigin": resuming, "confirmed": true])
        await repository.refresh()
        let session = session(for: repository)
        await session.readRemote()
        await session.syncProtection()
        return (path, pushed)
    }
}
