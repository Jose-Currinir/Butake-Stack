import AppKit
import SwiftUI

/// A project shared through a public tunnel; `url` appears once cloudflared has one.
struct ShareStatus: Decodable, Sendable, Hashable { let id: String; let url: String? }

/// Shares a project on the internet through Cloudflare (cloudflared), with a clear warning: anyone
/// with the address can open it while it is shared. Two ways: a temporary address
/// (trycloudflare.com, new each time) and a fixed address on a domain of the user's own (P-35).
struct ShareSection: View {
    @Bindable var store: StackStore
    let project: Project
    @State private var confirm = false
    /// The fixed address and the connection with Cloudflare (P-35).
    @State private var tunnels: TunnelState?
    var body: some View {
        let cloudflared = store.devTools["cloudflared"]?.installed == true
        Section {
            if cloudflared {
                temporary
                if let tunnels {
                    FixedAddressRows(store: store, project: project, tunnels: tunnels) { await reload() }
                }
            } else {
                // Installed from its official release, with the same confirmation as on the language pages.
                ToolRow(store: store, tool: "cloudflared", padded: false)
            }
        } header: {
            Text(L("share.title"))
        } footer: {
            Text(L("share.footer")).font(.uiCaption).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { if store.devTools.isEmpty { await store.refreshDevTools() } }
        .task(id: store.connectingCloudflare) { await follow() }
        .confirmationDialog(String(format: L("share.confirm"), project.title), isPresented: $confirm) {
            Button(L("share.start"), role: .destructive) { Task { await store.setShared(project, true) } }.accessibilityIdentifier("share.confirm")
            Button(L("common.cancel"), role: .cancel) {}
        } message: { Text(String(format: L("share.confirmDetail"), project.domain)) }
    }

    /// Loads the fixed address's state and, while the connection is being made, follows it until
    /// the certificate appears (the daemon ends the login then).
    private func follow() async {
        await reload()
        while store.connectingCloudflare && tunnels?.connected != true && !Task.isCancelled {
            try? await Task.sleep(for: .seconds(2))
            await reload()
            await store.refreshStatus()
        }
    }
    private func reload() async {
        if let state = await store.tunnelState() { tunnels = state }
    }

    /// The temporary address: one row with its state and its action.
    @ViewBuilder private var temporary: some View {
        let phase = store.phase("share.\(project.id)")
        if let share = store.share(project) {
            LabeledContent {
                HStack(spacing: 8) {
                    if let url = share.url {
                        if let link = URL(string: url) {
                            Link(url, destination: link).lineLimit(1).truncationMode(.middle).help(L("menu.openInBrowser"))
                                .accessibilityIdentifier("share.open")
                        }
                        Button { store.copyToPasteboard(url) } label: {
                            Label(L("share.copy"), systemImage: Symbols.copy).labelStyle(.iconOnly)
                        }
                        .buttonStyle(.borderless).help(L("share.copy")).accessibilityIdentifier("share.copy")
                    } else if phase == .crashed || phase == .stopped {
                        Text(L("share.failed")).foregroundStyle(Brand.dangerText)
                        Button { store.showLogs("share.\(project.id)") } label: { Label(L("process.logs"), systemImage: Symbols.logs) }
                            .buttonStyle(.bordered).controlSize(.small).accessibilityIdentifier("share.logs")
                    } else {
                        ProgressView().controlSize(.small)
                        Text(L("share.starting")).foregroundStyle(.secondary)
                    }
                    Button(role: .destructive) { Task { await store.setShared(project, false) } } label: {
                        Label(L("share.stop"), systemImage: Symbols.stop)
                    }
                    .buttonStyle(.bordered).accessibilityIdentifier("share.stop")
                }
            } label: {
                Text(L("share.temporary"))
                Label(L("share.publicWarning"), systemImage: Symbols.warning).foregroundStyle(Brand.warningText)
            }
        } else {
            LabeledContent {
                Button { confirm = true } label: { Label(L("share.start"), systemImage: Symbols.share) }
                    .buttonStyle(.bordered).disabled(!project.enabled || store.busy != nil).accessibilityIdentifier("share.start")
            } label: {
                Text(L("share.temporary"))
                Text(project.enabled ? L("share.help") : L("share.needsOn"))
            }
        }
    }
}
