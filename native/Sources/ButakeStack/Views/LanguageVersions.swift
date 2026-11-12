import SwiftUI

// MARK: Models

/// A Python line installed by Stack (`runtimes/python/<line>`).
struct PythonRuntime: Decodable, Sendable, Hashable, Identifiable {
    let line: String
    let version: String
    let release: String
    var id: String { line }
}
/// The newest build of a Python line in python-build-standalone's newest release.
struct PythonCatalogEntry: Decodable, Sendable, Hashable, Identifiable {
    let line: String
    let version: String
    let release: String
    let size_bytes: Int?
    var id: String { line }
}
/// A language on the terminal through Stack's links (`~/.local/bin`).
struct TerminalLink: Decodable, Sendable, Hashable {
    let version: String?
}
struct RustToolchain: Decodable, Sendable, Hashable, Identifiable {
    let name: String
    let `default`: Bool
    let version: String?
    var id: String { name }
    /// "stable-aarch64-apple-darwin" -> "stable".
    var short: String { name.replacingOccurrences(of: "-aarch64-apple-darwin", with: "").replacingOccurrences(of: "-x86_64-apple-darwin", with: "") }
}
struct SwiftToolchains: Decodable, Sendable, Hashable {
    struct Toolchain: Decodable, Sendable, Hashable, Identifiable {
        let name: String
        let kind: String?
        let `default`: Bool?
        var id: String { name }
    }
    struct Available: Decodable, Sendable, Hashable, Identifiable {
        let name: String
        let installed: Bool?
        var id: String { name }
    }
    let installed: Bool
    let toolchains: [Toolchain]
    let available: [Available]
}
/// What the newest version of a framework needs and which lines Stack offers that meet it.
struct FrameworkRequirement: Decodable, Sendable, Hashable {
    let framework: String
    let language: String
    let requirement: String
    let lines: [String]
    let compatible: [String]
}

// MARK: Store actions

extension StackStore {
    func globalVersion(_ language: String) -> String? { config?.versions[language] }
    func setGlobal(_ language: String, _ version: String) async {
        await run(L("busy.saving")) {
            self.config = try await self.call(["method": "setGlobalVersion", "language": language, "version": version])
            self.notify(String(format: L("versions.globalSet"), version))
        }
        terminalLinks = (try? await call(["method": "terminalStatus"])) ?? terminalLinks
    }
    func loadPythonCatalog(refresh: Bool = false) async {
        do {
            pythonCatalog = try await call(["method": "pythonCatalog", "refresh": refresh])
            pythonCatalogFailed = false
        } catch { pythonCatalogFailed = pythonCatalog.isEmpty }
    }
    func installPython(_ line: String) async {
        await run(String(format: L("python.installing"), line)) {
            let _: JSONAny = try await self.call(["method": "installPython", "line": line, "confirmed": true])
            self.notify(L("toast.installed"))
        }
        await refreshRuntimes(); await refreshStatus()
    }
    func removePython(_ line: String) async {
        await run(L("busy.removing")) { let _: Bool = try await self.call(["method": "removePython", "line": line, "confirmed": true]) }
        await refreshRuntimes(); await refreshStatus()
    }
    func linkTerminal(_ language: String, _ version: String) async {
        await run(L("busy.saving")) {
            let _: JSONAny = try await self.call(["method": "linkTerminal", "language": language, "version": version, "confirmed": true])
            self.notify(L("terminal.linked"))
        }
        terminalLinks = (try? await call(["method": "terminalStatus"])) ?? terminalLinks
    }
    func unlinkTerminal(_ language: String) async {
        await run(L("busy.saving")) { let _: JSONAny = try await self.call(["method": "unlinkTerminal", "language": language, "confirmed": true]) }
        terminalLinks = (try? await call(["method": "terminalStatus"])) ?? [:]
    }
    func loadRust() async {
        rustToolchains = (try? await call(["method": "rustToolchains"])) ?? []
        rustLoaded = true
    }
    func rustAction(_ action: String, _ toolchain: String) async {
        await run(action == "install" ? String(format: L("rust.installing"), toolchain) : L("busy.saving")) {
            self.rustToolchains = try await self.call(["method": "rustToolchain", "action": action, "toolchain": toolchain, "confirmed": true])
        }
    }
    func loadSwift(available: Bool = false) async {
        swiftToolchains = (try? await call(["method": "swiftToolchains", "available": available])) ?? swiftToolchains
    }
    func swiftAction(_ action: String, _ version: String) async {
        await run(action == "install" ? String(format: L("swift.installing"), version) : L("busy.saving")) {
            let _: SwiftToolchains = try await self.call(["method": "swiftToolchain", "action": action, "version": version, "confirmed": true])
        }
        await loadSwift(available: true)
    }
    func installSwiftly() async {
        await run(String(format: L("tools.installing"), "swiftly")) {
            let _: JSONAny = try await self.call(["method": "installSwiftly", "confirmed": true])
            self.notify(String(format: L("tools.installed"), "swiftly"))
        }
        await loadSwift(available: true)
    }
    func loadRequirement(_ framework: String) async {
        if let value: FrameworkRequirement = try? await call(["method": "frameworkRequirement", "framework": framework]) { requirements[framework] = value }
    }
    /// The site's version of a language, in Stack and in the project's standard file.
    func setSiteVersion(_ id: String, _ language: String, _ version: String) async throws {
        let _: Project = try await call(["method": "setSiteVersion", "id": id, "language": language, "version": version])
    }
    /// Makes the site's `.venv` with its Python and installs its dependencies.
    func preparePython(_ id: String, manager: String = "pip", recreate: Bool = false) async {
        await run(L("python.preparing")) {
            let _: JSONAny = try await self.call(["method": "preparePython", "id": id, "manager": manager, "recreate": recreate])
            self.notify(L("python.prepared"))
        }
        await refreshStatus()
    }
}

// MARK: Python

/// Python lines installed by Stack (like PHP): global, update and remove; then the catalog.
struct PythonVersionsSection: View {
    @Bindable var store: StackStore
    @State private var pending: PythonCatalogEntry?
    @State private var removing: PythonRuntime?
    var installedLines: Set<String> { Set(store.pythonRuntimes.map(\.line)) }
    func newest(_ line: String) -> PythonCatalogEntry? { store.pythonCatalog.first { $0.line == line } }
    var body: some View {
        CardBlock(title: L("runtimes.installedVersions"), symbol: "checkmark.seal", footer: L("python.installedFooter")) {
            if store.pythonRuntimes.isEmpty { Text(L("python.none")).foregroundStyle(.secondary) }
            ForEach(Array(store.pythonRuntimes.enumerated()), id: \.element.id) { index, runtime in
                if index > 0 { Divider() }
                HStack(spacing: 10) {
                    VersionRow(version: "Python \(runtime.version)", detail: "", verified: true,
                               badges: runtime.line == store.globalVersion("python") ? [L("runtimes.global")] : [],
                               cycle: store.cycle("python", for: runtime.line)) {
                        Button { Task { await store.setGlobal("python", runtime.line) } } label: { Label(L("runtimes.useGlobal"), systemImage: "star") }
                            .disabled(runtime.line == store.globalVersion("python"))
                        if let update = newest(runtime.line), update.version != runtime.version {
                            Button { pending = update } label: { Label(String(format: L("versions.update"), update.version), systemImage: "arrow.up.circle") }
                        }
                        Button { Folder.open("runtimes/python/\(runtime.line)/bin") } label: { Label(L("runtimes.openBinary"), systemImage: "folder") }
                        Divider()
                        Button(role: .destructive) { removing = runtime } label: { Label(L("runtimes.remove"), systemImage: "trash") }
                    }
                    if let update = newest(runtime.line), update.version != runtime.version {
                        Button { pending = update } label: { Label(String(format: L("versions.update"), update.version), systemImage: "arrow.up.circle.fill") }
                            .buttonStyle(.borderedProminent).controlSize(.small).disabled(store.busy != nil)
                    }
                }
            }
        }
        CardBlock(title: L("python.catalog"), symbol: "arrow.down.circle", footer: L("python.catalogFooter")) {
            Button { Task { await store.loadPythonCatalog(refresh: true) } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless).help(L("runtimes.reloadCatalog")).disabled(store.busy != nil)
        } content: {
            if store.pythonCatalogFailed { Text(L("python.offline")).foregroundStyle(.secondary) }
            else if store.pythonCatalog.isEmpty { HStack { ProgressView().controlSize(.small); Text(L("busy.catalog")).foregroundStyle(.secondary) } }
            ForEach(Array(store.pythonCatalog.enumerated()), id: \.element.id) { index, entry in
                if index > 0 { Divider() }
                HStack(spacing: 10) {
                    Text("Python \(entry.version)").font(.ui(size: 13, weight: .semibold)).monospacedDigit()
                    if let cycle = store.cycle("python", for: entry.line) { LifecycleChip(cycle: cycle) }
                    Spacer()
                    if let bytes = entry.size_bytes { Text(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)).font(.uiCaption).foregroundStyle(.secondary) }
                    if installedLines.contains(entry.line) {
                        Label(L("runtimes.installed"), systemImage: "checkmark.seal.fill").font(.uiCaption).foregroundStyle(Brand.success)
                    } else {
                        Button { pending = entry } label: { Label(L("runtimes.install"), systemImage: "arrow.down.circle") }
                            .controlSize(.small).disabled(store.busy != nil).accessibilityIdentifier("python.install.\(entry.line)")
                    }
                }
            }
        }
        .task {
            await store.loadLifecycle("python")
            if store.pythonCatalog.isEmpty { await store.loadPythonCatalog() }
        }
        .confirmationDialog(pending.map { String(format: L("runtimes.confirmInstall"), "Python", $0.version) } ?? "", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), presenting: pending) { entry in
            Button(L("runtimes.install")) { Task { await store.installPython(entry.line) } }.accessibilityIdentifier("python.confirmInstall")
        } message: { _ in Text(L("python.source")) }
        .confirmationDialog(removing.map { String(format: L("runtimes.confirmRemove"), "Python \($0.version)") } ?? "", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), presenting: removing) { runtime in
            Button(L("runtimes.remove"), role: .destructive) { Task { await store.removePython(runtime.line) } }
        } message: { _ in Text(L("python.removeDetail")) }
    }
}

// MARK: Terminal

/// The global version on the terminal: symbolic links to the real binaries in `~/.local/bin`
/// (optional, asked first) and Stack's block in `~/.zprofile` for the PATH.
struct TerminalCard: View {
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
    var body: some View {
        CardBlock(title: L("terminal.title"), symbol: "terminal", footer: L("terminal.footer.\(language)")) {
            HStack(spacing: 10) {
                Image(systemName: linked != nil ? "checkmark.circle.fill" : "circle.dashed").foregroundStyle(linked != nil ? Brand.success : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    if let linked {
                        Text(String(format: L("terminal.linkedTo"), title, linked.version ?? "")).font(.ui(size: 13, weight: .semibold))
                        Text(L("terminal.followsGlobal")).font(.uiCaption).foregroundStyle(.secondary)
                    } else {
                        Text(String(format: L("terminal.notLinked"), title)).font(.ui(size: 13, weight: .semibold))
                        Text(L("terminal.notLinkedDetail")).font(.uiCaption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if linked != nil {
                    Button(L("terminal.remove")) { removing = true }.controlSize(.small).disabled(store.busy != nil)
                        .accessibilityIdentifier("terminal.remove.\(language)")
                } else {
                    Button { confirming = true } label: { Label(L("terminal.use"), systemImage: "terminal") }
                        .controlSize(.small).disabled(store.busy != nil || version == nil)
                        .accessibilityIdentifier("terminal.use.\(language)")
                }
            }
        }
        .confirmationDialog(String(format: L("terminal.confirm"), title, version ?? ""), isPresented: $confirming) {
            Button(L("terminal.use")) { if let version { Task { await store.linkTerminal(language, version) } } }
                .accessibilityIdentifier("terminal.confirm.\(language)")
        } message: { Text(L("terminal.confirmDetail.\(language)")) }
        .confirmationDialog(String(format: L("terminal.confirmRemove"), title), isPresented: $removing) {
            Button(L("terminal.remove"), role: .destructive) { Task { await store.unlinkTerminal(language) } }
        }
    }
}

// MARK: Rust

/// Rust toolchains through rustup: the global default and the ones a project can ask for in
/// `rust-toolchain.toml`.
struct RustToolchainsSection: View {
    @Bindable var store: StackStore
    @State private var channel = "stable"
    @State private var release = ""
    @State private var pending: String?
    @State private var removing: RustToolchain?
    var wanted: String { channel == "version" ? release.trimmingCharacters(in: .whitespaces) : channel }
    var validRelease: Bool { channel != "version" || release.range(of: #"^\d+\.\d+(\.\d+)?$"#, options: .regularExpression) != nil }
    var body: some View {
        CardBlock(title: L("rust.toolchains"), symbol: "square.stack.3d.up", footer: L("rust.footer")) {
            if store.devTools["rustup"]?.installed != true {
                Text(L("rust.needsRustup")).foregroundStyle(.secondary)
            } else {
                if store.rustLoaded && store.rustToolchains.isEmpty { Text(L("rust.none")).foregroundStyle(.secondary) }
                ForEach(Array(store.rustToolchains.enumerated()), id: \.element.id) { index, toolchain in
                    if index > 0 { Divider() }
                    VersionRow(version: toolchain.short, detail: toolchain.version.map { "rustc \($0)" } ?? "", verified: true,
                               badges: toolchain.default ? [L("runtimes.global")] : []) {
                        Button { Task { await store.rustAction("default", toolchain.short) } } label: { Label(L("runtimes.useGlobal"), systemImage: "star") }
                            .disabled(toolchain.default)
                        Button(role: .destructive) { removing = toolchain } label: { Label(L("runtimes.remove"), systemImage: "trash") }
                            .disabled(toolchain.default)
                    }
                }
                Divider()
                HStack(spacing: 8) {
                    Picker("", selection: $channel) {
                        Text("stable").tag("stable"); Text("beta").tag("beta"); Text("nightly").tag("nightly")
                        Text(L("rust.specificVersion")).tag("version")
                    }.labelsHidden().fixedSize()
                    if channel == "version" {
                        TextField("1.90", text: $release).textFieldStyle(.roundedBorder).frame(width: 90)
                    }
                    Spacer()
                    Button { pending = wanted } label: { Label(L("runtimes.install"), systemImage: "arrow.down.circle") }
                        .controlSize(.small).disabled(store.busy != nil || wanted.isEmpty || !validRelease)
                        .accessibilityIdentifier("rust.install")
                }
            }
        }
        .task { await store.loadRust() }
        .confirmationDialog(pending.map { String(format: L("runtimes.confirmInstall"), "Rust", $0) } ?? "", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), presenting: pending) { name in
            Button(L("runtimes.install")) { Task { await store.rustAction("install", name) } }
        } message: { _ in Text(L("rust.source")) }
        .confirmationDialog(removing.map { String(format: L("runtimes.confirmRemove"), $0.short) } ?? "", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), presenting: removing) { toolchain in
            Button(L("runtimes.remove"), role: .destructive) { Task { await store.rustAction("uninstall", toolchain.short) } }
        }
    }
}

// MARK: Swift

/// Swift toolchains through swiftly (swift.org's installer): several versions, a global default
/// and `.swift-version` per project. Xcode keeps its own toolchain.
struct SwiftToolchainsSection: View {
    @Bindable var store: StackStore
    @State private var confirmingSwiftly = false
    @State private var pending: String?
    @State private var removing: String?
    var body: some View {
        CardBlock(title: L("swift.toolchains"), symbol: "square.stack.3d.up", footer: L("swift.footer")) {
            if let swift = store.swiftToolchains, swift.installed {
                ForEach(Array(swift.toolchains.enumerated()), id: \.element.id) { index, toolchain in
                    if index > 0 { Divider() }
                    VersionRow(version: toolchain.kind == "system" ? "Xcode" : "Swift \(toolchain.name)", detail: "", verified: true,
                               badges: toolchain.default == true ? [L("runtimes.global")] : []) {
                        Button { Task { await store.swiftAction("default", toolchain.name) } } label: { Label(L("runtimes.useGlobal"), systemImage: "star") }
                            .disabled(toolchain.default == true || toolchain.kind == "system")
                        if toolchain.kind != "system" {
                            Button(role: .destructive) { removing = toolchain.name } label: { Label(L("runtimes.remove"), systemImage: "trash") }
                        }
                    }
                }
                let available = swift.available.filter { $0.installed != true }
                if !available.isEmpty { Divider() }
                ForEach(available.prefix(6)) { item in
                    HStack {
                        Text("Swift \(item.name)").font(.ui(size: 13, weight: .semibold)).monospacedDigit()
                        Spacer()
                        Button { pending = item.name } label: { Label(L("runtimes.install"), systemImage: "arrow.down.circle") }
                            .controlSize(.small).disabled(store.busy != nil).accessibilityIdentifier("swift.install.\(item.name)")
                    }
                }
            } else {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("swift.swiftly")).font(.ui(size: 13, weight: .semibold))
                        Text(L("swift.swiftlyDetail")).font(.uiCaption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { confirmingSwiftly = true } label: { Label(L("setup.install"), systemImage: "arrow.down.circle") }
                        .controlSize(.small).disabled(store.busy != nil).accessibilityIdentifier("swift.installSwiftly")
                }
            }
        }
        .task { await store.loadSwift(available: true) }
        .confirmationDialog(String(format: L("runtimes.confirmInstall"), "swiftly", ""), isPresented: $confirmingSwiftly) {
            Button(L("setup.install")) { Task { await store.installSwiftly() } }
        } message: { Text(L("swift.swiftlySource")) }
        .confirmationDialog(pending.map { String(format: L("runtimes.confirmInstall"), "Swift", $0) } ?? "", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), presenting: pending) { name in
            Button(L("runtimes.install")) { Task { await store.swiftAction("install", name) } }
        } message: { _ in Text(L("swift.source")) }
        .confirmationDialog(removing.map { String(format: L("runtimes.confirmRemove"), "Swift \($0)") } ?? "", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), presenting: removing) { name in
            Button(L("runtimes.remove"), role: .destructive) { Task { await store.swiftAction("uninstall", name) } }
        }
    }
}
