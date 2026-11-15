import SwiftUI

/// «Crear…»: a new repository in a folder of this Mac, with `main` and a `.gitignore` as its first
/// commit and, optionally, `develop` to work on. Nothing leaves the Mac; it opens in the tool.
struct GitCreateRepositorySheet: View {
    let tool: GitTool
    @State private var name = ""
    @State private var parent = GitCloneSheet.defaultParent
    @State private var develop = true
    @State private var failure: String?

    private var target: String { (parent as NSString).appendingPathComponent(name) }
    private var isRepository: Bool { FileManager.default.fileExists(atPath: (target as NSString).appendingPathComponent(".git")) }

    var body: some View {
        SheetFrame(title: L("git.create.title"), symbol: Symbols.gitCreateRepository, detail: L("git.create.detail"),
                   note: failure ?? (isRepository ? String(format: L("git.create.exists"), name) : nil), width: 520, height: 340,
                   actionTitle: L("git.create.action"), actionSymbol: Symbols.gitCreateRepository, actionID: "git.create.run",
                   canAct: GitRepositoryName.valid(name) && !isRepository, cancelID: "git.create.cancel") {
            await create()
        } content: {
            Form {
                Section {
                    TextField(L("git.repo.folderName"), text: $name, prompt: Text(L("git.create.namePrompt")))
                        .accessibilityIdentifier("git.create.name")
                    GitFolderRow(parent: $parent, identifier: "git.create.folder")
                    Toggle(L("git.create.develop"), isOn: $develop).help(L("git.create.developHelp"))
                        .accessibilityIdentifier("git.create.develop")
                } footer: {
                    SettingsFooter(L("git.create.contents"))
                }
            }
            .formStyle(.grouped).themedScroll()
        }
    }

    private func create() async -> Bool {
        failure = nil
        do {
            try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
            let path: String = try await StackStore.shared.call(["method": "gitInit", "path": parent, "name": name, "develop": develop])
            await tool.add(path)
            StackStore.shared.notify(String(format: L("git.create.done"), name))
            return true
        } catch {
            let failure = GitFailure(error)
            self.failure = failure.detail.isEmpty ? failure.title : "\(failure.title): \(failure.detail)"
            return false
        }
    }
}

/// «Publicar repositorio…»: creates the repository on GitHub or Bitbucket (private unless the user
/// says otherwise), adds it as `origin` and sends the chosen branches. Creating something on the
/// provider is confirmed first. When `origin` already points to that repository (an earlier
/// attempt created it) it only sends the branches.
struct GitPublishRepositorySheet: View {
    let repository: GitRepository
    var hosting = GitHosting.shared
    @State private var provider: GitHostingProvider = .github
    @State private var owners: [String] = []
    @State private var owner = ""
    @State private var name = ""
    @State private var summary = ""
    @State private var isPrivate = true
    @State private var useSSH = true
    @State private var branches: Set<String> = []
    @State private var loading = false
    @State private var confirming = false
    @State private var working = false
    @State private var failure: String?
    @Environment(\.dismiss) private var dismiss

    private var connected: [GitHostingProvider] { hosting.connectedProviders }
    private var localBranches: [String] { repository.snapshot.branches.map(\.name) }
    private var slug: String { provider == .bitbucket ? name.lowercased() : name }
    /// `origin` already is this repository: only the branches are sent.
    private var resuming: Bool {
        guard let hosted = hosting.session(for: repository).hosted else { return false }
        return hosted.provider == provider && hosted.owner.caseInsensitiveCompare(owner) == .orderedSame && hosted.name.caseInsensitiveCompare(slug) == .orderedSame
    }
    private var valid: Bool { !owner.isEmpty && GitHostedRepository.validPart(name) && !branches.isEmpty && !working }

    var body: some View {
        SheetFrame(title: L("git.publish.title"), symbol: Symbols.gitPublishRepository, detail: L("git.publish.detail"),
                   note: failure ?? (connected.isEmpty ? nil : steps), width: 560, height: 560,
                   actionTitle: L("git.publish.actionEllipsis"), actionSymbol: Symbols.gitPublishRepository, actionID: "git.publish.run",
                   canAct: valid && !connected.isEmpty, cancelID: "git.publish.cancel") {
            confirming = true
            return false
        } content: {
            if connected.isEmpty {
                Notice(.info, L("git.publish.noAccount"), detail: L("git.publish.noAccountDetail")) {
                    Button { SettingsRouter.shared.open(.accounts) } label: { Label(L("git.pr.missing.openAccounts"), systemImage: Symbols.settings) }
                        .buttonStyle(.bordered).accessibilityIdentifier("git.publish.accounts")
                }
                Spacer(minLength: 0)
            } else {
                form
            }
        }
        .cancelling(nil, enabled: !working, help: L("git.publish.runningHelp"))
        .task { await start() }
        .confirmationDialog(String(format: L(resuming ? "git.publish.confirmPushTitle" : "git.publish.confirmTitle"), "\(owner)/\(slug)", provider.title),
                            isPresented: $confirming, titleVisibility: .visible) {
            Button(L("git.publish.confirm")) { Task { if await publish() { dismiss() } } }
                .accessibilityIdentifier("git.publish.confirmButton")
            Button(L("common.cancel"), role: .cancel) {}.accessibilityIdentifier("git.publish.confirmCancel")
        } message: {
            Text(resuming ? String(format: L("git.publish.confirmPushDetail"), branchList)
                 : String(format: L(isPrivate ? "git.publish.confirmPrivate" : "git.publish.confirmPublic"), branchList))
        }
    }

    private var branchList: String { localBranches.filter(branches.contains).joined(separator: ", ") }

    private var form: some View {
        Form {
            Picker(L("git.publish.provider"), selection: $provider) { ForEach(connected) { Text($0.title).tag($0) } }
                .onChange(of: provider) { Task { await loadOwners() } }
                .accessibilityIdentifier("git.publish.provider")
            Picker(L(provider == .bitbucket ? "git.publish.workspace" : "git.publish.owner"), selection: $owner) {
                ForEach(owners, id: \.self) { Text($0).tag($0) }
            }
            .disabled(loading)
            .accessibilityIdentifier("git.publish.owner")
            TextField(L("git.publish.name"), text: $name).accessibilityIdentifier("git.publish.name")
            TextField(L("git.publish.summary"), text: $summary, prompt: Text(L("git.publish.optional"))).accessibilityIdentifier("git.publish.summary")
            Toggle(L("git.publish.private"), isOn: $isPrivate).help(L("git.publish.privateHelp")).accessibilityIdentifier("git.publish.private")
            Picker(L("git.clone.protocol"), selection: $useSSH) {
                Text(L("git.clone.ssh")).tag(true)
                Text(L("git.clone.https")).tag(false)
            }
            .pickerStyle(.segmented).help(L("git.clone.protocolHelp")).accessibilityIdentifier("git.publish.protocol")
            Section(L("git.publish.branches")) {
                ForEach(localBranches, id: \.self) { branch in
                    Toggle(branch, isOn: Binding(get: { branches.contains(branch) }, set: { if $0 { branches.insert(branch) } else { branches.remove(branch) } }))
                        .accessibilityIdentifier("git.publish.branch.\(branch)")
                }
            }
        }
        .formStyle(.grouped).themedScroll()
    }

    /// What will happen, in order, under the form.
    private var steps: String? {
        guard !owner.isEmpty, !name.isEmpty else { return nil }
        let first = resuming ? String(format: L("git.publish.stepExisting"), provider.title, "\(owner)/\(slug)")
            : String(format: L(isPrivate ? "git.publish.stepCreatePrivate" : "git.publish.stepCreatePublic"), provider.title, "\(owner)/\(slug)")
        return first + " " + String(format: L("git.publish.stepPush"), branchList.isEmpty ? "—" : branchList)
    }

    private func start() async {
        if !hosting.accountsLoaded { await hosting.loadAccounts() }
        await hosting.session(for: repository).readRemote()
        name = repository.snapshot.name.replacingOccurrences(of: " ", with: "-")
        let snapshot = repository.snapshot
        branches = Set(localBranches.filter { $0 == snapshot.primaryBranch || $0 == "develop" || $0 == snapshot.branch })
        if let hosted = hosting.session(for: repository).hosted, connected.contains(hosted.provider) {
            provider = hosted.provider
            name = hosted.name
        } else if let first = connected.first {
            provider = first
        }
        await loadOwners()
    }

    private func loadOwners() async {
        guard hosting.account(for: provider) != nil else { owners = []; owner = ""; return }
        loading = true
        defer { loading = false }
        do {
            let credentials = try await hosting.credentials(for: provider)
            owners = try await hosting.client.owners(provider, credentials: credentials)
            if let hosted = hosting.session(for: repository).hosted, owners.contains(hosted.owner) { owner = hosted.owner }
            else if !owners.contains(owner) { owner = owners.first ?? "" }
            failure = nil
        } catch {
            owners = []
            owner = ""
            failure = (error as? GitHostingFailure)?.errorDescription
        }
    }

    /// Creates (or finds) the repository on the provider, then `gitPublish` adds `origin` and sends
    /// the branches without forcing. The protection of `main` is read afterwards.
    private func publish() async -> Bool {
        working = true
        failure = nil
        defer { working = false }
        do {
            let done = try await hosting.publish(repository, provider: provider, owner: owner, name: name, summary: summary, isPrivate: isPrivate,
                                                 useSSH: useSSH, branches: localBranches.filter(branches.contains), resuming: resuming)
            repository.store.notify(String(format: L("git.publish.done"), done.path, done.pushed.joined(separator: ", ")))
            return true
        } catch let failure as GitHostingFailure {
            self.failure = failure.errorDescription
        } catch {
            let failure = GitFailure(error)
            if !failure.cancelled { self.failure = failure.detail.isEmpty ? failure.title : "\(failure.title): \(failure.detail)" }
        }
        await repository.refresh()
        return false
    }
}

extension View {
    /// The clone, create and publish sheets of the Git tool, wherever the tool is on screen.
    func gitHostingSheets(tool: GitTool) -> some View { modifier(GitHostingSheets(tool: tool)) }
}

private struct GitHostingSheets: ViewModifier {
    let tool: GitTool
    @Bindable var hosting = GitHosting.shared

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $hosting.cloning) { GitCloneSheet(tool: tool).themedSheet() }
            .sheet(isPresented: $hosting.creating) { GitCreateRepositorySheet(tool: tool).themedSheet() }
            .sheet(isPresented: $hosting.publishing) {
                if let repository = tool.repository { GitPublishRepositorySheet(repository: repository).themedSheet() }
            }
            #if DEBUG
            .task { await GitHostingQA.start(tool) }
            #endif
    }
}
