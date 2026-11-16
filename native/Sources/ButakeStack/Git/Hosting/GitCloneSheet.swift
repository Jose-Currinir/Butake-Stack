import AppKit
import SwiftUI

/// «Clonar…»: a repository of a connected account (searched in a list) or any address
/// (https://, ssh:// or git@servidor:ruta), into a folder of this Mac; the new repository opens
/// in the tool. Over HTTPS, a repository of a connected account is cloned with its token; over
/// SSH, with the Mac's keys (`GitCloneAccessNotice` says what is missing).
struct GitCloneSheet: View {
    let tool: GitTool
    var hosting = GitHosting.shared
    enum Source: String, CaseIterable, Identifiable { case account, address; var id: String { rawValue } }

    @State private var source: Source = .account
    @State private var provider: GitHostingProvider = .github
    @State private var repositories: [GitHostingRemoteRepository] = []
    @State private var loading = false
    @State private var search = ""
    @State private var chosen: GitHostingRemoteRepository.ID?
    /// HTTPS works as soon as the account is connected; SSH stays chosen once the user picks it.
    @AppStorage("git.cloneSSH") private var useSSH = false
    @State private var address = ""
    @State private var parent = GitCloneSheet.defaultParent
    @State private var name = ""
    @State private var failure: String?
    @State private var running: Task<Bool, Never>?
    /// What an SSH address still needs on this Mac, and the code of a clone refused for access.
    @State private var access: GitSSHAccess?
    @State private var refused: String?
    /// How many notices about that access show: the sheet grows with them over the list.
    @State private var accessNotices = 0

    /// The folder chosen for clones, when the user brought it from the former app.
    static let parentKey = "git.cloneParent"

    static var defaultParent: String {
        #if DEBUG
        if let folder = GitHostingQA.cloneParent { return folder }
        #endif
        if let folder = UserDefaults.standard.string(forKey: parentKey), FileManager.default.fileExists(atPath: folder) { return folder }
        return Folder.projects
    }

    private var repository: GitHostingRemoteRepository? { repositories.first { $0.id == chosen } }
    private var url: String {
        switch source {
        case .account: repository.map { useSSH ? $0.ssh : $0.https } ?? ""
        case .address: address.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
    private var shown: [GitHostingRemoteRepository] {
        repositories.filter { search.isEmpty || $0.fullName.localizedCaseInsensitiveContains(search) || $0.summary.localizedCaseInsensitiveContains(search) }
    }
    private var target: String { (parent as NSString).appendingPathComponent(name) }
    private var exists: Bool { !name.isEmpty && FileManager.default.fileExists(atPath: target) }
    private var canClone: Bool { !url.isEmpty && GitRepositoryName.valid(name) && !exists && running == nil && access?.blocked != true }

    var body: some View {
        SheetFrame(title: L("git.clone.title"), symbol: Symbols.gitClone, detail: L("git.clone.detail"),
                   note: failure ?? (exists ? String(format: L("git.clone.exists"), name) : nil), width: 600,
                   height: 640 + (source == .account ? CGFloat(accessNotices) * 92 : 0),
                   actionTitle: L("git.clone.action"), actionSymbol: Symbols.gitClone, actionID: "git.clone.run",
                   canAct: canClone, cancelID: "git.clone.cancel") {
            await clone()
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                Picker(L("git.clone.source"), selection: $source) {
                    ForEach(Source.allCases) { Text(L("git.clone.source.\($0.rawValue)")).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
                .accessibilityIdentifier("git.clone.source")
                if source == .account { accountList } else {
                    TextField(L("git.clone.address"), text: $address, prompt: Text(L("git.clone.addressPrompt")))
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("git.clone.address")
                }
                GitCloneAccessNotice(url: url, access: access, refused: refused, refresh: { await readAccess() },
                                     useSSH: source == .account && !useSSH ? { useSSH = true } : nil, shown: $accessNotices, hosting: hosting)
                Form {
                    if source == .account {
                        Picker(L("git.clone.protocol"), selection: $useSSH) {
                            Text(L("git.clone.ssh")).tag(true)
                            Text(L("git.clone.https")).tag(false)
                        }
                        .pickerStyle(.segmented).help(L("git.clone.protocolHelp"))
                        .accessibilityIdentifier("git.clone.protocol")
                    }
                    GitFolderRow(parent: $parent, identifier: "git.clone.folder")
                    TextField(L("git.repo.folderName"), text: $name).accessibilityIdentifier("git.clone.name")
                }
                .formStyle(.grouped).themedScroll().scrollDisabled(true).frame(height: source == .account ? 210 : 160)
            }
        }
        .cancelling(running.map { task in { task.cancel() } }, help: L("git.clone.cancelHelp"))
        .task { await start() }
        .task(id: url) {
            // Typing an address: wait for it to settle before asking the engine.
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            refused = nil
            await readAccess()
        }
        .onChange(of: provider) { Task { await loadRepositories() } }
        .onChange(of: chosen) { if let repository { name = Self.folderName(repository.fullName) } }
        .onChange(of: address) { if source == .address { name = Self.folderName(address) } }
    }

    @ViewBuilder private var accountList: some View {
        let connected = hosting.connectedProviders
        if connected.isEmpty {
            Notice(.info, L("git.clone.noAccount"), detail: L("git.clone.noAccountDetail")) {
                Button { SettingsRouter.shared.open(.accounts) } label: { Label(L("git.pr.missing.openAccounts"), systemImage: Symbols.settings) }
                    .buttonStyle(.bordered).accessibilityIdentifier("git.clone.accounts")
            }
        } else {
            HStack {
                if connected.count > 1 {
                    Picker(L("git.publish.provider"), selection: $provider) { ForEach(connected) { Text($0.title).tag($0) } }
                        .labelsHidden().fixedSize().accessibilityIdentifier("git.clone.provider")
                }
                FilterField(text: $search, identifier: "git.clone.search", prompt: L("git.clone.search"))
            }
            List(shown, selection: $chosen) { repository in
                HStack(spacing: 8) {
                    Image(systemName: repository.isPrivate ? Symbols.locked : Symbols.address).foregroundStyle(.secondary).frame(width: 16)
                        .help(L(repository.isPrivate ? "git.clone.private" : "git.clone.public"))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(repository.fullName).lineLimit(1).truncationMode(.middle)
                        if !repository.summary.isEmpty { Text(repository.summary).font(.uiCaption).foregroundStyle(.secondary).lineLimit(1) }
                    }
                    Spacer()
                    if let updated = repository.updated {
                        Text(updated.formatted(.relative(presentation: .named))).font(.uiCaption).foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("git.clone.repo.\(repository.fullName)")
            }
            .listStyle(.bordered)
            .frame(minHeight: 160)
            .overlay {
                if loading { ProgressView() } else if shown.isEmpty {
                    if search.isEmpty { ContentUnavailableView(L("git.clone.none"), systemImage: Symbols.gitClone) } else { ContentUnavailableView.search(text: search) }
                }
            }
            .accessibilityIdentifier("git.clone.list")
        }
    }

    private func readAccess() async {
        let asked = url
        let found = asked.isEmpty ? nil : await hosting.sshAccess(url: asked, store: StackStore.shared)
        if asked == url { access = found }
    }

    private func start() async {
        #if DEBUG
        if let typed = GitHostingQA.cloneAddress, typed != "first" { source = .address; address = typed; return }
        #endif
        if !hosting.accountsLoaded { await hosting.loadAccounts() }
        if let first = hosting.connectedProviders.first { provider = first } else { source = .address }
        await loadRepositories()
        #if DEBUG
        if GitHostingQA.cloneAddress == "first" { chosen = repositories.first?.id }
        #endif
    }

    private func loadRepositories() async {
        guard hosting.account(for: provider) != nil else { repositories = []; return }
        loading = true
        defer { loading = false }
        do {
            let credentials = try await hosting.credentials(for: provider)
            repositories = try await hosting.client.repositories(provider, credentials: credentials)
            failure = nil
        } catch {
            repositories = []
            failure = (error as? GitHostingFailure)?.errorDescription ?? EngineFailure.message(error)
        }
    }

    /// Clones (stoppable) and opens the new repository; false keeps the sheet with the reason.
    private func clone() async -> Bool {
        failure = nil
        refused = nil
        let store = StackStore.shared
        let (url, parent, name) = (self.url, self.parent, self.name)
        let task = Task<Bool, Never> {
            do {
                let path = try await hosting.clone(url: url, parent: parent, name: name, store: store)
                await tool.add(path)
                store.notify(String(format: L("git.clone.done"), (path as NSString).lastPathComponent))
                return true
            } catch {
                let failure = GitFailure(error)
                if !failure.cancelled { self.failure = failure.detail.isEmpty ? failure.title : "\(failure.title): \(failure.detail)" }
                if ["clone_host_unknown", "clone_ssh_denied", "clone_auth"].contains(failure.code) {
                    refused = failure.code
                    await readAccess()
                }
                return false
            }
        }
        running = task
        let done = await task.value
        running = nil
        return done
    }

    /// The folder a clone gets: the last part of the address without «.git».
    static func folderName(_ url: String) -> String {
        let tail = url.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .split(whereSeparator: { $0 == "/" || $0 == ":" }).last.map(String.init) ?? ""
        return tail.hasSuffix(".git") ? String(tail.dropLast(4)) : tail
    }
}

/// Folder names the engine accepts for a new repository (the engine has the last word).
enum GitRepositoryName {
    static func valid(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 200 && !name.hasPrefix("-") && !name.hasPrefix(".") && !name.contains("/") && !name.contains("\\")
            && name.rangeOfCharacter(from: .controlCharacters) == nil
    }
}

/// The folder where something is created, with «Elegir…».
struct GitFolderRow: View {
    @Binding var parent: String
    let identifier: String
    var body: some View {
        LabeledContent(L("git.repo.folder")) {
            HStack {
                Text(parent.replacingOccurrences(of: NSHomeDirectory(), with: "~")).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).help(parent)
                Button { choose() } label: { Label(L("git.repo.chooseFolder"), systemImage: Symbols.folder) }
                    .accessibilityIdentifier(identifier)
            }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: parent)
        panel.prompt = L("git.repo.chooseFolder")
        if panel.runModal() == .OK, let url = panel.url { parent = url.path }
    }
}
