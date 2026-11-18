import SwiftUI

/// «Extensiones» of a project's Resumen, when its databases declare some (`databases[].extensions`):
/// each one with its state and, when something is missing, what and the button that resolves it
/// (installing from the catalog and activating in the database), like «Problemas».
struct ProjectExtensionsSection: View {
    @Bindable var store: StackStore
    let project: Project
    @State private var issues: [ExtensionIssue]?
    @State private var resolving = false
    var scope: String { "project.extensions" }
    var declared: [(database: String, extension: String)] {
        project.databases.flatMap { db in db.extensions.map { (db.name, $0) } }
    }

    var body: some View {
        if !declared.isEmpty {
            Section {
                if let issues, !issues.isEmpty {
                    Notice(.warning, L("ext.project.missing"), detail: issues.map(describe).joined(separator: "\n")) {
                        if issues.contains(where: \.fixable) {
                            Button { resolving = true } label: { Label(L("ext.project.resolve"), systemImage: Symbols.setup) }
                                .buttonStyle(.borderedProminent).disabled(store.busy != nil)
                                .accessibilityIdentifier("\(scope).resolve")
                        }
                    }
                    .accessibilityIdentifier("\(scope).missing")
                }
                ForEach(Array(declared.enumerated()), id: \.offset) { _, item in
                    let issue = issues?.first { $0.database == item.database && $0.extensionName == item.extension }
                    LabeledContent {
                        if issues == nil {
                            ProgressView().controlSize(.small)
                        } else if let issue {
                            Chip(text: L("ext.problem.\(issue.problem)"), symbol: Symbols.warning, tint: Brand.warning)
                        } else {
                            Chip(text: L("ext.project.ready"), symbol: Symbols.success, tint: Brand.success)
                        }
                    } label: {
                        Text(verbatim: item.extension)
                        Text(item.database)
                    }
                    .accessibilityIdentifier("\(scope).\(item.database).\(item.extension)")
                }
            } header: {
                Text(L("ext.title"))
            }
            .task(id: "\(project.id).\(project.enabled)") { await load() }
            .sheet(isPresented: $resolving, onDismiss: { Task { await load() } }) {
                ProjectExtensionsSheet(store: store, project: project, issues: issues ?? []).themedSheet()
            }
        }
    }

    private func describe(_ issue: ExtensionIssue) -> String {
        String(format: L("ext.project.line"), issue.extensionName, issue.database, L("ext.problem.\(issue.problem)"))
    }

    private func load() async {
        issues = await store.projectExtensionIssues(project)
        #if DEBUG
        if QAHooks.extensionSheet == "resolve", issues?.contains(where: \.fixable) == true { resolving = true }
        #endif
    }
}

/// «Resolver»: what will be installed and activated, then the work followed step by step.
private struct ProjectExtensionsSheet: View {
    @Bindable var store: StackStore
    let project: Project
    let issues: [ExtensionIssue]
    @State private var monitor: InstallMonitor
    var scope: String { "project.extensions.sheet" }

    init(store: StackStore, project: Project, issues: [ExtensionIssue]) {
        self.store = store
        self.project = project
        self.issues = issues
        _monitor = State(initialValue: InstallMonitor(log: StackStore.extensionLog, tool: "extension-project-\(project.id)"))
    }

    var body: some View {
        SheetFrame(title: L("ext.project.resolveTitle"), symbol: Symbols.package, width: TextScale.points(520), height: TextScale.points(460),
                   actionTitle: monitor.finished ? L("progress.close") : L("ext.project.resolve"),
                   actionSymbol: monitor.finished ? nil : Symbols.setup,
                   actionID: monitor.finished ? "\(scope).close" : "\(scope).confirm",
                   canAct: monitor.finished || (store.busy == nil && !monitor.running),
                   cancelID: monitor.finished ? nil : "\(scope).cancel",
                   action: {
                       if monitor.finished { return true }
                       monitor.start(store) { try await store.resolveProjectExtensionsFollowed(project) }
                       return false
                   }) {
            if monitor.phase == .ready {
                Form {
                    Section {
                        ForEach(issues.filter(\.fixable)) { issue in
                            LabeledContent(issue.extensionName, value: issue.problem == "notInstalled"
                                           ? String(format: L("ext.project.willInstall"), issue.database)
                                           : String(format: L("ext.project.willActivate"), issue.database))
                        }
                    } footer: {
                        Text(L("ext.project.resolveDetail")).font(.uiCaption).foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
            } else {
                InstallProgressView(monitor: monitor, name: project.title, scope: "\(scope).progress")
            }
        }
        .following(monitor)
    }
}
