import SwiftUI

/// "Preparar Butake Stack": everything the app needs on a new Mac, in order. Nothing is downloaded
/// without asking: each step shows its official source, lets the user pick the version and installs
/// only after confirming. Required steps first, recommended ones after.
struct SetupSheet: View {
    @Bindable var store: StackStore
    @Environment(\.dismiss) private var dismiss
    @State private var phpVersion = ""
    @State private var caddyVersion = ""
    @State private var nodeVersion = ""
    @State private var confirm: Pending?
    @State private var confirmAgent = false
    @State private var waitingTools = false

    struct Pending: Identifiable {
        let id: String
        let title: String
        let detail: String
        let run: () async -> Void
    }

    var nodeChoices: [AvailableVersion] {
        // LTS lines only, newest release of each: the sensible choices for projects.
        var seen = Set<String>()
        return (store.availableTools["node"] ?? []).filter { ($0.label ?? "").hasPrefix("LTS") && seen.insert($0.major).inserted }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                BrandMark(size: 46)
                VStack(alignment: .leading, spacing: 3) {
                    Text(L("setup.title")).font(.system(size: 20, weight: .bold, design: .rounded))
                    Text(L("setup.subtitle")).font(.uiCallout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            .padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    CardBlock(title: L("setup.required"), symbol: "checkmark.seal") {
                        step(tech: .of("php"), title: "PHP", detail: store.phpCatalogFailed ? L("setup.phpOffline") : L("setup.php"), done: store.phpReady) {
                            Picker("", selection: $phpVersion) {
                                ForEach(store.phpCatalog) { Text("PHP \($0.version)").tag($0.version) }
                            }
                            .labelsHidden().fixedSize().disabled(store.phpCatalog.isEmpty)
                            installButton("php", disabled: phpVersion.isEmpty) {
                                Pending(id: "php", title: String(format: L("runtimes.confirmInstall"), "PHP", phpVersion),
                                        detail: L("setup.phpSource")) { await store.downloadPhp(phpVersion) }
                            }
                        }
                        Divider()
                        step(tech: .of("web"), title: "Caddy", detail: L("setup.caddy"), done: store.caddyReady) {
                            Picker("", selection: $caddyVersion) {
                                ForEach((store.availableTools["caddy"] ?? []).prefix(8)) { Text($0.version).tag($0.version) }
                            }
                            .labelsHidden().fixedSize()
                            installButton("caddy", disabled: caddyVersion.isEmpty) {
                                let info = ToolInfo.of("caddy")
                                return Pending(id: "caddy", title: String(format: L("runtimes.confirmInstall"), "Caddy", caddyVersion),
                                               detail: String(format: L("runtimes.installDetail"), info.source + " · " + info.verification)) { await store.installTool("caddy", caddyVersion) }
                            }
                        }
                        Divider()
                        step(symbol: "network", title: L("activation.title"), detail: L("setup.agent"), done: store.agentReady) {
                            Button(L("activation.enable")) { confirmAgent = true }
                                .buttonStyle(.borderedProminent).controlSize(.small)
                                .disabled(!store.phpReady || !store.caddyReady || store.busy != nil)
                                .help(L("setup.agentNeeds")).accessibilityIdentifier("setup.agent")
                        }
                    }
                    CardBlock(title: L("setup.recommended"), symbol: "star") {
                        step(tech: .of("node"), title: "Node.js", detail: L("setup.node"), done: !(store.installedTools["node"] ?? []).isEmpty) {
                            Picker("", selection: $nodeVersion) {
                                ForEach(nodeChoices) { Text("\($0.version) · \($0.label ?? "")").tag($0.version) }
                            }
                            .labelsHidden().fixedSize()
                            installButton("node", disabled: nodeVersion.isEmpty) {
                                let info = ToolInfo.of("node")
                                return Pending(id: "node", title: String(format: L("runtimes.confirmInstall"), "Node.js", nodeVersion),
                                               detail: String(format: L("runtimes.installDetail"), info.source + " · " + info.verification)) { await store.installTool("node", nodeVersion) }
                            }
                        }
                        Divider()
                        step(symbol: "hammer.fill", title: L("setup.appleTools"), detail: L("setup.appleToolsDetail"), done: store.appleTools) {
                            if waitingTools { ProgressView().controlSize(.small) }
                            Button(L("setup.install")) {
                                waitingTools = true
                                store.installAppleTools()
                            }
                            .controlSize(.small).disabled(waitingTools).accessibilityIdentifier("setup.appleTools")
                        }
                    }
                    Text(L("setup.footer")).font(.uiCaption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .padding(20)
            }
            Divider()
            HStack {
                if let busy = store.busy { ProgressView().controlSize(.small); Text(busy).font(.uiCaption).foregroundStyle(.secondary) }
                Spacer()
                Button(store.setupComplete ? L("setup.done") : L("setup.later")) { dismiss() }
                    .keyboardShortcut(store.setupComplete ? .defaultAction : .cancelAction)
                    .accessibilityIdentifier("setup.close")
            }
            .padding(14)
        }
        .frame(width: 640, height: 640)
        .task {
            await store.refreshAppleTools()
            if store.phpCatalog.isEmpty { await store.loadPhpCatalog() }
            for tool in ["caddy", "node"] where (store.availableTools[tool] ?? []).isEmpty { await store.loadAvailable(tool) }
            phpVersion = phpVersion.isEmpty ? (store.phpCatalog.first?.version ?? "") : phpVersion
            caddyVersion = caddyVersion.isEmpty ? (store.availableTools["caddy"]?.first?.version ?? "") : caddyVersion
            nodeVersion = nodeVersion.isEmpty ? (nodeChoices.first?.version ?? "") : nodeVersion
        }
        // Apple's installer runs on its own; its tools show up here when it finishes.
        .task(id: waitingTools) {
            while waitingTools && !store.appleTools {
                try? await Task.sleep(for: .seconds(4))
                await store.refreshAppleTools()
            }
            waitingTools = false
        }
        .confirmationDialog(confirm?.title ?? "", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }), presenting: confirm) { item in
            Button(L("runtimes.install")) { Task { await item.run() } }.accessibilityIdentifier("setup.confirm")
        } message: { item in Text(item.detail) }
        .confirmationDialog(L("activation.confirmOn"), isPresented: $confirmAgent) {
            Button(L("activation.enable")) { Task { await store.installAgent() } }
        } message: { Text(L("activation.confirmOnDetail")) }
    }

    private func installButton(_ id: String, disabled: Bool, _ make: @escaping () -> Pending) -> some View {
        Button(L("setup.install")) { confirm = make() }
            .buttonStyle(.borderedProminent).controlSize(.small)
            .disabled(disabled || store.busy != nil)
            .accessibilityIdentifier("setup.install.\(id)")
    }

    private func step<Action: View>(tech: Tech? = nil, symbol: String = "", title: String, detail: String, done: Bool, @ViewBuilder action: () -> Action) -> some View {
        HStack(spacing: 12) {
            if let tech { TechLogo(tech: tech, size: 32) } else { IconTile(symbol: symbol, size: 32) }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.ui(size: 13, weight: .semibold))
                Text(detail).font(.uiCaption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 10)
            if done {
                Label(L("setup.ready"), systemImage: "checkmark.circle.fill").font(.uiCallout.weight(.medium)).foregroundStyle(Brand.success)
            } else {
                action()
            }
        }
        .padding(.vertical, 2)
    }
}
