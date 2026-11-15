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
    let versions: [FrameworkVersion]?
}
/// A supported line of a framework (Django 5.2, Laravel 12) and the language lines it accepts.
struct FrameworkVersion: Decodable, Sendable, Hashable, Identifiable {
    let cycle: String
    let latest: String?
    let lts: Flex?
    let requirement: String
    let compatible: [String]
    var id: String { cycle }
    var isLts: Bool { if case .flag(true) = lts { true } else if case .date = lts { true } else { false } }
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
            catalogErrors["python"] = nil
        } catch {
            pythonCatalogFailed = pythonCatalog.isEmpty
            catalogErrors["python"] = EngineFailure.message(error)
        }
    }
    func installPythonFollowed(_ line: String) async throws {
        defer { Task { await self.refreshRuntimes(); await self.refreshStatus() } }
        let _: JSONValue = try await stoppableCall(["method": "installPython", "line": line, "confirmed": true])
    }
    func removePython(_ line: String) async {
        await run(L("busy.removing")) { let _: Bool = try await self.call(["method": "removePython", "line": line, "confirmed": true]) }
        await refreshRuntimes(); await refreshStatus()
    }
    func linkTerminal(_ language: String, _ version: String) async {
        await run(L("busy.saving")) {
            let _: JSONValue = try await self.call(["method": "linkTerminal", "language": language, "version": version, "confirmed": true])
            self.notify(L("terminal.linked"))
        }
        terminalLinks = (try? await call(["method": "terminalStatus"])) ?? terminalLinks
    }
    func unlinkTerminal(_ language: String) async {
        await run(L("busy.saving")) { let _: JSONValue = try await self.call(["method": "unlinkTerminal", "language": language, "confirmed": true]) }
        terminalLinks = (try? await call(["method": "terminalStatus"])) ?? [:]
    }
    func loadRust() async {
        rustToolchains = (try? await call(["method": "rustToolchains"])) ?? []
        rustLoaded = true
    }
    func rustAction(_ action: String, _ toolchain: String) async {
        await run(L("busy.saving")) {
            self.rustToolchains = try await self.call(["method": "rustToolchain", "action": action, "toolchain": toolchain, "confirmed": true])
        }
    }
    /// A toolchain through rustup, followed by the picker (`InstallMonitor`); rustup's own step is
    /// not cut, so «Cancelar» is off while it runs.
    func installRustFollowed(_ toolchain: String) async throws {
        rustToolchains = try await stoppableCall(["method": "rustToolchain", "action": "install", "toolchain": toolchain, "confirmed": true])
    }
    func loadSwift(available: Bool = false) async {
        swiftToolchains = (try? await call(["method": "swiftToolchains", "available": available])) ?? swiftToolchains
    }
    func swiftAction(_ action: String, _ version: String) async {
        await run(L("busy.saving")) {
            let _: SwiftToolchains = try await self.call(["method": "swiftToolchain", "action": action, "version": version, "confirmed": true])
        }
        await loadSwift(available: true)
    }
    /// A toolchain through swiftly, followed by the picker like Rust's.
    func installSwiftFollowed(_ version: String) async throws {
        defer { Task { await self.loadSwift(available: true) } }
        let _: SwiftToolchains = try await stoppableCall(["method": "swiftToolchain", "action": "install", "version": version, "confirmed": true])
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
            let _: JSONValue = try await self.call(["method": "preparePython", "id": id, "manager": manager, "recreate": recreate])
            self.notify(L("python.prepared"))
        }
        await refreshStatus()
    }
}
