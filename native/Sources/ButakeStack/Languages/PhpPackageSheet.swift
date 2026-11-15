import SwiftUI

/// A PHP package chosen on this Mac.
struct PhpPackage: Identifiable {
    let url: URL
    var id: URL { url }
}

/// «Instalar paquete…»: the package chosen, what is checked before it is placed, and then the same
/// step-by-step progress as an install from the catalog (`InstallMonitor`).
struct PhpPackageSheet: View {
    @Bindable var store: StackStore
    let chosen: PhpPackage
    @State private var monitor = InstallMonitor(log: "install-php-package", tool: "php-package")
    let scope = "language.php.package.sheet"

    /// «8.4.3» from `php-8.4.3-macos-arm64.tar.gz`.
    var version: String {
        chosen.url.lastPathComponent.replacingOccurrences(of: "php-", with: "").replacingOccurrences(of: "-macos-arm64.tar.gz", with: "")
    }

    var body: some View {
        SheetFrame(title: L("php.packageTitle"), symbol: Symbols.package, width: TextScale.points(520), height: TextScale.points(400),
                   actionTitle: monitor.finished ? L("progress.close") : String(format: L("runtimes.installNamed"), "PHP", version),
                   actionSymbol: monitor.finished ? nil : Symbols.install,
                   actionID: monitor.finished ? "\(scope).close" : "\(scope).install",
                   canAct: monitor.finished || (store.busy == nil && !monitor.running),
                   cancelID: monitor.finished ? nil : "\(scope).cancel",
                   action: {
                       if monitor.finished { return true }
                       let url = chosen.url
                       monitor.start(store) { try await store.installPhpPackageFollowed(url) }
                       return false
                   }) {
            if monitor.phase == .ready { confirmation } else {
                InstallProgressView(monitor: monitor, name: "PHP \(version)", scope: "\(scope).progress")
            }
        }
        .following(monitor)
    }

    private var confirmation: some View {
        Form {
            Section {
                LabeledContent(L("php.packageFile")) {
                    Text(chosen.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                        .help(chosen.url.path)
                }
                LabeledContent(L("php.packageCheck"), value: L("php.packageCheckDetail"))
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}
