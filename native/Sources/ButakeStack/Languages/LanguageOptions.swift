import SwiftUI

/// What each language offers beyond its versions: Xdebug and local packages in PHP, the package
/// manager in Python, the toolchain utilities of Rust and Swift, and the terminal's link.
struct LanguageOptionsSection: View {
    @Bindable var store: StackStore
    let language: String
    var scope: String { "language.\(language)" }
    /// Engine id of the terminal's link and the versions it can link.
    var terminal: (id: String, title: String, installed: [String])? {
        switch language {
        case "php": ("php", "PHP", store.phpRuntimes.filter(\.verified).map(\.series))
        case "python": ("python", "Python", store.pythonRuntimes.map(\.line))
        case "node": ("node", "Node.js", (store.installedTools["node"] ?? []).map(\.version))
        case "java": ("jdk", "Java", (store.installedTools["jdk"] ?? []).map(\.version))
        default: nil
        }
    }
    /// Utilities of the language that are not the requirement of its versions (that one is said there).
    var utilities: [String] {
        switch language {
        case "python": ["uv"]
        case "rust": store.devTools["rustup"]?.installed == true ? ["rustup"] : []
        case "swift": ["xcode", "clt"] + (store.swiftToolchains?.installed == true ? ["swiftly"] : [])
        default: []
        }
    }
    var phpLines: [PhpRuntimeSummary] { language == "php" ? store.phpRuntimes.filter(\.verified) : [] }
    /// A package chosen on this Mac, confirmed and followed in its sheet.
    @State private var phpPackage: PhpPackage?

    var body: some View {
        let terminal = terminal.flatMap { $0.installed.isEmpty ? nil : $0 }
        if terminal != nil || !utilities.isEmpty || language == "php" {
            Section(L("language.options")) {
                ForEach(phpLines) { XdebugRow(store: store, runtime: $0) }
                if let terminal {
                    TerminalRow(store: store, language: terminal.id, title: terminal.title, installed: terminal.installed)
                }
                ForEach(utilities, id: \.self) { ToolRow(store: store, tool: $0, padded: false) }
                if language == "php" {
                    LabeledContent {
                        Button { phpPackage = store.choosePhpPackage().map(PhpPackage.init) } label: {
                            Label(L("runtimes.installPackage"), systemImage: Symbols.package)
                        }
                            .disabled(store.busy != nil)
                            .accessibilityIdentifier("\(scope).package")
                    } label: {
                        Text(L("php.package"))
                        Text(L("php.packageDetail"))
                    }
                    .help(L("runtimes.packageHelp"))
                }
            }
            .sheet(item: $phpPackage) { PhpPackageSheet(store: store, chosen: $0).themedSheet() }
        }
    }
}

/// Xdebug of one PHP line: on/off and its mode. Turning it on rewrites that line's php.ini and
/// restarts only its PHP-FPM.
struct XdebugRow: View {
    @Bindable var store: StackStore
    let runtime: PhpRuntimeSummary
    static let modes = ["debug", "develop", "coverage", "debug,develop"]
    var body: some View {
        LabeledContent {
            if runtime.xdebug == true {
                HStack(spacing: 8) {
                    if let mode = runtime.xdebug_mode {
                        Picker(L("xdebug.modeLabel"), selection: Binding(get: { mode }, set: { value in Task { await store.setXdebug(runtime.series, mode: value) } })) {
                            ForEach(Self.modes, id: \.self) { Text(L("xdebug.mode.\($0)")).tag($0) }
                        }
                        .labelsHidden().fixedSize()
                        .accessibilityIdentifier("language.php.xdebug.\(runtime.series).mode")
                    }
                    Toggle(String(format: L("xdebug.toggle"), runtime.series), isOn: Binding(get: { runtime.xdebug_mode != nil }, set: { on in Task { await store.setXdebug(runtime.series, mode: on ? "debug" : nil) } }))
                        .toggleStyle(.switch).labelsHidden().disabled(store.busy != nil)
                        .accessibilityIdentifier("language.php.xdebug.\(runtime.series).toggle")
                }
            } else {
                Text(L("xdebug.notInBuild")).foregroundStyle(.secondary)
            }
        } label: {
            Text(String(format: L("xdebug.toggle"), runtime.series))
        }
        .help(L("xdebug.footer") + " " + L("xdebug.footerHelp"))
    }
}

/// The global version on the terminal: symbolic links to the real binaries in `~/.local/bin`
/// (optional, asked first) and Stack's block in `~/.zprofile` for the PATH.
struct TerminalRow: View {
    @Bindable var store: StackStore
    /// Engine id: php, node, jdk or python.
    let language: String
    let title: String
    let installed: [String]
    @State private var confirming = false
    @State private var removing = false
    /// The version the terminal would use: the global one if installed, else the newest.
    var version: String? {
        if let global = store.globalVersion(language), installed.contains(where: { $0 == global || $0.hasPrefix(global + ".") }) { return global }
        return installed.first
    }
    var linked: TerminalLink? { store.terminalLinks[language] }
    /// The language page the row is on (the JDK lives on «Java y Kotlin»).
    var page: String { language == "jdk" ? "java" : language }
    var body: some View {
        LabeledContent {
            if linked != nil {
                Button { removing = true } label: { Label(L("terminal.remove"), systemImage: Symbols.remove) }
                    .disabled(store.busy != nil)
                    .accessibilityIdentifier("language.\(page).terminal.remove")
            } else {
                Button { confirming = true } label: { Label(L("terminal.use"), systemImage: Symbols.terminal) }
                    .disabled(store.busy != nil || version == nil)
                    .accessibilityIdentifier("language.\(page).terminal.use")
            }
        } label: {
            Text(L("terminal.title"))
            if let linked {
                Text(String(format: L("terminal.linkedTo"), title, linked.version ?? ""))
            } else {
                Text(L("terminal.notLinkedDetail"))
            }
        }
        .help(L("terminal.footer.\(language)"))
        .confirmationDialog(String(format: L("terminal.confirm"), title, version ?? ""), isPresented: $confirming) {
            Button(L("terminal.use")) { if let version { Task { await store.linkTerminal(language, version) } } }
                .accessibilityIdentifier("language.\(page).terminal.confirm")
            Button(L("common.cancel"), role: .cancel) {}
        } message: { Text(L("terminal.confirmDetail.\(language)")) }
        .confirmationDialog(String(format: L("terminal.confirmRemove"), title), isPresented: $removing) {
            Button(L("terminal.remove"), role: .destructive) { Task { await store.unlinkTerminal(language) } }
            Button(L("common.cancel"), role: .cancel) {}
        }
    }
}
