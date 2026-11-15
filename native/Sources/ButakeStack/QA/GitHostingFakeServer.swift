#if DEBUG
import Foundation
import Network

/// A made-up GitHub and Bitbucket Cloud on this Mac's loopback address, for tests and QA windows:
/// the same paths and JSON as the real APIs (only what the tool uses), invented accounts,
/// repositories, pull requests and checks, and a bare Git repository per hosted repository in
/// `remotes` (a clone address `https://<host>/<owner>/<name>.git` reaches it through Git's
/// `url.<carpeta>.insteadOf`, set in a temporary configuration). Nothing goes to the network.
final class GitHostingFakeServer: @unchecked Sendable {
    /// A request as it arrived (tests check where the token went).
    struct Request: Sendable {
        let method: String
        let provider: String
        let path: String
        let authorization: String?
        let raw: String
    }

    struct Pull {
        var number: Int; var title: String; var body: String; var state: String; var draft: Bool; var author: String
        var source: String; var target: String; var head: String; var updated: String
        var comments: [(id: Int, author: String, body: String, path: String?, line: Int?)] = []
        var reviews: [(author: String, state: String)] = []
    }
    struct Repo {
        var owner: String; var name: String; var isPrivate: Bool; var summary: String
        var pulls: [Pull] = []
        var protectedBranches: Set<String> = []
    }

    let port: UInt16
    let remotes: URL?
    /// The token each provider accepts, and Bitbucket's email.
    let tokens: [String: String]
    let email: String
    private let listener: NWListener
    /// Hands new connections to the server once it is built.
    private final class Relay: @unchecked Sendable { weak var server: GitHostingFakeServer? }
    private let relay: Relay
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var repos: [String: Repo] = [:]
    private var checks: [String: [(name: String, state: String)]] = [:]
    private var log: [Request] = []
    private var counter = 100

    /// Starts on a free port of 127.0.0.1 and waits until it listens.
    init(remotes: URL? = nil, tokens: [String: String], email: String = "ana@example.invalid") throws {
        self.remotes = remotes
        self.tokens = tokens
        self.email = email
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in if case .ready = state { ready.signal() } else if case .failed = state { ready.signal() } }
        let relay = Relay()
        self.relay = relay
        listener.newConnectionHandler = { connection in relay.server?.serve(connection) }
        let queue = DispatchQueue(label: "cl.butake.stack.qa.fakehosting")
        self.queue = queue
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
        guard let port = listener.port?.rawValue else { throw URLError(.cannotConnectToHost) }
        self.port = port
        relay.server = self
        seed()
    }

    func stop() { listener.cancel() }

    var endpoints: GitHostingEndpoints { .loopback(port: port) }
    var requests: [Request] { lock.withLock { log } }

    /// A hosted repository's bare copy in `remotes`.
    func bare(_ owner: String, _ name: String) -> URL? { remotes?.appendingPathComponent("\(owner)/\(name).git") }

    /// The checks a commit shows (`success`, `failure`, `pending`).
    func setChecks(_ commit: String, _ list: [(name: String, state: String)]) { lock.withLock { checks[commit] = list } }
    func repo(_ provider: String, _ path: String) -> Repo? { lock.withLock { repos["\(provider):\(path)"] } }

    // MARK: Seed

    /// Invented data: «acme/tienda» with two open pull requests (one with a failed check) on both
    /// providers, more repositories to clone and an organization or workspace to publish into.
    private func seed() {
        let head = String(repeating: "a1", count: 20)
        for provider in ["github", "bitbucket"] {
            var tienda = Repo(owner: "acme", name: "tienda", isPrivate: true, summary: "Tienda en línea de prueba", protectedBranches: ["main"])
            var pagos = Pull(number: 7, title: "Pagos con tarjeta", body: "Agrega el pago con **tarjeta** y la página de recibo.", state: "open", draft: false,
                             author: "bruno-qa", source: "feature/pagos", target: "main", head: head, updated: "2026-11-13T15:20:00Z")
            pagos.comments = [(1, "carla-qa", "¿Podemos mostrar el total con impuestos?", nil, nil),
                              (2, "bruno-qa", "Listo, quedó en el resumen.", "src/recibo.ts", 12)]
            pagos.reviews = [("carla-qa", "CHANGES_REQUESTED")]
            tienda.pulls = [pagos,
                            Pull(number: 5, title: "Corrige el menú en pantallas chicas", body: "", state: "open", draft: true, author: "carla-qa",
                                 source: "fix/menu", target: "main", head: String(repeating: "b2", count: 20), updated: "2026-11-12T10:00:00Z"),
                            Pull(number: 3, title: "Primera versión del catálogo", body: "Catálogo con filtros.", state: "merged", draft: false, author: "ana-qa",
                                 source: "feature/catalogo", target: "main", head: String(repeating: "c3", count: 20), updated: "2026-11-01T09:00:00Z")]
            repos["\(provider):acme/tienda"] = tienda
            repos["\(provider):acme/sitio-web"] = Repo(owner: "acme", name: "sitio-web", isPrivate: false, summary: "Sitio público")
            repos["\(provider):ana-qa/notas"] = Repo(owner: "ana-qa", name: "notas", isPrivate: true, summary: "")
        }
        checks[head] = [("build", "failure"), ("lint", "success"), ("tests", "pending")]
        checks[String(repeating: "b2", count: 20)] = [("build", "success")]
    }

    // MARK: HTTP

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
                let length = head.split(separator: "\r\n").first { $0.lowercased().hasPrefix("content-length:") }
                    .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
                let body = buffer[end.upperBound...]
                if body.count >= length {
                    let (status, json) = self.handle(head: head, body: Data(body.prefix(length)))
                    let payload = (try? JSONSerialization.data(withJSONObject: json)) ?? Data("{}".utf8)
                    var response = Data("HTTP/1.1 \(status) X\r\nContent-Type: application/json\r\nContent-Length: \(payload.count)\r\nConnection: close\r\n\r\n".utf8)
                    response.append(payload)
                    connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
                    return
                }
            }
            if complete || error != nil { connection.cancel(); return }
            self.receive(connection, buffer: buffer)
        }
    }

    private func handle(head: String, body: Data) -> (Int, Any) {
        let lines = head.split(separator: "\r\n").map(String.init)
        let first = lines.first?.split(separator: " ").map(String.init) ?? []
        guard first.count >= 2 else { return (400, [:]) }
        let method = first[0]
        let target = first[1]
        let authorization = lines.first { $0.lowercased().hasPrefix("authorization:") }.map { String($0.dropFirst("authorization:".count)).trimmingCharacters(in: .whitespaces) }
        let pathAndQuery = target.split(separator: "?", maxSplits: 1).map(String.init)
        let parts = pathAndQuery[0].split(separator: "/").map(String.init)
        let query = Dictionary((pathAndQuery.count > 1 ? pathAndQuery[1] : "").split(separator: "&").compactMap { pair -> (String, String)? in
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            return kv.count == 2 ? (kv[0], kv[1].removingPercentEncoding ?? kv[1]) : nil
        }, uniquingKeysWith: { $1 })
        guard let provider = parts.first, ["github", "bitbucket"].contains(provider) else { return (404, ["message": "Not Found"]) }
        let path = Array(parts.dropFirst())
        lock.withLock { log.append(Request(method: method, provider: provider, path: path.joined(separator: "/"), authorization: authorization, raw: head)) }
        let expected = provider == "github" ? "Bearer \(tokens[provider] ?? "")" : "Basic " + Data("\(email):\(tokens[provider] ?? "")".utf8).base64EncodedString()
        guard authorization == expected else { return (401, provider == "github" ? ["message": "Bad credentials"] : ["error": ["message": "Unauthorized"]]) }
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        return lock.withLock { provider == "github" ? github(method, path, query, json) : bitbucket(method, path, query, json) }
    }
}

// MARK: - Routes (called with the lock held)

extension GitHostingFakeServer {
    private func web(_ provider: String) -> String { endpoints.webHost(provider == "github" ? .github : .bitbucket) }

    private func ghRepo(_ repo: Repo) -> [String: Any] {
        ["full_name": "\(repo.owner)/\(repo.name)", "ssh_url": "git@\(web("github")):\(repo.owner)/\(repo.name).git",
         "clone_url": "https://\(web("github"))/\(repo.owner)/\(repo.name).git", "private": repo.isPrivate, "description": repo.summary,
         "updated_at": "2026-11-10T12:00:00Z"]
    }
    private func bbRepo(_ repo: Repo) -> [String: Any] {
        ["full_name": "\(repo.owner)/\(repo.name)", "is_private": repo.isPrivate, "description": repo.summary, "updated_on": "2026-11-10T12:00:00.123456+00:00",
         "links": ["clone": [["name": "https", "href": "https://ana-qa@\(web("bitbucket"))/\(repo.owner)/\(repo.name).git"],
                             ["name": "ssh", "href": "git@\(web("bitbucket")):\(repo.owner)/\(repo.name).git"]]]]
    }
    private func ghPull(_ repo: Repo, _ pull: Pull) -> [String: Any] {
        ["number": pull.number, "title": pull.title, "body": pull.body, "state": pull.state == "open" ? "open" : "closed", "draft": pull.draft,
         "user": ["login": pull.author], "head": ["ref": pull.source, "sha": pull.head], "base": ["ref": pull.target],
         "html_url": "https://\(web("github"))/\(repo.owner)/\(repo.name)/pull/\(pull.number)", "updated_at": pull.updated,
         "merged_at": pull.state == "merged" ? pull.updated : NSNull()]
    }
    private func bbPull(_ repo: Repo, _ pull: Pull) -> [String: Any] {
        ["id": pull.number, "title": pull.title, "description": pull.body, "state": ["open": "OPEN", "merged": "MERGED"][pull.state] ?? "DECLINED",
         "draft": pull.draft, "author": ["display_name": pull.author], "updated_on": pull.updated,
         "source": ["branch": ["name": pull.source], "commit": ["hash": pull.head]], "destination": ["branch": ["name": pull.target]],
         "links": ["html": ["href": "https://\(web("bitbucket"))/\(repo.owner)/\(repo.name)/pull-requests/\(pull.number)"]]]
    }

    /// Creates the hosted repository and its bare copy.
    private func create(_ provider: String, owner: String, name: String, isPrivate: Bool, summary: String) -> Repo? {
        let key = "\(provider):\(owner)/\(name)"
        guard repos[key] == nil, GitHostedRepository.validPart(owner), GitHostedRepository.validPart(name) else { return nil }
        let repo = Repo(owner: owner, name: name, isPrivate: isPrivate, summary: summary)
        repos[key] = repo
        if let bare = bare(owner, name) {
            try? FileManager.default.createDirectory(at: bare, withIntermediateDirectories: true)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["init", "-q", "--bare", "-b", "main", bare.path]
            try? process.run()
            process.waitUntilExit()
        }
        return repo
    }

    private func newPull(_ key: String, title: String, body: String, source: String, target: String, draft: Bool, author: String) -> Pull? {
        guard var repo = repos[key], !source.isEmpty, !repo.pulls.contains(where: { $0.source == source && $0.state == "open" }) else { return nil }
        counter += 1
        let pull = Pull(number: counter, title: title, body: body, state: "open", draft: draft, author: author, source: source, target: target,
                        head: String(repeating: "d4", count: 20), updated: "2026-11-14T12:00:00Z")
        repo.pulls.insert(pull, at: 0)
        repos[key] = repo
        return pull
    }

    private func update(_ key: String, _ number: Int, _ change: (inout Pull) -> Void) -> Bool {
        guard var repo = repos[key], let index = repo.pulls.firstIndex(where: { $0.number == number }) else { return false }
        change(&repo.pulls[index])
        repos[key] = repo
        return true
    }

    /// The path with its variable parts named: numbers as «#», commit hashes as «SHA».
    private func shape(_ path: [String]) -> String {
        path.map { part in
            if !part.isEmpty, part.allSatisfy(\.isNumber) { return "#" }
            if part.count == 40, part.allSatisfy(\.isHexDigit) { return "SHA" }
            return part
        }
        .joined(separator: "/")
    }

    private func github(_ method: String, _ path: [String], _ query: [String: String], _ json: [String: Any]) -> (Int, Any) {
        let me = "ana-qa"
        let notFound: (Int, Any) = (404, ["message": "Not Found"])
        let first = query["page"] == nil || query["page"] == "1"
        switch "\(method) \(path.joined(separator: "/"))" {
        case "GET user": return (200, ["login": me, "name": "Ana Prueba"])
        case "GET user/orgs": return (200, first ? [["login": "acme"]] : [])
        case "GET user/repos":
            return (200, first ? repos.filter { $0.key.hasPrefix("github:") }.values.sorted { $0.name < $1.name }.map(ghRepo) : [])
        default: break
        }
        if method == "POST", path == ["user", "repos"] || (path.count == 3 && path[0] == "orgs" && path[2] == "repos") {
            let owner = path[0] == "user" ? me : path[1]
            guard let repo = create("github", owner: owner, name: json["name"] as? String ?? "", isPrivate: json["private"] as? Bool ?? true,
                                    summary: json["description"] as? String ?? "") else { return (422, ["message": "name already exists on this account"]) }
            return (201, ghRepo(repo))
        }
        guard path.count >= 3, path[0] == "repos", let repo = repos["github:\(path[1])/\(path[2])"] else { return notFound }
        let key = "github:\(path[1])/\(path[2])"
        let rest = Array(path.dropFirst(3))
        let number = Int(rest.count > 1 ? rest[1] : "") ?? 0
        let pull = repo.pulls.first { $0.number == number }
        if method == "GET", rest.first == "branches" {
            return (200, ["protected": repo.protectedBranches.contains(rest.dropFirst().joined(separator: "/"))])
        }
        if method == "GET", rest.first == "rules" { return (200, [Any]()) }
        switch "\(method) \(shape(rest))" {
        case "GET ": return (200, ghRepo(repo))
        case "GET pulls":
            let open = query["state"] != "closed"
            return (200, repo.pulls.filter { ($0.state == "open") == open }.map { ghPull(repo, $0) })
        case "POST pulls":
            guard let created = newPull(key, title: json["title"] as? String ?? "", body: json["body"] as? String ?? "", source: json["head"] as? String ?? "",
                                        target: json["base"] as? String ?? "", draft: json["draft"] as? Bool ?? false, author: me)
            else { return (422, ["message": "A pull request already exists"]) }
            return (201, ghPull(repo, created))
        case "GET issues/#/comments":
            let items = first ? (pull?.comments.filter { $0.path == nil } ?? []) : []
            return (200, items.map { ["id": $0.id, "user": ["login": $0.author], "body": $0.body, "created_at": "2026-11-13T16:00:00Z"] })
        case "GET pulls/#/comments":
            let items = first ? (pull?.comments.filter { $0.path != nil } ?? []) : []
            return (200, items.map { ["id": $0.id, "user": ["login": $0.author], "body": $0.body, "created_at": "2026-11-13T17:00:00Z",
                                      "path": $0.path ?? "", "line": $0.line ?? 0] })
        case "POST issues/#/comments":
            let text = json["body"] as? String ?? ""
            return update(key, number) { $0.comments.append((Int.random(in: 1_000...9_999), me, text, nil, nil)) } ? (201, ["id": 1]) : notFound
        case "GET pulls/#/reviews":
            return (200, (first ? pull?.reviews ?? [] : []).map { ["user": ["login": $0.author], "state": $0.state] })
        case "POST pulls/#/reviews":
            return update(key, number) { $0.reviews.append((me, "APPROVED")) } ? (200, ["id": 1]) : notFound
        case "PUT pulls/#/merge":
            return update(key, number) { $0.state = "merged" } ? (200, ["merged": true]) : notFound
        case "GET commits/SHA/check-runs":
            let runs = (checks[rest[1]] ?? []).enumerated().map { index, check -> [String: Any] in
                ["id": index + 1, "name": check.name, "status": check.state == "pending" ? "in_progress" : "completed",
                 "conclusion": check.state == "pending" ? NSNull() : check.state, "html_url": "https://\(web("github"))/\(repo.owner)/\(repo.name)/runs/\(index + 1)"]
            }
            return (200, ["check_runs": runs])
        default: return notFound
        }
    }

    private func bitbucket(_ method: String, _ path: [String], _ query: [String: String], _ json: [String: Any]) -> (Int, Any) {
        func page(_ values: [Any]) -> [String: Any] { ["values": query["page"] == "1" || query["page"] == nil ? values : []] }
        let notFound: (Int, Any) = (404, ["error": ["message": "Not found"]])
        switch "\(method) \(path.joined(separator: "/"))" {
        case "GET user": return (200, ["username": "ana-qa", "display_name": "Ana Prueba"])
        case "GET user/workspaces": return (200, page([["workspace": ["slug": "acme"]], ["workspace": ["slug": "ana-qa"]]]))
        default: break
        }
        if method == "GET", path.count == 2, path[0] == "repositories" {
            return (200, page(repos.filter { $0.key.hasPrefix("bitbucket:\(path[1])/") }.values.sorted { $0.name < $1.name }.map(bbRepo)))
        }
        if method == "POST", path.count == 3, path[0] == "repositories" {
            guard let repo = create("bitbucket", owner: path[1], name: path[2], isPrivate: json["is_private"] as? Bool ?? true, summary: json["description"] as? String ?? "")
            else { return (400, ["error": ["message": "Repository with this Slug and Owner already exists."]]) }
            return (200, bbRepo(repo))
        }
        guard path.count >= 3, path[0] == "repositories", let repo = repos["bitbucket:\(path[1])/\(path[2])"] else { return notFound }
        let key = "bitbucket:\(path[1])/\(path[2])"
        let rest = Array(path.dropFirst(3))
        let number = Int(rest.count > 1 ? rest[1] : "") ?? 0
        let pull = repo.pulls.first { $0.number == number }
        switch "\(method) \(shape(rest))" {
        case "GET ": return (200, bbRepo(repo))
        case "GET pullrequests":
            let state = ["OPEN": "open", "MERGED": "merged", "DECLINED": "closed"][query["state"] ?? "OPEN"] ?? "open"
            return (200, ["values": repo.pulls.filter { $0.state == state }.map { bbPull(repo, $0) }])
        case "POST pullrequests":
            let source = ((json["source"] as? [String: Any])?["branch"] as? [String: Any])?["name"] as? String ?? ""
            let target = ((json["destination"] as? [String: Any])?["branch"] as? [String: Any])?["name"] as? String ?? ""
            guard let created = newPull(key, title: json["title"] as? String ?? "", body: json["description"] as? String ?? "", source: source, target: target,
                                        draft: json["draft"] as? Bool ?? false, author: "Ana Prueba")
            else { return (400, ["error": ["message": "There are no changes to be pulled"]]) }
            return (201, bbPull(repo, created))
        case "GET pullrequests/#":
            return (200, ["participants": (pull?.reviews ?? []).map { ["user": ["display_name": $0.author], "approved": $0.state == "APPROVED",
                                                                       "state": $0.state == "APPROVED" ? "approved" : "changes_requested"] }])
        case "GET pullrequests/#/comments":
            return (200, page((pull?.comments ?? []).map { comment -> [String: Any] in
                var value: [String: Any] = ["id": comment.id, "user": ["display_name": comment.author], "content": ["raw": comment.body],
                                            "created_on": "2026-11-13T16:00:00.000000+00:00"]
                if let path = comment.path { value["inline"] = ["path": path, "to": comment.line ?? 0] }
                return value
            }))
        case "POST pullrequests/#/comments":
            let text = (json["content"] as? [String: Any])?["raw"] as? String ?? ""
            return update(key, number) { $0.comments.append((Int.random(in: 1_000...9_999), "Ana Prueba", text, nil, nil)) } ? (201, ["id": 1]) : notFound
        case "POST pullrequests/#/approve":
            return update(key, number) { $0.reviews.append(("Ana Prueba", "APPROVED")) } ? (200, ["approved": true]) : notFound
        case "POST pullrequests/#/merge":
            return update(key, number) { $0.state = "merged" } ? (200, ["state": "MERGED"]) : notFound
        case "GET commit/SHA/statuses":
            return (200, page((checks[rest[1]] ?? []).map { check -> [String: Any] in
                ["key": check.name, "name": check.name, "state": ["success": "SUCCESSFUL", "failure": "FAILED", "pending": "INPROGRESS"][check.state] ?? "STOPPED",
                 "url": "https://\(web("bitbucket"))/\(repo.owner)/\(repo.name)/pipelines"]
            }))
        case "GET branch-restrictions":
            return (200, page(repo.protectedBranches.map { ["kind": "push", "pattern": $0, "branch_match_kind": "glob"] }))
        default: return notFound
        }
    }
}
#endif
