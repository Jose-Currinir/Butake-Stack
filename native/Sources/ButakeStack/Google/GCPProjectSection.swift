import SwiftUI

/// «Google Cloud» in a project's Resumen: the Google account and project it works with, its pages
/// in Google's consoles, and «Enlazar…» or «Cambiar…». The link only gives its processes and its
/// consoles the account and the project; gcloud's configuration does not change.
struct GCPProjectSection: View {
    let project: Project
    @Bindable private var tool = GCPTool.shared
    @State private var editing = false
    /// The project of several parts it is a part of, when that one has a link.
    private var inherited: ProjectGroup? { StackStore.shared.composite(of: project.id).flatMap { $0.gcp == nil ? nil : $0 } }

    var body: some View {
        Section {
            if let link = project.gcp ?? inherited?.gcp {
                if project.gcp == nil, let inherited {
                    // Its project of several parts gives it the link; its own, set here, would win.
                    LabeledContent(L("gcp.link.inherited")) { Text(inherited.name).foregroundStyle(.secondary) }
                        .accessibilityIdentifier("project.gcp.inherited")
                }
                LabeledContent(L("gcp.link.account")) {
                    Text(link.account).lineLimit(1).truncationMode(.middle).textSelection(.enabled).help(link.account)
                }
                .accessibilityIdentifier("project.gcp.account")
                LabeledContent {
                    GCPConsoleMenu(project: link.project, account: link.account, id: "project.gcp.console")
                } label: {
                    Text(L("gcp.link.project"))
                    Text(verbatim: link.project).font(.uiCaption.monospaced()).textSelection(.enabled)
                }
                .accessibilityIdentifier("project.gcp.project")
            } else {
                HStack(spacing: 10) {
                    IconTile(symbol: Symbols.gcpProject, size: 24)
                    Text(L("gcp.link.none")).foregroundStyle(.secondary)
                }
            }
        } header: {
            HStack {
                Text(Tech.of("gcp").title)
                Spacer()
                Button { editing = true } label: {
                    Label(L(project.gcp == nil ? "gcp.link.add" : "gcp.link.change"), systemImage: Symbols.link)
                }
                .buttonStyle(.bordered).controlSize(.small).accessibilityIdentifier("project.gcp.edit")
                .sheet(isPresented: $editing) { GCPLinkSheet(project: project).themedSheet() }
                #if DEBUG
                .onAppear { if QAHooks.gcpLinkSheet { editing = true } }
                #endif
            }
        } footer: {
            if project.gcp != nil || inherited != nil { SettingsFooter(L("gcp.link.footer")) }
        }
    }
}

/// Choosing the account and the project: the accounts gcloud has, then the projects the chosen
/// one reaches (or its id by hand when they cannot be read). «Ninguna» removes the link. Of a
/// project, or of a project of several parts (its parts inherit it).
struct GCPLinkSheet: View {
    enum Target {
        case project(Project)
        case composite(ProjectGroup)
        var title: String { switch self { case .project(let project): project.title; case .composite(let group): group.name } }
        var link: GCPLink? { switch self { case .project(let project): project.gcp; case .composite(let group): group.gcp } }
    }
    let target: Target
    @Bindable private var tool = GCPTool.shared
    @State private var account: String
    @State private var gcpProject: String

    init(project: Project) { self.init(target: .project(project)) }
    init(composite: ProjectGroup) { self.init(target: .composite(composite)) }
    private init(target: Target) {
        self.target = target
        _account = State(initialValue: target.link?.account ?? "")
        _gcpProject = State(initialValue: target.link?.project ?? "")
    }

    private var list: [GCPProject]? { tool.projects[account]?.list }
    private var link: GCPLink? { account.isEmpty ? nil : GCPLink(account: account, project: gcpProject) }
    private var valid: Bool { account.isEmpty || GCPLink.validProject(gcpProject) }
    private var changed: Bool { link != target.link }

    var body: some View {
        SheetFrame(title: String(format: L("gcp.link.title"), target.title), symbol: Symbols.link,
                   note: L(target.isComposite ? "gcp.link.compositeNote" : "gcp.link.note"), width: 520, actionTitle: L("common.save"),
                   actionID: "gcp.link.save", canAct: valid && changed, cancelID: "gcp.link.cancel") {
            switch target {
            case .project(let project): await tool.link(project, to: link)
            case .composite(let group): await tool.link(composite: group, to: link)
            }
        } content: {
            Form {
                Section {
                    Picker(L("gcp.link.account"), selection: $account) {
                        Text(L("gcp.link.noAccount")).tag("")
                        ForEach(tool.accounts) { Text(verbatim: $0.account).tag($0.account) }
                        if !account.isEmpty && tool.account(account) == nil {
                            Text(String(format: L("gcp.link.unknownAccount"), account)).tag(account)
                        }
                    }
                    .accessibilityIdentifier("gcp.link.accountPicker")
                    if !account.isEmpty { projectField }
                }
            }
            .formStyle(.grouped).themedScroll()
            .frame(minHeight: 150)
        }
        .task { if !tool.loaded { await tool.load() } }
        .task(id: account) {
            guard !account.isEmpty else { return }
            tool.loadProjects(account)
        }
        .onChange(of: list) { _, list in
            // A project of another account is not kept: the first one of this account is offered.
            if let list, !list.contains(where: { $0.id == gcpProject }), account != target.link?.account || gcpProject.isEmpty {
                gcpProject = list.first?.id ?? ""
            }
        }
    }

    @ViewBuilder private var projectField: some View {
        if tool.loadingProjects.contains(account) {
            LabeledContent(L("gcp.link.project")) { ProgressView().controlSize(.small) }
        } else if let list, tool.projectErrors[account] == nil {
            Picker(L("gcp.link.project"), selection: $gcpProject) {
                ForEach(list) { Text(verbatim: "\($0.title) (\($0.id))").tag($0.id) }
                if !gcpProject.isEmpty && !list.contains(where: { $0.id == gcpProject }) {
                    Text(verbatim: gcpProject).tag(gcpProject)
                }
            }
            .accessibilityIdentifier("gcp.link.projectPicker")
        } else {
            if let error = tool.projectErrors[account] { Notice(.warning, error, detail: L("gcp.link.byHand")) }
            TextField(L("gcp.link.project"), text: $gcpProject, prompt: Text(verbatim: "mi-proyecto-123"))
                .accessibilityIdentifier("gcp.link.projectField")
        }
    }
}

extension GCPLinkSheet.Target {
    var isComposite: Bool { if case .composite = self { true } else { false } }
}

extension GCPLink {
    /// The project ids the engine accepts (core/validate.rs `gcp_project`).
    static func validProject(_ id: String) -> Bool {
        var name = Substring(id)
        if let colon = id.lastIndex(of: ":") {
            let domain = id[..<colon]
            guard !domain.isEmpty, domain.count <= 253,
                  domain.unicodeScalars.allSatisfy({ ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "." || $0 == "-" }) else { return false }
            name = id[id.index(after: colon)...]
        }
        guard (6...30).contains(name.count), let first = name.unicodeScalars.first, ("a"..."z").contains(first), name.last != "-" else { return false }
        return name.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
    }
}
