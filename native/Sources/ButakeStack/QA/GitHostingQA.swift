#if DEBUG
import Foundation

/// GitHub and Bitbucket in a QA window without the real ones (debug builds with BUTAKE_QA_WINDOW
/// and a separate BUTAKE_STACK_HOME): a fake server on 127.0.0.1 (`GitHostingFakeServer`) and a
/// Keychain in memory. Nothing reaches a provider or the user's Keychain.
///
///     BUTAKE_QA_GIT_HOSTING=fake                    the fake server and a store in memory
///     BUTAKE_QA_GIT_HOSTING_ACCOUNTS=github,bitbucket   accounts already connected (made-up tokens)
///     BUTAKE_QA_GIT_HOSTING_REMOTES=<carpeta>       where repositories created on the server get their bare copy
///     BUTAKE_QA_GIT_CLONE_PARENT=<carpeta>          the folder «Clonar…» and «Crear…» propose
///     BUTAKE_QA_GIT_HOSTING_STEPS=<paso>;<paso>…    after the Git tool opens, in order:
///       clone  create  publish  newPR  pr:<número>  scope:<branch|open|merged|closed>  checks  load  open:<ruta>  wait:<segundos>
///       and, as the buttons do once confirmed: connect:<github|bitbucket>  createPR:<título>
///       cloneRun:<dirección>  publishRun:<dueño>/<nombre>
///     Every step writes «QA hosting: <paso> → <estado>» to the standard error.
@MainActor enum GitHostingQA {
    private static func value(_ name: String) -> String? {
        let env = ProcessInfo.processInfo.environment
        return StackStore.qaWindow && env["BUTAKE_STACK_HOME"] != nil ? env[name] : nil
    }

    /// The made-up tokens of the QA window's accounts (never a real one).
    static let tokens = ["github": "qa-ficha-inventada-github", "bitbucket": "qa-ficha-inventada-bitbucket"]
    private static var server: GitHostingFakeServer?

    static var cloneParent: String? { value("BUTAKE_QA_GIT_CLONE_PARENT") }

    /// The hosting of a QA window, or nil outside one.
    static func hosting() -> GitHosting? {
        guard value("BUTAKE_QA_GIT_HOSTING") == "fake" else { return nil }
        let remotes = value("BUTAKE_QA_GIT_HOSTING_REMOTES").map { URL(fileURLWithPath: $0) }
        guard let fake = try? GitHostingFakeServer(remotes: remotes, tokens: tokens) else { return nil }
        server = fake
        let items = MemoryKeychainItems()
        let vault = GitHostingVault(items: items)
        for provider in (value("BUTAKE_QA_GIT_HOSTING_ACCOUNTS") ?? "").split(separator: ",").compactMap({ GitHostingProvider(rawValue: String($0)) }) {
            let account = GitHostingAccount(provider: provider, login: "ana-qa", name: "Ana Prueba", email: provider.needsEmail ? fake.email : "")
            try? vault.save(account, credentials: GitHostingCredentials(email: account.email, token: tokens[provider.rawValue] ?? ""))
        }
        FileHandle.standardError.write(Data("QA hosting: servidor falso en 127.0.0.1:\(fake.port)\n".utf8))
        return GitHosting(endpoints: fake.endpoints, vault: vault)
    }

    private static var started = false

    static func start(_ tool: GitTool) async {
        guard !started, let script = value("BUTAKE_QA_GIT_HOSTING_STEPS") else { return }
        started = true
        // After the Git tool's own QA steps (GitQA) opened the repository.
        for _ in 0..<40 where tool.repository == nil { try? await Task.sleep(for: .milliseconds(250)) }
        for step in script.split(separator: ";").map(String.init) {
            await run(step, tool)
            report(step, tool)
        }
    }

    private static func run(_ step: String, _ tool: GitTool) async {
        let parts = step.split(separator: ":", maxSplits: 1).map(String.init)
        let argument = parts.count > 1 ? parts[1] : ""
        let hosting = GitHosting.shared
        switch parts[0] {
        case "wait": try? await Task.sleep(for: .seconds(Double(argument) ?? 1))
        case "open": await tool.open(argument)
        case "clone": hosting.cloning = true
        case "create": hosting.creating = true
        case "publish": hosting.publishing = true
        case "newPR": if let repository = tool.repository { hosting.session(for: repository).composing = true }
        case "pr": if let repository = tool.repository { hosting.session(for: repository).selected = Int(argument) }
        case "scope":
            if let repository = tool.repository, let scope = GitHostingSession.Scope(rawValue: argument) { hosting.session(for: repository).scope = scope }
        case "checks": if let repository = tool.repository { await hosting.session(for: repository).refreshBranchChecks() }
        case "load": if let repository = tool.repository { await hosting.session(for: repository).load() }
        // The end-to-end run, through the same calls the buttons make once confirmed.
        case "connect":
            guard let provider = GitHostingProvider(rawValue: argument) else { return }
            _ = try? await hosting.connect(provider, email: server?.email ?? "", token: tokens[argument] ?? "")
        case "createPR":
            guard let repository = tool.repository else { return }
            _ = await hosting.session(for: repository).create(title: argument, body: "", target: repository.snapshot.primaryBranch, draft: false)
        case "cloneRun":
            guard let parent = cloneParent, let path = try? await hosting.clone(url: argument, parent: parent, name: GitCloneSheet.folderName(argument),
                                                                                 store: StackStore.shared) else { return }
            await tool.add(path)
        case "publishRun":
            let target = argument.split(separator: "/").map(String.init)
            guard let repository = tool.repository, target.count == 2 else { return }
            _ = try? await hosting.publish(repository, provider: .github, owner: target[0], name: target[1], summary: "", isPrivate: true, useSSH: false,
                                           branches: repository.snapshot.branches.map(\.name), resuming: false)
        default: break
        }
    }

    private static func report(_ step: String, _ tool: GitTool) {
        let hosting = GitHosting.shared
        var line = "QA hosting: \(step) → cuentas=\(hosting.accounts.map(\.id).joined(separator: ","))"
        if let repository = tool.repository {
            let session = hosting.session(for: repository)
            line += " pr=\(session.pullRequests.map { "#\($0.id)" }.joined(separator: ",")) elegido=\(session.selected.map(String.init) ?? "-")"
            line += " checks=\(session.branchChecks.map { "\($0.name):\($0.state.rawValue)" }.joined(separator: ","))"
            line += " problemas=\(GitHostingProblems.current(for: repository).map(\.title).joined(separator: " | "))"
            line += " remoto=\(session.remote) error=\(session.failure?.code.rawValue ?? "-") repositorio=\(repository.root)"
        }
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
}
#endif
