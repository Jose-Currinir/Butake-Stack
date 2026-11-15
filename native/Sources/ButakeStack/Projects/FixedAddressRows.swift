import AppKit
import SwiftUI

/// The fixed address of «Compartir en internet» (P-35): connecting with Cloudflare once, the
/// address itself, sharing it, and the origin to authorize in Google and similar providers.
struct FixedAddressRows: View {
    @Bindable var store: StackStore
    let project: Project
    /// Loaded (and followed while connecting) by the section, which is always on screen.
    let tunnels: TunnelState
    let reload: () async -> Void
    @State private var editing: FixedAddressSheet.Mode?
    @State private var confirmShare = false
    @State private var confirmRemove = false
    @State private var explainDisconnect = false
    @State private var leftover: LeftoverRecord?

    private var address: FixedAddress? { tunnels.addresses[project.id] }

    var body: some View {
        Group {
            if !tunnels.connected {
                connection
            } else if let address {
                configured(address)
                origins(address)
            } else {
                LabeledContent {
                    HStack(spacing: 8) {
                        Button { editing = .configure } label: { Label(L("share.fixed.configure"), systemImage: Symbols.address) }
                            .buttonStyle(.bordered).disabled(store.busy != nil).accessibilityIdentifier("share.fixed.configure")
                        more
                    }
                } label: {
                    Text(L("share.fixed.title"))
                    Text(L("share.fixed.help"))
                }
            }
        }
        .sheet(item: $editing) { mode in
            FixedAddressSheet(store: store, project: project, mode: mode, zone: address?.zone ?? tunnels.zone ?? "",
                              current: address?.hostname) { change in
                Task { await reload() }
                leftover = change.leftover(removed: false)
            }
        }
        .confirmationDialog(String(format: L("share.fixed.confirm"), project.title), isPresented: $confirmShare) {
            Button(L("share.start"), role: .destructive) { Task { await store.setFixedShared(project, true) } }
                .accessibilityIdentifier("share.fixed.confirmShare")
            Button(L("common.cancel"), role: .cancel) {}
        } message: { Text(String(format: L("share.fixed.confirmDetail"), address?.hostname ?? "")) }
        .confirmationDialog(L("share.fixed.removeTitle"), isPresented: $confirmRemove) {
            Button(L("share.fixed.remove"), role: .destructive) {
                Task {
                    let removed = await store.removeFixedAddress(project)
                    await reload()
                    leftover = removed?.leftover(removed: true)
                }
            }
            .accessibilityIdentifier("share.fixed.confirmRemove")
            Button(L("common.cancel"), role: .cancel) {}
        } message: { Text(String(format: L("share.fixed.removeDetail"), address?.hostname ?? "")) }
        .alert(L("share.fixed.disconnectTitle"), isPresented: $explainDisconnect) {
            Button(L("common.done"), role: .cancel) {}
        } message: { Text(String(format: L("share.fixed.disconnectDetail"), tunnels.certificate)) }
        .alert(L("share.fixed.dnsTitle"), isPresented: Binding(get: { leftover != nil }, set: { if !$0 { leftover = nil } }),
               presenting: leftover) { record in
            Button(L("share.fixed.openDNS")) { if let url = record.dashboard { NSWorkspace.shared.open(url) } }
                .accessibilityIdentifier("share.fixed.openDNS")
            Button(L("common.cancel"), role: .cancel) {}
        } message: { record in Text(String(format: L("share.fixed.dnsDetail"), record.hostname)) }
        #if DEBUG
        .onAppear { if QAHooks.shareSheet == "configure" { editing = .configure } }
        #endif
    }

    // MARK: Rows

    /// Not connected: one step in the browser, once.
    @ViewBuilder private var connection: some View {
        let phase = store.phase("cloudflare.login")
        LabeledContent {
            HStack(spacing: 8) {
                if store.connectingCloudflare && phase != .crashed && phase != .stopped {
                    ProgressView().controlSize(.small)
                    Text(L("share.fixed.connecting")).foregroundStyle(.secondary)
                    Button(role: .cancel) { Task { await store.connectCloudflare(false) } } label: {
                        Label(L("common.cancel"), systemImage: Symbols.close)
                    }
                    .buttonStyle(.bordered).accessibilityIdentifier("share.fixed.cancelConnect")
                } else {
                    if store.connectingCloudflare {
                        Text(L("share.fixed.connectFailed")).foregroundStyle(Brand.danger)
                    }
                    Button { Task { await store.connectCloudflare(true) } } label: {
                        Label(L("share.fixed.connect"), systemImage: Symbols.link)
                    }
                    .buttonStyle(.bordered).disabled(store.busy != nil || !store.daemonRunning)
                    .help(store.daemonRunning ? L("share.fixed.connectHelp") : L("share.fixed.needsStack"))
                    .accessibilityIdentifier("share.fixed.connect")
                }
            }
        } label: {
            Text(L("share.fixed.title"))
            Text(L("share.fixed.notConnected"))
        }
    }

    /// Configured: the address, whether it is shared now, and its actions.
    @ViewBuilder private func configured(_ address: FixedAddress) -> some View {
        let share = store.publicShare(project)
        let phase = store.phase("public.\(project.id)")
        LabeledContent {
            HStack(spacing: 8) {
                if let url = address.url {
                    Link(address.hostname, destination: url).lineLimit(1).truncationMode(.middle).help(L("menu.openInBrowser"))
                        .accessibilityIdentifier("share.fixed.open")
                }
                Button { store.copyToPasteboard(address.origin) } label: {
                    Label(L("share.copy"), systemImage: Symbols.copy).labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless).help(L("share.copy")).accessibilityIdentifier("share.fixed.copy")
                more
            }
        } label: {
            Text(L("share.fixed.title"))
            if address.advancedCertificate {
                Label(L("share.fixed.advancedCertificate"), systemImage: Symbols.warning).foregroundStyle(Brand.warning)
            }
        }
        LabeledContent {
            HStack(spacing: 8) {
                if share != nil {
                    if phase == .crashed || phase == .stopped {
                        Button { store.showLogs("public.\(project.id)") } label: { Label(L("process.logs"), systemImage: Symbols.logs) }
                            .buttonStyle(.bordered).accessibilityIdentifier("share.fixed.logs")
                    } else if share?.ready != true {
                        ProgressView().controlSize(.small)
                    }
                    Button(role: .destructive) { Task { await store.setFixedShared(project, false) } } label: {
                        Label(L("share.stop"), systemImage: Symbols.stop)
                    }
                    .buttonStyle(.bordered).accessibilityIdentifier("share.fixed.stop")
                } else {
                    Button { confirmShare = true } label: { Label(L("share.start"), systemImage: Symbols.share) }
                        .buttonStyle(.bordered).disabled(!project.enabled || store.busy != nil || !store.daemonRunning)
                        .accessibilityIdentifier("share.fixed.start")
                }
            }
        } label: {
            if share == nil {
                Text(L("share.fixed.notShared"))
                Text(project.enabled ? L("share.fixed.shareHelp") : L("share.needsOn"))
            } else if phase == .crashed || phase == .stopped {
                Text(L("share.failed")).foregroundStyle(Brand.danger)
            } else if share?.ready == true {
                Text(L("share.fixed.shared"))
                Label(L("share.publicWarning"), systemImage: Symbols.warning).foregroundStyle(Brand.warning)
            } else {
                Text(L("share.fixed.starting"))
            }
        }
    }

    /// Google (and other sign-in providers) only accept authorized origins: the exact one to add.
    /// Stack cannot add it (Google has no public interface for it): it only guides.
    private func origins(_ address: FixedAddress) -> some View {
        LabeledContent {
            HStack(spacing: 8) {
                Text(verbatim: address.origin).font(.uiCallout.monospaced()).textSelection(.enabled)
                    .lineLimit(1).truncationMode(.middle).help(address.origin)
                Button {
                    if let url = StackStore.googleCredentialsURL(project: project.gcp?.project) { NSWorkspace.shared.open(url) }
                } label: { Label(L("share.origins.openGoogle"), systemImage: Symbols.openInBrowser) }
                .buttonStyle(.bordered).accessibilityIdentifier("share.origins.openGoogle")
                Button { store.copyToPasteboard(address.origin) } label: {
                    Label(L("share.origins.copy"), systemImage: Symbols.copy).labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless).help(L("share.origins.copy")).accessibilityIdentifier("share.origins.copy")
            }
        } label: {
            Text(L("share.origins.title"))
            Text(L("share.origins.help"))
        }
    }

    /// «⋯» at the end of the row: change or remove the address, and how to disconnect.
    private var more: some View {
        Menu {
            if address != nil {
                Button { editing = .change } label: { Label(L("share.fixed.change"), systemImage: Symbols.edit) }
                    .accessibilityIdentifier("share.fixed.change")
                Button(role: .destructive) { confirmRemove = true } label: { Label(L("share.fixed.removeMenu"), systemImage: Symbols.delete) }
                    .accessibilityIdentifier("share.fixed.remove")
                Divider()
            }
            Button { explainDisconnect = true } label: { Label(L("share.fixed.disconnect"), systemImage: Symbols.info) }
                .accessibilityIdentifier("share.fixed.disconnect")
        } label: {
            Label(L("share.fixed.more"), systemImage: Symbols.more).labelStyle(.iconOnly)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .disabled(store.busy != nil)
        .help(L("share.fixed.more")).accessibilityIdentifier("share.fixed.more")
    }
}
