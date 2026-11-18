import SwiftUI

extension GCPAccount: CloudAccount {}

/// The Google Cloud tool's accounts in the window's content column: people's accounts, then
/// service accounts.
struct GCPAccountList: View {
    @Bindable var tool: GCPTool

    var body: some View {
        CloudAccountList(accounts: tool.accounts, selection: $tool.selection, loaded: tool.loaded,
                         searchPrompt: L("gcp.search"), identifier: "gcp.list",
                         sectionTitle: { L("gcp.section.\($0.rawValue)") }) { account in
            CloudAccountRow(symbol: account.kind.symbol, title: account.account, subtitle: subtitle(account),
                            identifier: "gcp.list.account.\(account.account)")
        } bar: {
            Button { GCPConsole.signIn() } label: { Label(L("gcp.signInEllipsis"), systemImage: Symbols.signIn) }
                .buttonStyle(.borderless).disabled(tool.cliPath == nil)
                .help(L("gcp.signInHelp")).accessibilityIdentifier("gcp.list.signIn")
        }
    }

    /// gcloud's active one says so; then how many Stack projects use it.
    private func subtitle(_ account: GCPAccount) -> String {
        var parts = [account.active ? L("gcp.active") : account.kind.title]
        let uses = tool.uses(of: account.account).count
        if uses == 1 { parts.append(L("gcp.projectsUsing.one")) } else if uses > 1 { parts.append(String(format: L("gcp.projectsUsing.other"), uses)) }
        return parts.joined(separator: " · ")
    }
}
