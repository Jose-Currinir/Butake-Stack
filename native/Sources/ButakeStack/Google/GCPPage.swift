import AppKit
import SwiftUI

/// The Google Cloud tool's detail: the selected account's card, or why there is none (gcloud
/// missing, no accounts, nothing selected). Its actions live in the toolbar: «Iniciar sesión…»,
/// «Recargar» and the rest in «Más».
struct GCPPage: View {
    @Bindable var store: StackStore
    @Bindable var tool = GCPTool.shared

    /// Where gcloud is installed from (it is not in Utilidades: its installer is Google's).
    static let installPage = URL(string: "https://cloud.google.com/sdk/docs/install")!

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .toolbar { toolbar }
            .onDisappear { tool.cancelReads() }
            .task {
                await tool.load()
                #if DEBUG
                await QAHooks.gcp(tool)
                #endif
            }
            .confirmationDialog(String(format: L("gcp.revokeConfirm"), tool.revoking?.account ?? ""),
                                isPresented: Binding(get: { tool.revoking != nil }, set: { if !$0 { tool.revoking = nil } }),
                                presenting: tool.revoking) { account in
                Button(L("gcp.revoke"), role: .destructive) { Task { await tool.revoke(account) } }
                    .accessibilityIdentifier("gcp.confirmRevoke")
                Button(L("common.cancel"), role: .cancel) {}
            } message: { account in
                Text(revokeDetail(account))
            }
    }

    private func revokeDetail(_ account: GCPAccount) -> String {
        var lines = [L("gcp.revokeDetail")]
        let uses = tool.uses(of: account.account)
        if !uses.isEmpty { lines.append(String(format: L("gcp.revokeUsed"), uses.map(\.name).joined(separator: ", "))) }
        return lines.joined(separator: "\n")
    }

    @ViewBuilder private var content: some View {
        if let account = tool.selected {
            GCPAccountCard(tool: tool, account: account).id(account.account)
        } else if !tool.loaded {
            ProgressView()
        } else if !tool.cliInstalled {
            ContentUnavailableView {
                Label(L("gcp.cliMissing"), systemImage: Symbols.cloud)
            } description: {
                Text(L("gcp.cliMissingDetail"))
            } actions: {
                Button { NSWorkspace.shared.open(Self.installPage) } label: { Label(L("gcp.install"), systemImage: Symbols.openInBrowser) }
                    .buttonStyle(.borderedProminent).accessibilityIdentifier("gcp.empty.install")
                Button { Task { await tool.load() } } label: { Label(L("gcp.checkAgain"), systemImage: Symbols.reload) }
                    .buttonStyle(.bordered).accessibilityIdentifier("gcp.empty.reload")
            }
        } else if tool.loadFailed {
            ContentUnavailableView {
                Label(L("gcp.loadFailed"), systemImage: Symbols.error)
            } actions: {
                Button { Task { await tool.load() } } label: { Label(L("common.retry"), systemImage: Symbols.reload) }
                    .buttonStyle(.bordered).accessibilityIdentifier("gcp.empty.retry")
            }
        } else if tool.accounts.isEmpty {
            ContentUnavailableView {
                Label(L("gcp.empty"), systemImage: Symbols.googleAccount)
            } description: {
                Text(L("gcp.emptyDetail"))
            } actions: {
                Button { GCPConsole.signIn() } label: { Label(L("gcp.signInEllipsis"), systemImage: Symbols.signIn) }
                    .buttonStyle(.borderedProminent).accessibilityIdentifier("gcp.empty.signIn")
            }
        } else {
            ContentUnavailableView(L("gcp.noSelection"), systemImage: Symbols.googleAccount, description: Text(L("gcp.noSelectionDetail")))
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button { GCPConsole.signIn() } label: { Label(L("gcp.signInEllipsis"), systemImage: Symbols.signIn) }
                .disabled(tool.cliPath == nil)
                .help(L("gcp.signInHelp")).accessibilityIdentifier("gcp.toolbar.signIn")
            Button {
                Task {
                    await tool.load()
                    if let account = tool.selection { tool.loadProjects(account, force: true) }
                }
            } label: { Label(L("gcp.reload"), systemImage: Symbols.reload) }
                .disabled(!tool.loaded || tool.loadingProjects.contains(tool.selection ?? ""))
                .help(L("gcp.reloadHelp")).accessibilityIdentifier("gcp.toolbar.reload")
            Menu {
                if let account = tool.selected { GCPAccountMenu(tool: tool, account: account) }
            } label: { Label(L("gcp.more"), systemImage: Symbols.more) }
                .disabled(tool.selected == nil)
                .help(L("gcp.more")).accessibilityIdentifier("gcp.toolbar.more")
        }
    }
}

/// The actions on an account, in the toolbar's «Más».
struct GCPAccountMenu: View {
    let tool: GCPTool
    let account: GCPAccount
    var body: some View {
        if account.kind == .user {
            Button { GCPConsole.signIn(account: account.account) } label: { Label(L("gcp.renewEllipsis"), systemImage: Symbols.signIn) }
                .disabled(tool.cliPath == nil).accessibilityIdentifier("gcp.menu.renew")
        }
        Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(account.account, forType: .string) } label: {
            Label(L("gcp.copyAccount"), systemImage: Symbols.copy)
        }
        .accessibilityIdentifier("gcp.menu.copy")
        Divider()
        Button(role: .destructive) { tool.revoking = account } label: { Label(L("gcp.revokeEllipsis"), systemImage: Symbols.signOut) }
            .disabled(account.active || tool.cliPath == nil)
            .help(account.active ? L("gcp.revokeActive") : "")
            .accessibilityIdentifier("gcp.menu.revoke")
    }
}
