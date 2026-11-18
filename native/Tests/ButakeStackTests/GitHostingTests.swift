import Foundation
import Testing
@testable import ButakeStack

// GitHub and Bitbucket Cloud against a fake server on 127.0.0.1 (`GitHostingFakeServer`) with
// invented accounts and a Keychain in memory: never the real providers, accounts or Keychain. Clone
// and publish run the real engine and Git on temporary repositories; the clone addresses of the
// fake hosts reach local bare repositories through `url.<carpeta>.insteadOf`, in a Git
// configuration of this process only. No network.

/// A token nobody has: if it shows up anywhere but the request's header, the test says where.
private let sentinel = "ficha-centinela-7f3a9c1e5b2d4086"

/// Git's configuration for this process and the engines it starts: an identity and the fake
/// hosts mapped to `remotes` (environment variables, never the user's files).
private func isolateGit(remotes: URL) {
    if ProcessInfo.processInfo.environment["GIT_CONFIG_GLOBAL"] == nil {
        let config = FileManager.default.temporaryDirectory.appendingPathComponent("stack-hosting-gitconfig-\(ProcessInfo.processInfo.processIdentifier)")
        FileManager.default.createFile(atPath: config.path, contents: Data())
        setenv("GIT_CONFIG_GLOBAL", config.path, 1)
    }
    setenv("GIT_CONFIG_NOSYSTEM", "1", 1)
    let entries = [("user.name", "Stack QA"), ("user.email", "qa@example.invalid"), ("commit.gpgsign", "false"),
                   ("url.\(remotes.path)/.insteadOf", "https://github.fake.invalid/"),
                   ("url.\(remotes.path)/.insteadOf", "https://bitbucket.fake.invalid/"),
                   ("url.\(remotes.path)/.insteadOf", "git@github.fake.invalid:")]
    setenv("GIT_CONFIG_COUNT", "\(entries.count)", 1)
    for (index, entry) in entries.enumerated() {
        setenv("GIT_CONFIG_KEY_\(index)", entry.0, 1)
        setenv("GIT_CONFIG_VALUE_\(index)", entry.1, 1)
    }
}

@discardableResult private func run(_ folder: URL, _ arguments: String...) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = arguments
    process.currentDirectoryURL = folder
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let text = String(decoding: data, as: UTF8.self)
    guard process.terminationStatus == 0 else { throw EngineFailure(code: "git", messageKey: "git", detail: text) }
    return text
}

/// A fake server, a store in memory and a temporary folder for repositories.
@MainActor private struct Fixture {
    let root: URL
    let remotes: URL
    let server: GitHostingFakeServer
    let items = MemoryKeychainItems()
    let hosting: GitHosting

    init(token: String = sentinel) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("stack-hosting-\(UUID().uuidString)").resolvingSymlinksInPath()
        remotes = root.appendingPathComponent("remotos")
        try FileManager.default.createDirectory(at: remotes, withIntermediateDirectories: true)
        server = try GitHostingFakeServer(remotes: remotes, tokens: ["github": token, "bitbucket": token])
        hosting = GitHosting(endpoints: server.endpoints, vault: GitHostingVault(items: items))
    }

    func cleanUp() {
        server.stop()
        try? FileManager.default.removeItem(at: root)
    }

    /// A local repository whose `origin` is `owner/name` on the fake GitHub, with `feature/pagos` published.
    func repository(_ store: StackStore, path: String = "acme/tienda") async throws -> GitRepository {
        isolateGit(remotes: remotes)
        let bare = remotes.appendingPathComponent("\(path).git")
        try FileManager.default.createDirectory(at: bare, withIntermediateDirectories: true)
        try run(bare, "init", "-q", "--bare", "-b", "main")
        let work = root.appendingPathComponent("trabajo-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try run(work, "init", "-q", "-b", "main")
        try "hola\n".write(to: work.appendingPathComponent("leeme.txt"), atomically: true, encoding: .utf8)
        try run(work, "add", "leeme.txt")
        try run(work, "commit", "-q", "-m", "chore: base")
        try run(work, "remote", "add", "origin", "https://github.fake.invalid/\(path).git")
        try run(work, "push", "-q", "-u", "origin", "main")
        try run(work, "switch", "-q", "-c", "feature/pagos")
        try "pago\n".write(to: work.appendingPathComponent("pago.txt"), atomically: true, encoding: .utf8)
        try run(work, "add", "pago.txt")
        try run(work, "commit", "-q", "-m", "feat: pago con tarjeta")
        try run(work, "push", "-q", "-u", "origin", "feature/pagos")
        let _: [ToolInfo] = try await store.call(["method": "pluginSetEnabled", "id": "git", "enabled": true])
        let snapshot: GitSnapshot = try await store.call(["method": "gitOpen", "path": work.path])
        return GitRepository(snapshot: snapshot, store: store)
    }
}

// MARK: - Pure rules

@MainActor @Test func remotesOfBothProvidersAreReadStrictly() {
    let real = GitHostingEndpoints.production
    #expect(GitHostedRepository(remote: "git@github.com:acme/tienda.git", endpoints: real) == GitHostedRepository(provider: .github, owner: "acme", name: "tienda"))
    #expect(GitHostedRepository(remote: "https://github.com/acme/tienda", endpoints: real)?.path == "acme/tienda")
    #expect(GitHostedRepository(remote: "ssh://git@ssh.github.com:443/acme/tienda.git", endpoints: real)?.provider == .github)
    #expect(GitHostedRepository(remote: "https://ana@bitbucket.org/equipo/app.git", endpoints: real) == GitHostedRepository(provider: .bitbucket, owner: "equipo", name: "app"))
    // A password in the address, another server, a path that is not owner/name: nothing.
    #expect(GitHostedRepository(remote: "https://ana:secreto@bitbucket.org/equipo/app.git", endpoints: real) == nil)
    #expect(GitHostedRepository(remote: "git@gitlab.example:acme/tienda.git", endpoints: real) == nil)
    #expect(GitHostedRepository(remote: "https://github.com/acme/../tienda", endpoints: real) == nil)
    #expect(GitHostedRepository(remote: "https://github.com/acme/tienda/extra", endpoints: real) == nil)
    // The fake hosts are only the fake server's.
    #expect(GitHostedRepository(remote: "https://github.fake.invalid/acme/tienda.git", endpoints: real) == nil)
    #expect(GitHostedRepository(remote: "https://github.fake.invalid/acme/tienda.git", endpoints: .loopback(port: 9))?.provider == .github)
}

@Test func bitbucketSSHUsesItsNewNameAndStillReadsTheOldOne() {
    let real = GitHostingEndpoints.production
    let expected = GitHostedRepository(provider: .bitbucket, owner: "equipo", name: "app")
    for remote in ["git@ssh.bitbucket.org:equipo/app.git", "ssh://git@ssh.bitbucket.org/equipo/app.git", "git@bitbucket.org:equipo/app.git",
                   "ssh://git@altssh.bitbucket.org:443/equipo/app.git"] {
        #expect(GitHostedRepository(remote: remote, endpoints: real) == expected, "\(remote)")
    }
    let addresses = GitHostedRepository.cloneAddresses(provider: .bitbucket, path: "equipo/app", endpoints: real)
    #expect(addresses.ssh == "git@ssh.bitbucket.org:equipo/app.git" && addresses.https == "https://bitbucket.org/equipo/app.git")
    #expect(GitHostedRepository.cloneAddresses(provider: .github, path: "a/b", endpoints: real).ssh == "git@github.com:a/b.git")
}

@Test func listsFollowTheProvidersNextAddressAndLimitsSayWhenToRetry() {
    #expect(GitHostingClient.nextLink(#"<https://api.github.com/user/repos?page=2>; rel="next", <https://api.github.com/user/repos?page=9>; rel="last""#)
            == "https://api.github.com/user/repos?page=2")
    #expect(GitHostingClient.nextLink(#"<https://api.github.com/user/repos?page=1>; rel="prev""#) == nil)
    #expect(GitHostingClient.nextLink(nil) == nil)
    let url = URL(string: "https://api.github.com/user")!
    let now = Date(timeIntervalSince1970: 1_000_000)
    func response(_ headers: [String: String]) -> HTTPURLResponse { HTTPURLResponse(url: url, statusCode: 403, httpVersion: nil, headerFields: headers)! }
    #expect(GitHostingClient.retryDate(response(["Retry-After": "90"]), now: now) == now.addingTimeInterval(90))
    #expect(GitHostingClient.retryDate(response(["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "1000300"]), now: now) == Date(timeIntervalSince1970: 1_000_300))
    #expect(GitHostingClient.retryDate(response([:]), now: now) == nil)
    // A 403 with the limit spent is «rate limited», whatever the message says; any other is «forbidden».
    let limited = GitHostingClient.failure(status: 403, data: Data(), provider: .github, token: "x", headers: response(["X-RateLimit-Remaining": "0"]))
    #expect(limited.code == .rateLimited)
    #expect(GitHostingClient.failure(status: 403, data: Data(), provider: .github, token: "x", headers: response([:])).code == .forbidden)
}

@Test func aBranchingModelSaysWhichTypeABranchIs() throws {
    let json = #"{"development":{"branch":{"name":"develop"}},"production":{"branch":{"name":"main"}},"branch_types":[{"kind":"feature","prefix":"feature/"}]}"#
    let model = try JSONDecoder().decode(BBBranchingModel.self, from: Data(json.utf8))
    #expect(model.type(of: "main") == "production" && model.type(of: "develop") == "development")
    #expect(model.type(of: "feature/pagos") == "feature" && model.type(of: "otra") == nil)
    #expect(!model.unresolved)
    let main = try JSONDecoder().decode(BBBranchingModel.self, from: Data(#"{"development":{"use_mainbranch":true},"production":{"branch":{"name":"prod"}}}"#.utf8))
    #expect(main.unresolved)
}

@Test func theTokenFollowsARedirectOnlyInsideTheSameOrigin() {
    var original = URLRequest(url: URL(string: "https://api.example.invalid/repos/acme/tienda")!)
    original.setValue("Bearer \(sentinel)", forHTTPHeaderField: "Authorization")
    let task = URLSession(configuration: .ephemeral).dataTask(with: original)
    let response = HTTPURLResponse(url: original.url!, statusCode: 301, httpVersion: nil, headerFields: nil)!
    func follow(_ address: String) -> URLRequest? {
        var answer: URLRequest?
        GitHostingRedirects().urlSession(.shared, task: task, willPerformHTTPRedirection: response,
                                         newRequest: URLRequest(url: URL(string: address)!)) { answer = $0 }
        return answer
    }
    #expect(follow("https://api.example.invalid/repos/acme/tienda-nueva")?.value(forHTTPHeaderField: "Authorization") == "Bearer \(sentinel)")
    #expect(follow("https://otro.example.invalid/repos/acme/tienda") == nil)
    #expect(follow("https://api.example.invalid:8443/repos/acme/tienda") == nil)
    #expect(follow("http://api.example.invalid/repos/acme/tienda") == nil)
}

@Test func requestsOnlyGoToTheProvidersOwnAPI() {
    let real = GitHostingEndpoints.production
    #expect(real.allows(URL(string: "https://api.github.com/user")!, for: .github))
    #expect(!real.allows(URL(string: "https://api.github.com.evil.example/user")!, for: .github))
    #expect(!real.allows(URL(string: "http://api.github.com/user")!, for: .github))
    #expect(!real.allows(URL(string: "https://api.bitbucket.org/2.0/user")!, for: .github))
    #expect(real.allows(URL(string: "https://api.bitbucket.org/2.0/user")!, for: .bitbucket))
    #expect(!real.allows(URL(string: "https://api.bitbucket.org/user")!, for: .bitbucket))
    let fake = GitHostingEndpoints.loopback(port: 4242)
    #expect(fake.allows(URL(string: "http://127.0.0.1:4242/github/user")!, for: .github))
    #expect(!fake.allows(URL(string: "http://127.0.0.1:4243/github/user")!, for: .github))
    #expect(!fake.allows(URL(string: "http://127.0.0.1:4242/bitbucket/user")!, for: .github))
}

@Test func failedChecksBecomeOneProblemForProblemas() {
    let checks = [GitHostingCheck(id: "1", name: "build", state: .failure, page: URL(string: "https://github.com/acme/tienda/runs/1")),
                  GitHostingCheck(id: "2", name: "lint", state: .failure, page: nil),
                  GitHostingCheck(id: "3", name: "tests", state: .pending, page: nil),
                  GitHostingCheck(id: "4", name: "docs", state: .success, page: nil)]
    let pr = GitPullRequest(id: 7, title: "Pagos", body: "", state: .open, draft: false, author: "ana", source: "feature/pagos", target: "main",
                            head: nil, page: URL(string: "https://github.com/acme/tienda/pull/7"), updated: nil)
    let problems = GitHostingProblems.problems(branch: "feature/pagos", provider: .github, checks: checks, pullRequest: pr, repositoryPage: nil)
    #expect(problems.count == 1)
    #expect(problems[0].kind == .checksFailed && problems[0].checks == ["build", "lint"])
    #expect(problems[0].title == "2 comprobaciones fallaron en feature/pagos")
    #expect(problems[0].detail.contains("build, lint"))
    #expect(problems[0].actionTitle == "Ver en GitHub")
    #expect(problems[0].page == pr.page)
    // One failure: its own page. Passing or running checks: no problem.
    let one = GitHostingProblems.problems(branch: "x", provider: .bitbucket, checks: [checks[0]], pullRequest: nil, repositoryPage: nil)
    #expect(one.first?.page == checks[0].page && one.first?.title == "Una comprobación falló en x")
    #expect(GitHostingProblems.problems(branch: "x", provider: .github, checks: Array(checks[2...]), pullRequest: nil, repositoryPage: nil).isEmpty)
}

/// The texts the screens compose at run time («git.pr.state.\(…)»…) exist for every value.
@MainActor @Test func everyComposedTextOfTheProvidersExists() {
    var keys = GitHostingFailure.Code.allCases.map { "git.hosting.error.\($0.rawValue)" }
    keys += GitPullRequestState.allCases.map { "git.pr.state.\($0.rawValue)" }
    keys += GitHostingSession.Scope.allCases.flatMap { ["git.pr.scope.\($0.rawValue)", "git.pr.empty.\($0.rawValue)"] }
    keys += [GitPullRequestReview.Verdict.approved, .changesRequested, .commented].map { "git.pr.review.\($0.rawValue)" }
    keys += [GitHostingCheck.State.success, .failure, .pending, .skipped].map { "git.pr.check.\($0.rawValue)" }
    keys += GitCloneSheet.Source.allCases.map { "git.clone.source.\($0.rawValue)" }
    keys += GitHostingProvider.allCases.flatMap { provider in (0..<GitHostingProvider.permissionCount).map { "git.hosting.permission.\(provider.rawValue).\($0)" } }
    keys += SettingsTab.allCases.map { "settings.tab.\($0.rawValue)" }
    #expect(keys.filter { localized($0) == nil }.isEmpty, "\(keys.filter { localized($0) == nil })")
}

@Test func credentialsNeverPrintTheirToken() {
    let credentials = GitHostingCredentials(email: "ana@example.invalid", token: sentinel)
    #expect(!"\(credentials)".contains(sentinel))
    #expect(!String(reflecting: credentials).contains(sentinel))
    // A provider that echoes the token in its message: it is hidden before reaching the user.
    let echoed = Data("{\"message\":\"Bad credentials \(sentinel)\"}".utf8)
    let failure = GitHostingClient.failure(status: 401, data: echoed, provider: .github, token: sentinel)
    #expect(failure.code == .unauthorized)
    #expect(!(failure.errorDescription ?? "").contains(sentinel))
}

// MARK: - Accounts

@MainActor @Test func anAccountIsSavedOnlyOnceTheProviderAcceptsItAndListedWithoutReadingTheToken() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let hosting = fixture.hosting
    // A wrong token: refused, nothing saved, and the message does not repeat it.
    await #expect(throws: GitHostingFailure.self) { try await hosting.connect(.github, email: "", token: "otra-ficha") }
    #expect(fixture.items.accounts.isEmpty)
    do { _ = try await hosting.connect(.github, email: "", token: "otra-ficha") } catch {
        #expect((error as? GitHostingFailure)?.code == .unauthorized)
        #expect(!(error.localizedDescription).contains("otra-ficha"))
    }
    // Bitbucket needs the account's email.
    await #expect(throws: GitHostingFailure.self) { try await hosting.connect(.bitbucket, email: "", token: sentinel) }

    let github = try await hosting.connect(.github, email: "", token: sentinel)
    #expect(github.id == "github/ana-qa" && github.display == "Ana Prueba (ana-qa)")
    let bitbucket = try await hosting.connect(.bitbucket, email: fixture.server.email, token: sentinel)
    #expect(bitbucket.id == "bitbucket/ana-qa")
    // One item per account; its attributes say who it is, never the token.
    #expect(fixture.items.accounts == ["github/ana-qa", "bitbucket/ana-qa"])
    for entry in fixture.items.list(prefix: "") {
        #expect(!String(decoding: entry.attributes ?? Data(), as: UTF8.self).contains(sentinel))
    }
    // Listing the accounts (what Ajustes and the tab do) reads no token: no Keychain prompt.
    let fresh = GitHosting(endpoints: fixture.server.endpoints, vault: GitHostingVault(items: fixture.items))
    let reads = fixture.items.reads.count
    await fresh.loadAccounts()
    #expect(fresh.accounts.map(\.id) == ["bitbucket/ana-qa", "github/ana-qa"])
    #expect(fixture.items.reads.count == reads)
    // The token is read once, when a request needs it.
    _ = try await fresh.test(github)
    _ = try await fresh.test(github)
    #expect(fixture.items.reads.count == reads + 1)
    // Disconnecting removes the item.
    await fresh.disconnect(github)
    #expect(fixture.items.accounts == ["bitbucket/ana-qa"])
    #expect(fresh.account(for: .github) == nil)
}

/// The flows that run the engine and Git, one at a time: they set Git's configuration for this
/// process (`isolateGit`), which other tests running at the same time must not see change.
@Suite(.serialized) @MainActor struct GitHostingFlowTests {
    // MARK: - Pull requests

    @Test func pullRequestsAreListedOpenedCheckedCreatedApprovedCommentedAndMerged() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let store = StackStore(engine: StackEngine())
        let repository = try await fixture.repository(store)
        defer { repository.stopWatching() }
        let session = fixture.hosting.session(for: repository)
        // Without an account the tab explains what is missing.
        await session.load()
        #expect(session.remote == "https://github.fake.invalid/acme/tienda.git")
        #expect(session.availability == .noAccount(.github))

        _ = try await fixture.hosting.connect(.github, email: "", token: sentinel)
        let ready = fixture.hosting.session(for: repository)
        guard case .ready(let hosted, _) = ready.availability else { Issue.record("not ready"); return }
        #expect(hosted.path == "acme/tienda")

        // The current branch's pull request, its checks (one failed) and the problem for Problemas.
        await ready.load()
        #expect(ready.pullRequests.map(\.id) == [7])
        #expect(ready.selected == 7)
        #expect(ready.listChecks[7]?.count == 3)
        #expect(ready.branchPullRequest?.id == 7)
        #expect(ready.branchChecks.filter { $0.state == .failure }.map(\.name) == ["build"])
        let problems = GitHostingProblems.problems(branch: repository.snapshot.branch, provider: .github, checks: ready.branchChecks,
                                                   pullRequest: ready.branchPullRequest, repositoryPage: nil)
        #expect(problems.first?.title == "Una comprobación falló en feature/pagos")
        // The provider protects main: the repository knows it now.
        #expect(repository.snapshot.mainProtected)

        // The detail: comments (conversation and a line), the review, checks and files from origin/….
        await ready.loadDetail()
        let detail = try #require(ready.detail)
        #expect(detail.comments.map(\.author) == ["carla-qa", "bruno-qa"])
        #expect(detail.comments.last?.path == "src/recibo.ts")
        #expect(detail.reviews == [GitPullRequestReview(author: "carla-qa", verdict: .changesRequested)])
        #expect(detail.checks.map(\.state) == [.failure, .success, .pending])
        #expect(detail.files?.map(\.path) == ["pago.txt"])
        let selected = try #require(ready.selectedPullRequest)
        let patch = try #require(await ready.patch(of: "pago.txt", in: selected))
        #expect(patch.contains("+pago"))

        // The whole repository: open, merged.
        ready.scope = .open
        await ready.loadList()
        #expect(ready.pullRequests.map(\.id) == [7, 5])
        ready.scope = .merged
        await ready.loadList()
        #expect(ready.pullRequests.map(\.id) == [3])

        // Approve, comment, merge (each confirmed by the view first).
        ready.scope = .open
        await ready.loadList()
        ready.selected = 7
        let seven = try #require(ready.selectedPullRequest)
        #expect(await ready.act(.approve, on: seven))
        #expect(await ready.act(.comment("Se ve bien"), on: seven))
        await ready.loadDetail()
        #expect(ready.detail?.reviews.contains(GitPullRequestReview(author: "ana-qa", verdict: .approved)) == true)
        #expect(ready.detail?.comments.contains { $0.body == "Se ve bien" && $0.author == "ana-qa" } == true)
        #expect(await ready.act(.merge, on: seven))
        #expect(fixture.server.repo("github", "acme/tienda")?.pulls.first { $0.number == 7 }?.state == "merged")

        // A new pull request from the current branch (no open one any more).
        #expect(await ready.create(title: "Pagos, segunda parte", body: "Recibo en PDF.", target: "main", draft: true))
        let created = try #require(ready.selectedPullRequest)
        #expect(created.title == "Pagos, segunda parte" && created.draft && created.source == "feature/pagos")
        #expect(ready.scope == .branch)
        #expect(ready.failure == nil)
    }

    /// The pull request is merged on the provider's page with «delete the branch»: back in Stack the
    /// branch is pruned without pressing anything, and one button goes back to main and deletes it.
    @Test func aPullRequestMergedOnTheWebIsFollowedWhenStackComesBack() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let store = StackStore(engine: StackEngine())
        let repository = try await fixture.repository(store)
        defer { repository.stopWatching() }
        _ = try await fixture.hosting.connect(.github, email: "", token: sentinel)
        #expect(repository.snapshot.branch == "feature/pagos")

        // What the provider does: merges into main and deletes feature/pagos.
        let bare = fixture.remotes.appendingPathComponent("acme/tienda.git")
        let other = fixture.root.appendingPathComponent("proveedor")
        try run(fixture.root, "clone", "-q", "-b", "main", bare.path, other.path)
        try run(other, "merge", "-q", "--no-ff", "-m", "Merge pull request #7", "origin/feature/pagos")
        try run(other, "push", "-q", "origin", "main")
        try run(other, "push", "-q", "origin", "--delete", "feature/pagos")

        // Back from a page Stack did not open: nothing happens on its own.
        await fixture.hosting.returnedFromBrowser(in: repository)
        #expect(repository.snapshot.currentBranch?.gone == false)
        // Back from the page «Ver en GitHub» opened.
        fixture.hosting.awaitingReturn = true
        await fixture.hosting.returnedFromBrowser(in: repository)
        #expect(!fixture.hosting.awaitingReturn)
        #expect(repository.snapshot.currentBranch?.mergedAndGone == true)
        #expect(!repository.snapshot.remoteBranches.contains { $0.short == "feature/pagos" })

        let gone = try #require(GitProblemSources.shared.problems(for: repository).first { $0.id == "git.upstreamGone" })
        #expect(gone.title == "feature/pagos ya se combinó")
        #expect(gone.action?.title == "Volver a main y eliminar la rama")
        await gone.action?.run()
        #expect(repository.snapshot.branch == "main")
        #expect(repository.snapshot.branches.map(\.name) == ["main"])
        #expect(repository.snapshot.behind == 0)
        #expect(repository.failure == nil)
    }

    @Test func aSlowAnswerForAnotherScopeNeverReplacesTheListOnScreen() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let store = StackStore(engine: StackEngine())
        let repository = try await fixture.repository(store)
        defer { repository.stopWatching() }
        _ = try await fixture.hosting.connect(.github, email: "", token: sentinel)
        let session = fixture.hosting.session(for: repository)
        await session.load()
        // «Cerrados» answers late; «Abiertos» is chosen before it does.
        fixture.server.delay("state=closed", by: 0.8)
        session.scope = .closed
        try await Task.sleep(for: .milliseconds(150))
        session.scope = .open
        await session.loadList()
        #expect(session.pullRequests.map(\.id) == [7, 5])
        #expect(!session.loading)
        try await Task.sleep(for: .milliseconds(1_000))
        #expect(session.pullRequests.map(\.id) == [7, 5])
        #expect(session.scope == .open)
    }

    @Test func bitbucketWorksTheSameWay() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let credentials = GitHostingCredentials(email: fixture.server.email, token: sentinel)
        let client = fixture.hosting.client
        let repo = GitHostedRepository(provider: .bitbucket, owner: "acme", name: "tienda")
        let open = try await client.pullRequests(repo, state: .open, credentials: credentials)
        #expect(open.map(\.id) == [7, 5])
        #expect(open[0].page?.absoluteString == "https://bitbucket.fake.invalid/acme/tienda/pull-requests/7")
        let head = try #require(open[0].head)
        let checks = try await client.checks(repo, commit: head, credentials: credentials)
        #expect(checks.map(\.state) == [.failure, .success, .pending])
        #expect(try await client.reviews(repo, pr: 7, credentials: credentials) == [GitPullRequestReview(author: "carla-qa", verdict: .changesRequested)])
        #expect(try await client.comments(repo, pr: 7, credentials: credentials).count == 2)
        #expect(await client.protection(repo, branch: "main", credentials: credentials) == .protected)
        #expect(await client.protection(repo, branch: "develop", credentials: credentials) == .open)
        // The list of repositories to clone: Bitbucket's HTTPS address without the user name.
        let repositories = try await client.repositories(.bitbucket, credentials: credentials)
        #expect(repositories.map(\.fullName).contains("acme/tienda"))
        #expect(repositories.allSatisfy { !$0.https.contains("@") })
        #expect(try await client.owners(.bitbucket, credentials: credentials) == ["acme", "ana-qa"])
    }

    // MARK: - Clone and publish

    @Test func cloningFromTheAccountAndPublishingANewRepository() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let store = StackStore(engine: StackEngine())
        _ = try await fixture.hosting.connect(.github, email: "", token: sentinel)
        // A repository on the provider with a commit.
        let origin = try await fixture.repository(store, path: "acme/sitio-web")
        origin.stopWatching()

        // Clone it from the account's list (HTTPS address of the provider).
        let listed = try await fixture.hosting.client.repositories(.github, credentials: try await fixture.hosting.credentials(for: .github))
        let site = try #require(listed.first { $0.fullName == "acme/sitio-web" })
        let parent = fixture.root.appendingPathComponent("clonados").path
        let cloned = try await fixture.hosting.clone(url: site.https, parent: parent, name: GitCloneSheet.folderName(site.https), store: store)
        #expect(cloned.hasSuffix("/clonados/sitio-web"))
        #expect(FileManager.default.fileExists(atPath: cloned + "/leeme.txt"))

        // A new local repository, published as a private one on the account.
        let made: String = try await store.call(["method": "gitInit", "path": fixture.root.path, "name": "nuevo", "develop": true])
        let snapshot: GitSnapshot = try await store.call(["method": "gitOpen", "path": made])
        let repository = GitRepository(snapshot: snapshot, store: store)
        defer { repository.stopWatching() }
        #expect(repository.syncState == .publishRepository)
        let done = try await fixture.hosting.publish(repository, provider: .github, owner: "ana-qa", name: "nuevo", summary: "", isPrivate: true,
                                                     useSSH: false, branches: ["main", "develop"], resuming: false)
        #expect(done.path == "ana-qa/nuevo" && Set(done.pushed) == ["main", "develop"])
        #expect(fixture.server.repo("github", "ana-qa/nuevo")?.isPrivate == true)
        #expect(try run(fixture.remotes.appendingPathComponent("ana-qa/nuevo.git"), "branch", "--list").contains("develop"))
        #expect(repository.snapshot.hasRemote && repository.syncState == .fetch(last: nil))
        // Publishing into a repository the provider already has (created by an earlier attempt that
        // did not get to add `origin`): the provider says it exists, the account sees it, so it is used
        // as it is and nothing is created twice.
        let created = fixture.server.requests.filter { $0.method == "POST" }.count
        let other: String = try await store.call(["method": "gitInit", "path": fixture.root.path, "name": "otro", "develop": false])
        try run(URL(fileURLWithPath: other), "switch", "-q", "-c", "solo-aqui")
        let otherSnapshot: GitSnapshot = try await store.call(["method": "gitOpen", "path": other])
        let otherRepository = GitRepository(snapshot: otherSnapshot, store: store)
        defer { otherRepository.stopWatching() }
        let again = try await fixture.hosting.publish(otherRepository, provider: .github, owner: "ana-qa", name: "nuevo", summary: "", isPrivate: true,
                                                      useSSH: false, branches: ["solo-aqui"], resuming: false)
        #expect(again.path == "ana-qa/nuevo" && again.pushed == ["solo-aqui"])
        #expect(fixture.server.requests.filter { $0.method == "POST" }.count == created + 1, "one refused creation, no second repository")
        // A name the provider would not take never leaves the Mac.
        await #expect(throws: GitHostingFailure.self) {
            try await fixture.hosting.publish(repository, provider: .github, owner: "ana-qa", name: "con espacios", summary: "", isPrivate: true,
                                              useSSH: false, branches: ["main"], resuming: false)
        }
    }

    // MARK: - The token stays in the Keychain

    @Test func theTokenNeverReachesDiskLogsResponsesOrTheScreenTexts() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let store = StackStore(engine: StackEngine())
        let repository = try await fixture.repository(store)
        defer { repository.stopWatching() }
        _ = try await fixture.hosting.connect(.github, email: "", token: sentinel)
        _ = try await fixture.hosting.connect(.bitbucket, email: fixture.server.email, token: sentinel)
        let session = fixture.hosting.session(for: repository)
        await session.load()
        await session.loadDetail()
        let fresh: String = try await store.call(["method": "gitInit", "path": fixture.root.path, "name": "centinela", "develop": false])
        let freshSnapshot: GitSnapshot = try await store.call(["method": "gitOpen", "path": fresh])
        let freshRepository = GitRepository(snapshot: freshSnapshot, store: store)
        defer { freshRepository.stopWatching() }
        _ = try await fixture.hosting.publish(freshRepository, provider: .github, owner: "ana-qa", name: "centinela", summary: "", isPrivate: true,
                                              useSSH: false, branches: ["main"], resuming: false)
        // An error from the provider (a refused token) is shown without the token.
        let wrong = GitHosting(endpoints: fixture.server.endpoints, vault: GitHostingVault(items: MemoryKeychainItems()))
        let refused = await #expect(throws: GitHostingFailure.self) { try await wrong.connect(.github, email: "", token: sentinel + "x") }
        let message = refused?.errorDescription ?? ""
        #expect(!message.isEmpty && !message.contains(sentinel))

        // Only the Authorization header of the requests to the fake API carried it.
        #expect(!fixture.server.requests.isEmpty)
        for request in fixture.server.requests {
            #expect(!request.path.contains(sentinel))
            let lines = request.raw.split(separator: "\r\n").filter { $0.contains(sentinel) }
            #expect(lines.allSatisfy { $0.lowercased().hasPrefix("authorization: bearer") })
        }
        // What the views show: accounts, pull requests, detail, failures.
        let shown = "\(fixture.hosting.accounts) \(session.pullRequests) \(String(describing: session.detail)) \(String(describing: session.failure))"
        #expect(!shown.contains(sentinel))
        // Not in Stack's store, the repositories, the engine's answers or this app's preferences.
        let home = try #require(ProcessInfo.processInfo.environment["BUTAKE_STACK_HOME"])
        for folder in [URL(fileURLWithPath: home), fixture.root] {
            let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
            for file in files where (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                let data = (try? Data(contentsOf: file)) ?? Data()
                #expect(data.range(of: Data(sentinel.utf8)) == nil, "the token is in \(file.path)")
            }
        }
        let snapshot: JSONValue = try await store.call(["method": "gitSnapshot", "path": repository.root])
        #expect(!"\(snapshot)".contains(sentinel))
        let preferences = UserDefaults.standard.dictionaryRepresentation().description
        #expect(!preferences.contains(sentinel))
        // In memory only in its Keychain item (here the store in memory).
        #expect(fixture.items.accounts.count == 2)
    }
}

@Test func onlyFailuresThatSayNothingAboutTheTokenGiveItBackToTheField() {
    let usable: Set<GitHostingFailure.Code> = [.offline, .rateLimited, .keychain]
    for code in GitHostingFailure.Code.allCases {
        #expect(GitHostingFailure(code, provider: .github).leavesTokenUsable == usable.contains(code), "\(code)")
    }
}
