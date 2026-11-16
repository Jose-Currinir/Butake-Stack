import AppKit
import SwiftUI

/// The Git tool's detail: the selected tab's detail for the open repository, or why there is none
/// (Git missing, no repositories, nothing chosen). Its toolbar holds the branch and the primary sync
/// button; what is shown is chosen in the repository's sidebar, in the content column (`GitSidebar`).
struct GitPage: View {
    @Bindable var store: StackStore
    @Bindable var tool = GitTool.shared
    /// The tab on screen, kept with the window.
    @SceneStorage("git.tab") private var savedTab = GitTab.changes.rawValue
    /// A narrow detail: the toolbar's actions show their symbols only, so they stay over it.
    @State private var narrow = false

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onGeometryChange(for: Bool.self) { $0.size.width < 860 } action: { narrow = $0 }
            .toolbar {
                if tool.requirement.ready, let repository = tool.repository {
                    GitToolbar(repository: repository, compact: narrow)
                }
            }
            .focusedSceneValue(\.gitCommands, tool.requirement.ready && tool.repository != nil ? GitCommands(tool: tool) : nil)
            .task {
                if let tab = GitTab(rawValue: savedTab) { tool.tab = tab }
                GitMigration.shared.check()
                await tool.load()
                #if DEBUG
                await GitQA.start(tool)
                #endif
            }
            .onChange(of: tool.tab) { savedTab = tool.tab.rawValue }
            .gitHostingSheets(tool: tool)
            .gitMigrationSheet(in: .tool)
            .sheet(isPresented: $tool.showingDictionary) { GitDictionarySheet().themedSheet() }
            .alert(tool.repository?.failure?.title ?? tool.openFailure?.title ?? "", isPresented: failureShown) {
                Button(L("common.close"), role: .cancel) { clearFailure() }.accessibilityIdentifier("git.failure.close")
            } message: {
                Text(tool.repository?.failure?.detail ?? tool.openFailure?.detail ?? "")
            }
            .sheet(item: Binding(get: { tool.repository?.pullProblem }, set: { tool.repository?.pullProblem = $0 })) { problem in
                if let repository = tool.repository { GitPullAssistantSheet(repository: repository, problem: problem).themedSheet() }
            }
    }

    private var failureShown: Binding<Bool> {
        Binding(get: { tool.repository?.failure != nil || tool.openFailure != nil }, set: { if !$0 { clearFailure() } })
    }

    private func clearFailure() {
        tool.repository?.failure = nil
        tool.openFailure = nil
    }

    @ViewBuilder private var content: some View {
        switch tool.requirement {
        case .checking:
            ProgressView()
        case .missing, .outdated:
            GitRequirementView(store: store, tool: tool)
        case .ready:
            if let repository = tool.repository {
                GitWorkspace(tab: tool.tab, repository: repository).id(repository.root)
                    .gitBranchDialogs(repository: repository)
            } else if !tool.loaded || tool.opening != nil {
                ProgressView()
            } else {
                GitNoRepositoryView(tool: tool)
            }
        }
    }
}

/// Git is missing or too old: what to do, and Utilidades › Repositorios, where it is installed.
struct GitRequirementView: View {
    let store: StackStore
    let tool: GitTool
    var body: some View {
        let outdated: String? = if case .outdated(let version) = tool.requirement { version } else { nil }
        ContentUnavailableView {
            Label(L(outdated == nil ? "git.requirement.missing" : "git.requirement.outdated"), systemImage: Symbols.git)
        } description: {
            Text(outdated.map { String(format: L("git.requirement.outdatedDetail"), $0, GitRequirement.minimum.map(String.init).joined(separator: ".")) }
                 ?? L("git.requirement.missingDetail"))
        } actions: {
            Button { store.route = UtilityCatalog.route(for: "git") } label: { Label(L("git.requirement.openUtilities"), systemImage: Symbols.utilities) }
                .buttonStyle(.borderedProminent).accessibilityIdentifier("git.requirement.utilities")
            Button { Task { await tool.load() } } label: { Label(L("git.requirement.check"), systemImage: Symbols.reload) }
                .buttonStyle(.bordered).accessibilityIdentifier("git.requirement.check")
        }
    }
}

/// No repository open: the list to choose from is in the content column; here, what to do.
struct GitNoRepositoryView: View {
    let tool: GitTool
    var body: some View {
        let none = tool.entries.filter { !$0.missing }.isEmpty && tool.list.recent.isEmpty
        let migration = GitMigration.shared
        ContentUnavailableView {
            Label(L(none ? "git.empty.title" : "git.empty.chooseTitle"), systemImage: Symbols.git)
        } description: {
            Text(L(none ? "git.empty.detail" : "git.empty.chooseDetail"))
        } actions: {
            Button { tool.chooseAndAdd() } label: { Label(L("git.repo.add"), systemImage: Symbols.add) }
                .buttonStyle(.borderedProminent).accessibilityIdentifier("git.empty.add")
            HStack {
                Button { GitHosting.shared.cloning = true } label: { Label(L("git.clone.ellipsis"), systemImage: Symbols.gitClone) }
                    .buttonStyle(.bordered).help(L("git.clone.help")).accessibilityIdentifier("git.empty.clone")
                Button { GitHosting.shared.creating = true } label: { Label(L("git.create.ellipsis"), systemImage: Symbols.gitCreateRepository) }
                    .buttonStyle(.bordered).help(L("git.create.help")).accessibilityIdentifier("git.empty.create")
            }
            if migration.offered {
                Button { migration.presenter = .tool } label: { Label(L("git.migration.actionEllipsis"), systemImage: Symbols.importing) }
                    .buttonStyle(.bordered).help(L("git.migration.help")).accessibilityIdentifier("git.empty.migrate")
            }
        }
    }
}
