import SwiftUI

/// «Google Cloud» in the page of a project of several parts: the account and project its parts
/// inherit (each part's own link wins), and «Enlazar…» or «Cambiar…».
struct GCPCompositeSection: View {
    let group: ProjectGroup
    @State private var editing = false

    var body: some View {
        Section {
            if let link = group.gcp {
                LabeledContent(L("gcp.link.account")) {
                    Text(link.account).lineLimit(1).truncationMode(.middle).textSelection(.enabled).help(link.account)
                }
                .accessibilityIdentifier("composite.gcp.account")
                LabeledContent {
                    GCPConsoleMenu(project: link.project, account: link.account, id: "composite.gcp.console")
                } label: {
                    Text(L("gcp.link.project"))
                    Text(verbatim: link.project).font(.uiCaption.monospaced()).textSelection(.enabled)
                }
                .accessibilityIdentifier("composite.gcp.project")
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
                    Label(L(group.gcp == nil ? "gcp.link.add" : "gcp.link.change"), systemImage: Symbols.link)
                }
                .buttonStyle(.bordered).controlSize(.small).accessibilityIdentifier("composite.gcp.edit")
                .sheet(isPresented: $editing) { GCPLinkSheet(composite: group).themedSheet() }
            }
        } footer: {
            SettingsFooter(L("gcp.link.compositeFooter"))
        }
    }
}
