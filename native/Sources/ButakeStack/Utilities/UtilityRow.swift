import AppKit
import SwiftUI

/// One utility: its tile, name and what it is, the version on this Mac (or «Sin instalar»), the
/// action that fits (Instalar… or Actualizar a X, through the confirmation) and the rest in «⋯».
/// A copy installed some other way is only shown: Stack never replaces nor removes it.
struct UtilityRow: View {
    @Bindable var store: StackStore
    let tool: String
    @State private var installing = false
    @State private var removing = false

    var scope: String { "utilities.\(tool)" }
    var status: DevToolStatus? { store.devTools[tool] }
    var installed: Bool { status?.installed == true }
    var managed: Bool { status?.managed == true }
    /// Git of Apple's developer tools: it stays; Stack can still install its own build.
    var apple: Bool { status?.apple == true }
    var update: String? { store.devUpdates.tools[tool].flatMap { $0.update ? $0.latest : nil } }
    var name: String { L("tool.\(tool)") }
    /// Install (or Stack's own build over Apple's) is offered, and an update is.
    var canInstall: Bool { apple || (!installed && store.devUpdates.unknownReason(tool) == nil) }
    var canUpdate: Bool { installed && managed && !apple && update != nil }

    var body: some View {
        LogoRow {
            HStack(spacing: 8) {
                Group {
                    if installed {
                        Text(status?.version ?? L("setup.ready")).monospacedDigit()
                    } else {
                        Text(L("utilities.notInstalled"))
                    }
                }
                .foregroundStyle(.secondary).lineLimit(1)
                .accessibilityIdentifier("\(scope).version")
                if apple {
                    Text(L("utilities.apple")).font(.uiCaption).foregroundStyle(.secondary)
                        .help(L("utilities.appleHelp"))
                        .accessibilityIdentifier("\(scope).apple")
                    Button { installing = true } label: { Label(L("utilities.install"), systemImage: Symbols.install) }
                        .disabled(store.busy != nil)
                        .help(L("utilities.installOwnHelp"))
                        .accessibilityIdentifier("\(scope).install")
                } else if installed && !managed {
                    Text(L("utilities.elsewhere")).font(.uiCaption).foregroundStyle(.secondary)
                        .help(L("utilities.elsewhereHelp"))
                        .accessibilityIdentifier("\(scope).elsewhere")
                } else if let update, installed {
                    Button { installing = true } label: { Label(String(format: L("tools.updateTo"), update), systemImage: Symbols.update) }
                        .disabled(store.busy != nil)
                        .help(String(format: L("tools.installedVersion"), status?.version ?? ""))
                        .accessibilityIdentifier("\(scope).update")
                } else if !installed, let reason = store.devUpdates.unknownReason(tool) {
                    // The source did not say its newest version: why, and «Reintentar».
                    Text(L("utilities.latestUnknown")).font(.uiCaption).foregroundStyle(.secondary)
                        .help(reason).accessibilityIdentifier("\(scope).latestUnknown")
                    Button { Task { await store.refreshDevTools(refresh: true) } } label: { Label(L("common.retry"), systemImage: Symbols.reload) }
                        .disabled(store.busy != nil).help(reason)
                        .accessibilityIdentifier("\(scope).retry")
                } else if !installed {
                    Button { installing = true } label: { Label(L("utilities.install"), systemImage: Symbols.install) }
                        .disabled(store.busy != nil)
                        .help(store.devUpdates.knownNote(tool) ?? "")
                        .accessibilityIdentifier("\(scope).install")
                }
                // AWS CLI leads to its profiles (the AWS tool) while that tool is on.
                if tool == "aws" && installed && store.pluginEnabled("aws") {
                    Button { store.route = .tool("aws") } label: { Label(L("aws.utilityProfiles"), systemImage: Symbols.awsProfile) }
                        .help(L("aws.utilityProfilesHelp")).accessibilityIdentifier("\(scope).profiles")
                }
                more
            }
        } label: {
            TechLogo(tech: .of(tool), size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                Text(L("toolDetail.\(tool)")).font(.uiCaption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        // The same actions as the row's buttons and its «⋯» menu.
        .contextMenu {
            if canInstall {
                Button { installing = true } label: { Label(L("utilities.install"), systemImage: Symbols.install) }
                    .disabled(store.busy != nil)
                    .accessibilityIdentifier("\(scope).install.context")
                Divider()
            } else if canUpdate, let update {
                Button { installing = true } label: { Label(String(format: L("tools.updateTo"), update), systemImage: Symbols.update) }
                    .disabled(store.busy != nil)
                    .accessibilityIdentifier("\(scope).update.context")
                Divider()
            }
            menuItems
        }
        .sheet(isPresented: $installing) {
            UtilityInstallSheet(store: store, tool: tool, updating: installed && managed).themedSheet()
        }
        .confirmationDialog(String(format: L("utilities.removeConfirm"), name), isPresented: $removing) {
            Button(L("common.remove"), role: .destructive) { Task { await store.removeDevTool(tool) } }
                .accessibilityIdentifier("\(scope).removeConfirm")
            Button(L("common.cancel"), role: .cancel) {}
        } message: { Text(L("utilities.removeDetail")) }
        #if DEBUG
        .task { if await QAHooks.opensUtilitySheet(tool) { installing = true } }
        #endif
    }

    private var more: some View {
        Menu { menuItems } label: {
            Label(String(format: L("utilities.actions"), name), systemImage: Symbols.more).labelStyle(.iconOnly)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help(String(format: L("utilities.actions"), name))
        .accessibilityIdentifier("\(scope).menu")
    }

    @ViewBuilder private var menuItems: some View {
            // A terminal assistant found on this Mac opens in a tab of the Terminal, while it is on.
            if store.pluginEnabled("ssh-terminal"), let program = LocalConsoles.program(tool), !program.isShell {
                Button { LocalConsoles.open(program) } label: { Label(L("ssh.local.openInTerminal"), systemImage: Symbols.terminal) }
                    .accessibilityIdentifier("\(scope).openInTerminal")
                Divider()
            }
            if let site = UtilityCatalog.site(tool) {
                Button { NSWorkspace.shared.open(site) } label: { Label(L("tools.official"), systemImage: Symbols.openInBrowser) }
                    .accessibilityIdentifier("\(scope).site")
            }
            Button {
                if let path = status?.path { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
            } label: { Label(L("menu.showInFinder"), systemImage: Symbols.folder) }
                .disabled(status?.path == nil)
                .accessibilityIdentifier("\(scope).finder")
            Divider()
            Button(role: .destructive) { removing = true } label: { Label(L("utilities.remove"), systemImage: Symbols.delete) }
                .disabled(!managed || store.busy != nil)
                .help(installed && !managed ? L(apple ? "utilities.appleHelp" : "utilities.elsewhereHelp") : "")
                .accessibilityIdentifier("\(scope).remove")
    }
}
