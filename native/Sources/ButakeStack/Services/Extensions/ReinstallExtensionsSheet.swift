import SwiftUI

/// «Reinstalar con extensiones»: the installed PostgreSQL is built again with its standard
/// extensions and OpenSSL, followed step by step and stoppable. The data folder is not touched;
/// the old build stays until the new one is complete, and PostgreSQL restarts on it.
struct ReinstallExtensionsSheet: View {
    @Bindable var store: StackStore
    let version: String
    @State private var monitor = InstallMonitor(log: "install-postgres", tool: "postgres")
    let scope = "service.database.postgres.reinstall"

    var body: some View {
        SheetFrame(title: L("engine.reinstallTitle"), symbol: Symbols.database, width: TextScale.points(520), height: TextScale.points(440),
                   actionTitle: monitor.finished ? L("progress.close") : L("engine.reinstallExtensions"),
                   actionSymbol: monitor.finished ? nil : Symbols.install,
                   actionID: monitor.finished ? "\(scope).close" : "\(scope).confirm",
                   canAct: monitor.finished || (store.busy == nil && !monitor.running),
                   cancelID: monitor.finished ? nil : "\(scope).cancel",
                   action: {
                       if monitor.finished { return true }
                       monitor.start(store) { try await store.reinstallToolFollowed("postgres", version) }
                       return false
                   }) {
            if monitor.phase == .ready { confirmation } else {
                InstallProgressView(monitor: monitor, name: "PostgreSQL \(version)", scope: "\(scope).progress")
            }
        }
        .following(monitor)
    }

    private var confirmation: some View {
        Form {
            Section {
                LabeledContent(L("utilities.version"), value: version)
                LabeledContent(L("engine.reinstallIncludes"), value: L("engine.reinstallExtensionsList"))
            } footer: {
                Text(L("engine.reinstallDetail")).font(.uiCaption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}
