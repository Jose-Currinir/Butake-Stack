import SwiftUI

/// What Stack needs on this Mac, in order. Nothing is downloaded without asking: each row shows its
/// official source, lets the user pick the version and installs only after confirming. Starting
/// with the session and the local trust ask first and then macOS asks for authorization itself.
struct BaseStep: View {
    @Bindable var store: StackStore
    /// The product whose official catalog is open to pick a version (caddy, php or node).
    @State private var picking: String?
    @State private var confirmAgent = false
    @State private var waitingTools = false
    @State private var confirmResolver = false
    @State private var confirmCa = false
    @AppStorage("setup.profiles") private var profilesRaw = ""
    var profiles: Set<String> { Set(profilesRaw.split(separator: ",").map(String.init)) }
    var needsPhp: Bool { profiles.contains("laravel") }
    var needsNode: Bool { !profiles.isDisjoint(with: WorkProfile.needsNode) }

    var body: some View {
        Form {
            Section(L("setup.base")) {
                row(tech: .of("web"), title: "Caddy", detail: L("setup.caddy"), done: store.caddyReady) {
                    installButton("caddy")
                }
                row(symbol: Symbols.startup, title: L("activation.title"), detail: L("setup.agent"), done: store.agentReady) {
                    Button { confirmAgent = true } label: { Label(L("activation.enable"), systemImage: Symbols.startup) }
                        .buttonStyle(.bordered)
                        .disabled(!store.caddyReady || store.busy != nil)
                        .help(L("setup.agentNeeds")).accessibilityIdentifier("setup.agent")
                }
                // /etc/resolver/test and the local CA: macOS asks for authorization itself.
                let trust = store.localTrust
                row(symbol: Symbols.network, title: L("trust.resolver.title"), detail: LocalTrust.resolverDetail(trust), done: trust?.resolversReady == true) {
                    Button { confirmResolver = true } label: { Label(LocalTrust.resolverAction(trust), systemImage: Symbols.network) }
                        .buttonStyle(.bordered)
                        .disabled(trust == nil || store.busy != nil).accessibilityIdentifier("trust.resolver")
                }
                row(symbol: Symbols.certificate, title: L("trust.ca.title"), detail: LocalTrust.caDetail(trust), done: trust?.authority.trusted == true) {
                    Button { confirmCa = true } label: { Label(L("trust.ca.action"), systemImage: Symbols.certificate) }
                        .buttonStyle(.bordered)
                        .disabled(trust?.authority.exists != true || store.busy != nil).accessibilityIdentifier("trust.ca")
                }
            }
            Section {
                if needsPhp {
                    row(tech: .of("php"), title: "PHP", detail: store.phpCatalogFailed ? L("setup.phpOffline") : L("setup.php"), done: store.phpReady) {
                        installButton("php")
                    }
                }
                if needsNode {
                    row(tech: .of("node"), title: "Node.js", detail: L("setup.node"), done: !(store.installedTools["node"] ?? []).isEmpty) {
                        installButton("node")
                    }
                }
                row(tech: .of("clt"), title: L("setup.appleTools"), detail: L("setup.appleToolsDetail"), done: store.appleTools) {
                    if waitingTools { ProgressView().controlSize(.small) }
                    Button {
                        waitingTools = true
                        store.installAppleTools()
                    } label: { Label(L("common.install"), systemImage: Symbols.install) }
                    .buttonStyle(.bordered)
                    .disabled(waitingTools).accessibilityIdentifier("setup.appleTools")
                }
            } header: {
                Text(L("setup.forWork"))
            } footer: {
                Text(L("setup.footer")).font(.uiCaption).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
        // The sheet is the background: no second surface behind the sections.
        .scrollContentBackground(.hidden)
        .task {
            if store.localTrust == nil { await store.refreshTrust() }
            await store.refreshAppleTools()
            // Says whether PHP's catalog can be reached; the picker loads each catalog itself.
            if store.phpCatalog.isEmpty { await store.loadPhpCatalog() }
        }
        // Apple's installer runs on its own; its tools show up here when it finishes.
        .task(id: waitingTools) {
            while waitingTools && !store.appleTools {
                try? await Task.sleep(for: .seconds(4))
                await store.refreshAppleTools()
            }
            waitingTools = false
        }
        .trustConfirmations(store: store, resolver: $confirmResolver, ca: $confirmCa)
        // The same catalog as the language and service pages: the source said above the button,
        // nothing downloaded until a version is picked and «Instalar» is pressed.
        .sheet(isPresented: Binding(get: { picking != nil }, set: { if !$0 { picking = nil } })) {
            if let picking {
                VersionPickerSheet(store: store, provider: picking == "php" ? .php(store) : .tool(store, picking), scope: "setup.\(picking)").themedSheet()
            }
        }
        .confirmationDialog(L("activation.confirmOn"), isPresented: $confirmAgent) {
            Button(L("activation.enable")) { Task { await store.installAgent() } }
            Button(L("common.cancel"), role: .cancel) {}
        } message: { Text(L("activation.confirmOnDetail")) }
    }

    private func installButton(_ id: String) -> some View {
        Button { picking = id } label: { Label(L("runtimes.installVersion"), systemImage: Symbols.install) }
            .buttonStyle(.bordered)
            .disabled(store.busy != nil)
            .accessibilityIdentifier("setup.install.\(id)")
    }

    private func row<Action: View>(tech: Tech? = nil, symbol: String = "", title: String, detail: String, done: Bool, @ViewBuilder action: () -> Action) -> some View {
        LabeledContent {
            HStack(spacing: 8) {
                if done {
                    Label(L("setup.ready"), systemImage: Symbols.success).foregroundStyle(Brand.success)
                } else {
                    action()
                }
            }
        } label: {
            Label {
                Text(title)
                Text(detail).frame(maxWidth: .infinity, alignment: .leading)
            } icon: {
                if let tech { TechLogo(tech: tech, size: 22) } else { IconTile(symbol: symbol, size: 22) }
            }
        }
    }
}
