import SwiftUI

/// An account's card in the detail: what it is, the Google Cloud projects it reaches (with their
/// pages in Google's consoles) and the Stack projects that use it. Nothing secret is shown or read.
struct GCPAccountCard: View {
    @Bindable var tool: GCPTool
    let account: GCPAccount

    var body: some View {
        Form {
            Section {
                header
                if !tool.cliInstalled {
                    Notice(.warning, L("gcp.cliMissing"), detail: L("gcp.cliMissingDetail"))
                }
            } footer: {
                SettingsFooter(L(account.kind == .service ? "gcp.service.footer" : (account.active ? "gcp.active.footer" : "gcp.user.footer")))
            }
            projects
            uses
        }
        .formStyle(.grouped).themedScroll()
        .accessibilityIdentifier("gcp.card")
        .task(id: account.account) { tool.loadProjects(account.account) }
        .onDisappear { tool.cancelReads() }
    }

    private var header: some View {
        CloudCardHeader(symbol: account.kind.symbol, title: account.account, subtitle: account.kind.title,
                        titleIdentifier: "gcp.card.account", selectable: true) {
            if account.active { Chip(text: L("gcp.active"), symbol: Symbols.makeDefault, help: L("gcp.active.help")) }
        }
    }

    @ViewBuilder private var projects: some View {
        Section {
            if tool.loadingProjects.contains(account.account) {
                LabeledContent(L("gcp.projects.loading")) { ProgressView().controlSize(.small) }
            } else if let error = tool.projectErrors[account.account] {
                Notice(.error, error) {
                    if account.kind == .user {
                        Button { GCPConsole.signIn(account: account.account) } label: { Label(L("gcp.renewEllipsis"), systemImage: Symbols.signIn) }
                            .buttonStyle(.bordered).disabled(tool.cliPath == nil).accessibilityIdentifier("gcp.card.renew")
                    }
                }
            } else if let list = tool.projects[account.account]?.list {
                if list.isEmpty { Text(L("gcp.projects.none")).foregroundStyle(.secondary) }
                ForEach(list) { GCPProjectRow(project: $0, account: account) }
            }
        } header: {
            Text(L("gcp.projects"))
        } footer: {
            SettingsFooter(L("gcp.projects.footer"))
        }
    }

    private var uses: some View {
        Section(L("gcp.uses")) {
            let uses = tool.uses(of: account.account)
            if uses.isEmpty { Text(L("gcp.uses.none")).foregroundStyle(.secondary) }
            ForEach(uses) { use in
                if let project = StackStore.shared.projects.first(where: { $0.id == use.id }) {
                    ProjectLinkRow(project: project, detail: use.project) { StackStore.shared.openSite(project.id) }
                        .accessibilityIdentifier("gcp.card.use.\(use.id)")
                }
            }
        }
    }
}

/// A Google Cloud project: its name and id; the button at the end opens it in the console and its
/// menu, its credentials, Firebase and billing pages.
private struct GCPProjectRow: View {
    let project: GCPProject
    let account: GCPAccount
    var body: some View {
        LabeledContent {
            GCPConsoleMenu(project: project.id, account: account.account, id: "gcp.card.project.\(project.id)")
        } label: {
            HStack(spacing: 10) {
                IconTile(symbol: Symbols.gcpProject, size: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(project.title).lineLimit(1).truncationMode(.middle).help(project.title)
                    Text(verbatim: project.id).font(.uiCaption.monospaced()).foregroundStyle(.secondary).lineLimit(1).textSelection(.enabled)
                }
            }
        }
    }
}

/// «Abrir en la consola» at the end of a row: a click opens the project's dashboard; its menu, the
/// other pages. Shared by the account's card and a Stack project's «Google Cloud» row.
struct GCPConsoleMenu: View {
    let project: String
    let account: String?
    let id: String
    var body: some View {
        Menu {
            ForEach(GCPConsolePage.allCases, id: \.self) { page in
                Button { GCPConsole.open(page, project: project, account: account) } label: { Label(page.title, systemImage: page.symbol) }
                    .accessibilityIdentifier("\(id).\(page.rawValue)")
            }
        } label: {
            Label(L("gcp.console.open"), systemImage: Symbols.openInBrowser)
        } primaryAction: {
            GCPConsole.open(.dashboard, project: project, account: account)
        }
        .fixedSize()
        .help(L("gcp.console.openHelp"))
        .accessibilityIdentifier(id)
    }
}
