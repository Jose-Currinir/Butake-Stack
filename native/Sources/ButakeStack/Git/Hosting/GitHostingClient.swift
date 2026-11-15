import Foundation

/// Never follows a redirect to another host with the token: only one inside the provider's own
/// API (a renamed repository answers 301), keeping the request's credentials.
private final class GitHostingRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let original = task.originalRequest?.url, request.url?.host == original.host, request.url?.scheme == original.scheme,
              request.url?.port == original.port else { completionHandler(nil); return }
        var next = request
        if next.value(forHTTPHeaderField: "Authorization") == nil, let value = task.originalRequest?.value(forHTTPHeaderField: "Authorization") {
            next.setValue(value, forHTTPHeaderField: "Authorization")
        }
        completionHandler(next)
    }
}

/// The providers' web API, called by the app itself: the token goes from the Keychain to the
/// `Authorization` header of a request to the provider's own API host (`GitHostingEndpoints`),
/// and nowhere else. Ephemeral session: no cookies, no cache, nothing written to disk.
actor GitHostingClient {
    let endpoints: GitHostingEndpoints
    private let session: URLSession

    init(endpoints: GitHostingEndpoints) {
        self.endpoints = endpoints
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        session = URLSession(configuration: configuration, delegate: GitHostingRedirects(), delegateQueue: nil)
    }

    // MARK: Requests

    func send<T: Decodable>(_ provider: GitHostingProvider, _ endpoint: String, method: String = "GET", body: [String: Any]? = nil,
                            credentials: GitHostingCredentials) async throws -> T {
        guard !endpoint.contains(".."), !endpoint.hasPrefix("/"), let url = URL(string: endpoint, relativeTo: endpoints.apiBase(provider))?.absoluteURL,
              endpoints.allows(url, for: provider) else {
            throw GitHostingFailure(.invalid, provider: provider)
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        switch provider {
        case .github:
            request.setValue("Bearer \(credentials.token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        case .bitbucket:
            let pair = Data("\(credentials.email):\(credentials.token)".utf8).base64EncodedString()
            request.setValue("Basic \(pair)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
        }
        request.setValue("Stack", forHTTPHeaderField: "User-Agent")
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) } catch is CancellationError { throw CancellationError() } catch {
            if (error as? URLError)?.code == .cancelled { throw CancellationError() }
            throw GitHostingFailure(.offline, provider: provider)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(status) else { throw Self.failure(status: status, data: data, provider: provider, token: credentials.token) }
        if T.self == GitHostingIgnored.self || data.isEmpty { return try JSONDecoder().decode(T.self, from: Data("{}".utf8)) }
        do { return try JSONDecoder().decode(T.self, from: data) } catch { throw GitHostingFailure(.invalid, provider: provider) }
    }

    /// The code of an HTTP error and the provider's short message, without the token (in case the
    /// provider echoed it) and at most 300 characters.
    static func failure(status: Int, data: Data, provider: GitHostingProvider, token: String) -> GitHostingFailure {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        var message = (object?["message"] as? String) ?? ((object?["error"] as? [String: Any])?["message"] as? String) ?? ""
        if !token.isEmpty { message = message.replacingOccurrences(of: token, with: "••••") }
        message = String(message.prefix(300))
        let code: GitHostingFailure.Code = switch status {
        case 401: .unauthorized
        case 403: message.localizedCaseInsensitiveContains("rate limit") ? .rateLimited : .forbidden
        case 404: .notFound
        case 429: .rateLimited
        case 400, 405, 409, 422: .rejected
        default: .offline
        }
        return GitHostingFailure(code, provider: provider, detail: message)
    }

    /// Every page of a GitHub list (`per_page` already in the endpoint), up to `pages`.
    private func githubAll<T: Decodable>(_ endpoint: String, perPage: Int = 100, pages: Int = 5, credentials: GitHostingCredentials) async throws -> [T] {
        var all: [T] = []
        for page in 1...pages {
            let items: [T] = try await send(.github, endpoint + (endpoint.contains("?") ? "&" : "?") + "page=\(page)", credentials: credentials)
            all += items
            if items.count < perPage { break }
        }
        return all
    }

    /// Every page of a Bitbucket list, up to `pages`.
    private func bitbucketAll<T: Decodable>(_ endpoint: String, pages: Int = 5, credentials: GitHostingCredentials) async throws -> [T] {
        var all: [T] = []
        for page in 1...pages {
            let result: BBPage<T> = try await send(.bitbucket, endpoint + (endpoint.contains("?") ? "&" : "?") + "page=\(page)", credentials: credentials)
            all += result.values
            if result.next == nil || result.values.isEmpty { break }
        }
        return all
    }

    // MARK: Account

    /// Checks the token and says whose it is.
    func verify(_ provider: GitHostingProvider, credentials: GitHostingCredentials) async throws -> GitHostingAccount {
        switch provider {
        case .github:
            let user: GHUser = try await send(.github, "user", credentials: credentials)
            return GitHostingAccount(provider: .github, login: user.login, name: user.name ?? "", email: "")
        case .bitbucket:
            let user: BBUser = try await send(.bitbucket, "user", credentials: credentials)
            let login = user.username ?? user.nickname ?? credentials.email
            guard GitHostedRepository.validPart(login) || login.contains("@") else { throw GitHostingFailure(.invalid, provider: provider) }
            return GitHostingAccount(provider: .bitbucket, login: login, name: user.display_name ?? "", email: credentials.email)
        }
    }

    // MARK: Pull requests

    func pullRequests(_ repo: GitHostedRepository, state: GitPullRequestState, credentials: GitHostingCredentials) async throws -> [GitPullRequest] {
        switch repo.provider {
        case .github:
            let pulls: [GHPull] = try await send(.github, "repos/\(repo.path)/pulls?state=\(state == .open ? "open" : "closed")&per_page=50&sort=updated&direction=desc",
                                                 credentials: credentials)
            return pulls.map(\.pullRequest).filter { $0.state == state }
        case .bitbucket:
            let remote = ["open": "OPEN", "merged": "MERGED", "closed": "DECLINED"][state.rawValue] ?? "OPEN"
            let page: BBPage<BBPull> = try await send(.bitbucket, "repositories/\(repo.path)/pullrequests?state=\(remote)&pagelen=50&sort=-updated_on",
                                                      credentials: credentials)
            return page.values.map(\.pullRequest)
        }
    }

    func comments(_ repo: GitHostedRepository, pr: Int, credentials: GitHostingCredentials) async throws -> [GitPullRequestComment] {
        switch repo.provider {
        case .github:
            let general: [GHComment] = try await githubAll("repos/\(repo.path)/issues/\(pr)/comments?per_page=100", credentials: credentials)
            let inline: [GHComment] = (try? await githubAll("repos/\(repo.path)/pulls/\(pr)/comments?per_page=100", credentials: credentials)) ?? []
            let all = general.map { GitPullRequestComment(id: "c\($0.id)", author: $0.user?.login ?? "—", body: $0.body ?? "", created: gitHostingDate($0.created_at)) }
                + inline.map { GitPullRequestComment(id: "l\($0.id)", author: $0.user?.login ?? "—", body: $0.body ?? "", created: gitHostingDate($0.created_at),
                                                     path: $0.path, line: $0.line ?? $0.original_line) }
            return all.sorted { ($0.created ?? .distantPast) < ($1.created ?? .distantPast) }
        case .bitbucket:
            let values: [BBComment] = try await bitbucketAll("repositories/\(repo.path)/pullrequests/\(pr)/comments?pagelen=100", credentials: credentials)
            return values.filter { $0.deleted != true }.map {
                GitPullRequestComment(id: "c\($0.id)", author: $0.user?.display_name ?? "—", body: $0.content.raw ?? "", created: gitHostingDate($0.created_on),
                                      path: $0.inline?.path, line: $0.inline?.to ?? $0.inline?.from)
            }
            .sorted { ($0.created ?? .distantPast) < ($1.created ?? .distantPast) }
        }
    }

    /// The last verdict of each reviewer.
    func reviews(_ repo: GitHostedRepository, pr: Int, credentials: GitHostingCredentials) async throws -> [GitPullRequestReview] {
        switch repo.provider {
        case .github:
            let items: [GHReview] = try await githubAll("repos/\(repo.path)/pulls/\(pr)/reviews?per_page=100", credentials: credentials)
            var latest: [String: GitPullRequestReview.Verdict] = [:]
            var order: [String] = []
            for review in items {
                guard let author = review.user?.login else { continue }
                let verdict: GitPullRequestReview.Verdict? = switch review.state {
                case "APPROVED": .approved
                case "CHANGES_REQUESTED": .changesRequested
                case "COMMENTED", "DISMISSED": latest[author] == nil ? .commented : nil
                default: nil
                }
                guard let verdict else { continue }
                if latest[author] == nil { order.append(author) }
                latest[author] = verdict
            }
            return order.compactMap { author in latest[author].map { GitPullRequestReview(author: author, verdict: $0) } }
        case .bitbucket:
            let detail: BBPullDetail = try await send(.bitbucket, "repositories/\(repo.path)/pullrequests/\(pr)", credentials: credentials)
            return detail.participants.compactMap { participant in
                guard let name = participant.user?.display_name else { return nil }
                if participant.approved == true || participant.state == "approved" { return GitPullRequestReview(author: name, verdict: .approved) }
                if participant.state == "changes_requested" { return GitPullRequestReview(author: name, verdict: .changesRequested) }
                return nil
            }
        }
    }

    /// The checks of a commit.
    func checks(_ repo: GitHostedRepository, commit: String, credentials: GitHostingCredentials) async throws -> [GitHostingCheck] {
        guard !commit.isEmpty, commit.allSatisfy(\.isHexDigit) else { return [] }
        switch repo.provider {
        case .github:
            let runs: GHCheckRuns = try await send(.github, "repos/\(repo.path)/commits/\(commit)/check-runs?per_page=100", credentials: credentials)
            return runs.check_runs.map { run in
                let state: GitHostingCheck.State = run.status != "completed" ? .pending
                    : run.conclusion == "success" ? .success
                    : ["failure", "timed_out", "cancelled", "action_required", "startup_failure"].contains(run.conclusion ?? "") ? .failure : .skipped
                return GitHostingCheck(id: "\(run.id)", name: run.name, state: state, page: run.html_url.flatMap(URL.init(string:)))
            }
        case .bitbucket:
            let statuses: [BBStatus] = try await bitbucketAll("repositories/\(repo.path)/commit/\(commit)/statuses?pagelen=100", credentials: credentials)
            return statuses.map { status in
                let state: GitHostingCheck.State = switch status.state {
                case "SUCCESSFUL": .success
                case "FAILED", "STOPPED": .failure
                case "INPROGRESS": .pending
                default: .skipped
                }
                return GitHostingCheck(id: status.key, name: status.name ?? status.key, state: state, page: status.url.flatMap(URL.init(string:)))
            }
        }
    }

    func createPullRequest(_ repo: GitHostedRepository, title: String, body: String, source: String, target: String, draft: Bool,
                           credentials: GitHostingCredentials) async throws -> GitPullRequest {
        switch repo.provider {
        case .github:
            let pull: GHPull = try await send(.github, "repos/\(repo.path)/pulls", method: "POST",
                                              body: ["title": title, "body": body, "head": source, "base": target, "draft": draft], credentials: credentials)
            return pull.pullRequest
        case .bitbucket:
            let pull: BBPull = try await send(.bitbucket, "repositories/\(repo.path)/pullrequests", method: "POST",
                                              body: ["title": title, "description": body, "source": ["branch": ["name": source]],
                                                     "destination": ["branch": ["name": target]], "close_source_branch": false, "draft": draft],
                                              credentials: credentials)
            return pull.pullRequest
        }
    }

    func approve(_ repo: GitHostedRepository, pr: Int, credentials: GitHostingCredentials) async throws {
        switch repo.provider {
        case .github:
            let _: GitHostingIgnored = try await send(.github, "repos/\(repo.path)/pulls/\(pr)/reviews", method: "POST", body: ["event": "APPROVE"], credentials: credentials)
        case .bitbucket:
            let _: GitHostingIgnored = try await send(.bitbucket, "repositories/\(repo.path)/pullrequests/\(pr)/approve", method: "POST", credentials: credentials)
        }
    }

    func comment(_ repo: GitHostedRepository, pr: Int, text: String, credentials: GitHostingCredentials) async throws {
        switch repo.provider {
        case .github:
            let _: GitHostingIgnored = try await send(.github, "repos/\(repo.path)/issues/\(pr)/comments", method: "POST", body: ["body": text], credentials: credentials)
        case .bitbucket:
            let _: GitHostingIgnored = try await send(.bitbucket, "repositories/\(repo.path)/pullrequests/\(pr)/comments", method: "POST",
                                                      body: ["content": ["raw": text]], credentials: credentials)
        }
    }

    /// Joins the pull request into its target, keeping the source branch.
    func merge(_ repo: GitHostedRepository, pr: Int, credentials: GitHostingCredentials) async throws {
        switch repo.provider {
        case .github:
            let _: GitHostingIgnored = try await send(.github, "repos/\(repo.path)/pulls/\(pr)/merge", method: "PUT", body: [:], credentials: credentials)
        case .bitbucket:
            let _: GitHostingIgnored = try await send(.bitbucket, "repositories/\(repo.path)/pullrequests/\(pr)/merge", method: "POST",
                                                      body: ["close_source_branch": false], credentials: credentials)
        }
    }

    // MARK: Repositories

    /// The repositories of the account, most recently updated first.
    func repositories(_ provider: GitHostingProvider, credentials: GitHostingCredentials) async throws -> [GitHostingRemoteRepository] {
        switch provider {
        case .github:
            let items: [GHRepo] = try await githubAll("user/repos?per_page=100&sort=updated", credentials: credentials)
            return items.map(\.remote)
        case .bitbucket:
            var repos: [GitHostingRemoteRepository] = []
            for owner in try await owners(.bitbucket, credentials: credentials) {
                let values: [BBRepo] = try await bitbucketAll("repositories/\(owner)?pagelen=100&sort=-updated_on", credentials: credentials)
                repos += values.map { $0.remote(endpoints) }
            }
            return repos
        }
    }

    /// Where the account can create repositories: GitHub's user and organizations, Bitbucket's workspaces.
    func owners(_ provider: GitHostingProvider, credentials: GitHostingCredentials) async throws -> [String] {
        switch provider {
        case .github:
            let user: GHUser = try await send(.github, "user", credentials: credentials)
            let orgs: [GHOrg] = (try? await githubAll("user/orgs?per_page=100", credentials: credentials)) ?? []
            return ([user.login] + orgs.map(\.login)).filter(GitHostedRepository.validPart)
        case .bitbucket:
            let values: [BBWorkspaceAccess] = try await bitbucketAll("user/workspaces?pagelen=100", credentials: credentials)
            return values.compactMap { $0.workspace?.slug }.filter(GitHostedRepository.validPart)
        }
    }

    /// An existing repository, or nil when it does not exist or the token cannot see it.
    func repository(_ provider: GitHostingProvider, owner: String, name: String, credentials: GitHostingCredentials) async -> GitHostingRemoteRepository? {
        guard GitHostedRepository.validPart(owner), GitHostedRepository.validPart(name) else { return nil }
        switch provider {
        case .github:
            let repo: GHRepo? = try? await send(.github, "repos/\(owner)/\(name)", credentials: credentials)
            return repo?.remote
        case .bitbucket:
            let repo: BBRepo? = try? await send(.bitbucket, "repositories/\(owner)/\(name.lowercased())", credentials: credentials)
            return repo?.remote(endpoints)
        }
    }

    /// Creates an empty repository (no first file, so the first push is a plain one).
    func createRepository(_ provider: GitHostingProvider, owner: String, name: String, isPrivate: Bool, summary: String,
                          credentials: GitHostingCredentials) async throws -> GitHostingRemoteRepository {
        guard GitHostedRepository.validPart(owner), GitHostedRepository.validPart(name) else { throw GitHostingFailure(.invalid, provider: provider) }
        switch provider {
        case .github:
            let user: GHUser = try await send(.github, "user", credentials: credentials)
            let endpoint = owner == user.login ? "user/repos" : "orgs/\(owner)/repos"
            let repo: GHRepo = try await send(.github, endpoint, method: "POST",
                                              body: ["name": name, "private": isPrivate, "description": summary, "auto_init": false], credentials: credentials)
            return repo.remote
        case .bitbucket:
            let repo: BBRepo = try await send(.bitbucket, "repositories/\(owner)/\(name.lowercased())", method: "POST",
                                              body: ["scm": "git", "is_private": isPrivate, "description": summary], credentials: credentials)
            return repo.remote(endpoints)
        }
    }

    /// Whether the provider blocks direct pushes to `branch`.
    func protection(_ repo: GitHostedRepository, branch: String, credentials: GitHostingCredentials) async -> GitHostingProtection {
        guard !branch.isEmpty, branch.allSatisfy({ $0.isLetter || $0.isNumber || "-_./".contains($0) }), !branch.contains("..") else { return .unknown }
        func lookup(_ error: Error) -> GitHostingProtection {
            guard let failure = error as? GitHostingFailure else { return .unreachable }
            return failure.code == .forbidden || failure.code == .notFound ? .unknown : .unreachable
        }
        switch repo.provider {
        case .github:
            do {
                let info: GHBranch = try await send(.github, "repos/\(repo.path)/branches/\(branch)", credentials: credentials)
                if info.protected { return .protected }
            } catch { return lookup(error) }
            // Rulesets do not always mark the branch: a pull request or update rule also blocks pushes.
            let rules: [GHRule]? = try? await send(.github, "repos/\(repo.path)/rules/branches/\(branch)", credentials: credentials)
            return rules?.contains { ["pull_request", "update"].contains($0.type) } == true ? .protected : .open
        case .bitbucket:
            do {
                let restrictions: [BBRestriction] = try await bitbucketAll("repositories/\(repo.path)/branch-restrictions?kind=push&pagelen=100", credentials: credentials)
                let blocked = restrictions.contains { restriction in
                    if restriction.branch_match_kind == "branching_model" { return restriction.branch_type == "production" }
                    guard let pattern = restriction.pattern else { return false }
                    return NSPredicate(format: "SELF LIKE %@", pattern).evaluate(with: branch)
                }
                return blocked ? .protected : .open
            } catch { return lookup(error) }
        }
    }
}
