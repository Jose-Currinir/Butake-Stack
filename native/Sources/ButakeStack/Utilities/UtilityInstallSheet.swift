import SwiftUI

/// The confirmation before a utility is downloaded: which version, from where, how it is checked
/// and where it goes. The button names the version; nothing is downloaded until it is pressed.
/// Then the same sheet follows the install step by step. Every utility Stack installs opens it:
/// from the Utilidades page and from its row elsewhere (`ToolRow`: rustup, uv, the Android SDK…).
struct UtilityInstallSheet: View {
    @Bindable var store: StackStore
    let tool: String
    let updating: Bool
    @State private var shellPath = true
    @State private var monitor: InstallMonitor
    @Environment(\.dismiss) private var dismiss

    init(store: StackStore, tool: String, updating: Bool) {
        self.store = store
        self.tool = tool
        self.updating = updating
        _monitor = State(initialValue: InstallMonitor(log: "devtool-\(tool)", tool: tool))
    }

    var scope: String { "utilities.\(tool).sheet" }
    /// Built from its source with Apple's compiler, which is not on this Mac: nothing can start.
    var missingCompiler: Bool {
        UtilityCatalog.needsAppleTools.contains(tool) && (store.devTools["clt"]?.installed == false || !store.appleTools)
    }
    var name: String { L("tool.\(tool)") }
    /// The Android SDK asks to accept Google's licenses: the button says so and the sheet explains them.
    var licenses: Bool { tool == "android-sdk" }
    /// Command line utilities can go on the terminal's PATH; desktop apps and the SDK do not.
    var offersShellPath: Bool { UtilityCatalog.isCommand(tool) && !licenses }
    /// The version an install brings, when its source answered (it may arrive while the sheet is open).
    var version: String? { store.devUpdates.tools[tool].map(\.latest).flatMap { $0.isEmpty ? nil : $0 } }
    var actionTitle: String {
        if licenses && !updating { return L("tools.acceptAndInstall") }
        return switch (updating, version) {
        case (true, let version?): String(format: L("tools.updateTo"), version)
        case (false, let version?): String(format: L("runtimes.installNamed"), name, version)
        case (true, nil): L("tools.update")
        case (false, nil): String(format: L("utilities.installNamed"), name)
        }
    }

    /// «Git 2.56.1»: what the progress talks about.
    var named: String { version.map { "\(name) \($0)" } ?? name }

    var body: some View {
        SheetFrame(title: String(format: L(updating ? "utilities.updateTitle" : "utilities.installTitle"), name),
                   detail: L("toolDetail.\(tool)"), width: TextScale.points(520), height: TextScale.points(460),
                   actionTitle: monitor.finished ? L("progress.close") : actionTitle,
                   actionSymbol: monitor.finished ? nil : (updating ? Symbols.update : Symbols.install),
                   actionID: monitor.finished ? "\(scope).close" : "\(scope).install",
                   canAct: monitor.finished || (store.busy == nil && !missingCompiler && !monitor.running),
                   cancelID: monitor.finished ? nil : "\(scope).cancel",
                   action: {
                       if monitor.finished { return true }
                       let shell = offersShellPath && shellPath
                       let accepted = licenses
                       monitor.start(store) { try await store.installDevToolFollowed(tool, shellPath: shell, acceptLicenses: accepted) }
                       return false
                   }) {
            if monitor.phase == .ready { confirmation } else { InstallProgressView(monitor: monitor, name: named, scope: "\(scope).progress") }
        } status: {
            if let busy = store.busy, monitor.phase == .ready {
                Text(busy).font(.uiCaption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .following(monitor)
        .task { if version == nil { await store.refreshDevTools(refresh: true) } }
        #if DEBUG
        .task { await QAHooks.installProgress(monitor) }
        #endif
    }

    private var confirmation: some View {
            Form {
                if missingCompiler {
                    Section {
                        Notice(.warning, L("utilities.needsAppleTools"), detail: L("utilities.needsAppleToolsDetail")) {
                            // Apple's tools have their row in Lenguajes › Swift.
                            Button { dismiss(); store.route = .language("swift") } label: { Label(L("utilities.openAppleTools"), systemImage: Symbols.forward) }
                                .accessibilityIdentifier("\(scope).appleTools")
                        }
                    }
                }
                Section {
                    LabeledContent(L("utilities.version"), value: version ?? L("utilities.latest"))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L("utilities.source"))
                        Text(L("toolSource.\(tool)")).font(.uiCaption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    LabeledContent(L("utilities.placeLabel"), value: L("utilities.place.\(tool)"))
                }
                if licenses {
                    Section {
                        Text(L("tools.licenses")).font(.uiCaption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("\(scope).licenses")
                    }
                }
                if offersShellPath {
                    Section {
                        Toggle(L("utilities.shellPath"), isOn: $shellPath)
                            .help(L("utilities.shellPathHelp"))
                            .accessibilityIdentifier("\(scope).shellPath")
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
    }
}
