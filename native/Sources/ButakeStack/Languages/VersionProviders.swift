import AppKit
import SwiftUI

/// The versions of each product Stack installs, read from the store: one provider per language and
/// per service, all drawn by `VersionsSection`.
extension VersionProvider {
    @MainActor static func language(_ name: String, store: StackStore) -> VersionProvider {
        switch name {
        case "php": php(store)
        case "python": python(store)
        case "rust": rust(store)
        case "swift": swift(store)
        case "java": tool(store, "jdk")
        default: tool(store, name)
        }
    }

    /// Stack's own static PHP builds, one per series; the catalog is Stack's `runtimes` release.
    @MainActor static func php(_ store: StackStore) -> VersionProvider {
        VersionProvider(
            id: "php", title: "PHP", logo: "php", lifecycle: "php",
            installed: store.phpRuntimes.filter(\.installed).map { runtime in
                InstalledVersion(id: runtime.series, version: runtime.manifest?.version ?? runtime.series, line: runtime.series,
                                 detail: runtime.manifest.map { String(format: L("runtimes.extensions"), $0.extensions.count) },
                                 global: runtime.series == store.globalPhp,
                                 problem: runtime.verified ? nil : L("runtimes.invalid"),
                                 folder: "runtimes/php/\(runtime.series)/bin")
            },
            catalog: store.phpCatalog.sorted { $0.version.compare($1.version, options: .numeric) == .orderedDescending }.map {
                CatalogVersion(id: $0.version, version: $0.version, line: $0.series, detail: $0.size_bytes.map { Format.fileSizeText(Int64($0)) })
            },
            catalogFailed: store.phpCatalogFailed,
            catalogError: store.catalogErrors["php"],
            source: L("php.source"),
            removeDetail: L("php.removeDetail"),
            load: { await store.loadPhpCatalog(refresh: $0) },
            install: FollowedInstall(log: "install-php", tool: "php") { try await store.downloadPhpFollowed($0.id) },
            // A line a project or the global setting uses is refused by the engine, which names them.
            remove: { await store.removePhp($0.id) },
            setGlobal: { await store.setGlobal("php", $0.id) },
            menu: { item in
                [VersionMenuItem(id: "ini", title: L("runtimes.openIni"), symbol: Symbols.file) { Folder.open("config/php/\(item.id)") }]
            }
        )
    }

    /// CPython lines from python-build-standalone, one build per line.
    @MainActor static func python(_ store: StackStore) -> VersionProvider {
        let global = store.globalVersion("python")
        return VersionProvider(
            id: "python", title: "Python", logo: "python", lifecycle: "python",
            installed: store.pythonRuntimes.map {
                InstalledVersion(id: $0.line, version: $0.version, line: $0.line, global: $0.line == global,
                                 folder: "runtimes/python/\($0.line)/bin")
            },
            catalog: store.pythonCatalog.map {
                CatalogVersion(id: $0.line, version: $0.version, line: $0.line, detail: $0.size_bytes.map { Format.fileSizeText(Int64($0)) })
            },
            catalogFailed: store.pythonCatalogFailed,
            catalogError: store.catalogErrors["python"],
            source: L("python.source"),
            removeDetail: L("python.removeDetail"),
            load: { await store.loadPythonCatalog(refresh: $0) },
            install: FollowedInstall(log: "install-python", tool: "python") { try await store.installPythonFollowed($0.id) },
            remove: { await store.removePython($0.id) },
            setGlobal: { await store.setGlobal("python", $0.id) }
        )
    }

    /// Products from the engine's catalog of official downloads: Node.js, the JDK, Caddy and every
    /// service (MySQL, Redis…). Node and the JDK have a global version: the major, so patches follow.
    @MainActor static func tool(_ store: StackStore, _ id: String) -> VersionProvider {
        let info = DownloadInfo.of(id)
        func line(_ version: String) -> String {
            if let cycle = store.cycle(id, for: version) { return cycle.cycle }
            let parts = version.split(separator: ".")
            return id == "node" || id == "postgres" ? String(parts.first ?? "") : parts.prefix(2).joined(separator: ".")
        }
        let hasGlobal = id == "node" || id == "jdk"
        let global = hasGlobal ? store.globalVersion(id) : nil
        var installed = (store.installedTools[id] ?? []).map { InstalledVersion(id: $0.version, version: $0.version, line: line($0.version)) }
        // The global names a line ("24") or a version: the newest installed of that line carries the mark.
        if let global, let index = installed.firstIndex(where: { $0.version == global || $0.line == global || $0.version.hasPrefix(global + ".") }) {
            installed[index].global = true
        }
        var setGlobal: (@MainActor (InstalledVersion) async -> Void)?
        if hasGlobal {
            setGlobal = { item in await store.setGlobal(id, String(item.version.split(separator: ".").first ?? "")) }
        }
        let catalog: [CatalogVersion] = (store.availableTools[id] ?? []).map {
            CatalogVersion(id: $0.version, version: $0.version, line: line($0.version), detail: $0.date)
        }
        return VersionProvider(
            id: info.id, title: info.title, logo: id == "jdk" ? "java" : id, lifecycle: info.id,
            installed: installed, catalog: catalog,
            source: String(format: L("runtimes.installDetail"), info.source + " · " + info.verification),
            load: { refresh in await store.loadAvailable(id, refresh: refresh) },
            install: FollowedInstall(log: "install-\(id)", tool: id) { entry in try await store.installToolFollowed(id, entry.id) },
            remove: { item in await store.removeTool(id, item.id) },
            setGlobal: setGlobal
        )
    }

    /// Rust toolchains through rustup: channels, or a version typed by hand.
    @MainActor static func rust(_ store: StackStore) -> VersionProvider {
        VersionProvider(
            id: "rust", title: "Rust", logo: "rust",
            installed: store.rustToolchains.map {
                InstalledVersion(id: $0.short, version: $0.short, line: $0.short, detail: $0.version.map { "rustc \($0)" },
                                 global: $0.default, removable: !$0.default)
            },
            catalog: ["stable", "beta", "nightly"].map { CatalogVersion(id: $0, version: $0, line: $0) },
            source: L("rust.source"),
            custom: CustomVersion(title: L("rust.specificVersion"), placeholder: "1.90", pattern: #"^\d+\.\d+(\.\d+)?$"#),
            requirement: store.devTools["rustup"]?.installed == true ? nil : "rustup",
            load: { _ in await store.loadRust() },
            install: FollowedInstall(log: "install-rust-toolchain", tool: "rust-toolchain") { try await store.installRustFollowed($0.id) },
            remove: { await store.rustAction("uninstall", $0.id) },
            setGlobal: { await store.rustAction("default", $0.id) }
        )
    }

    /// Swift toolchains through swiftly; Xcode's own toolchain is listed but stays Xcode's.
    @MainActor static func swift(_ store: StackStore) -> VersionProvider {
        let swift = store.swiftToolchains
        return VersionProvider(
            id: "swift", title: "Swift", logo: "swift",
            installed: (swift?.toolchains ?? []).map {
                let system = $0.kind == "system"
                return InstalledVersion(id: $0.name, version: $0.name, line: $0.name, name: system ? "Xcode" : nil,
                                        global: $0.default == true, removable: !system, canBeGlobal: !system)
            },
            catalog: (swift?.available ?? []).map {
                CatalogVersion(id: $0.name, version: $0.name, line: $0.name.split(separator: ".").prefix(2).joined(separator: "."))
            },
            source: L("swift.source"),
            requirement: swift?.installed == true ? nil : "swiftly",
            load: { _ in await store.loadSwift(available: true) },
            install: FollowedInstall(log: "install-swift-toolchain", tool: "swift-toolchain") { try await store.installSwiftFollowed($0.id) },
            remove: { await store.swiftAction("uninstall", $0.id) },
            setGlobal: { await store.swiftAction("default", $0.id) }
        )
    }
}

/// Where a product of the catalog is downloaded from and how it is verified.
struct DownloadInfo: Identifiable, Hashable {
    let id: String
    let title: String
    let source: String
    let verification: String
    @MainActor static func of(_ id: String) -> DownloadInfo {
        switch id {
        case "node": DownloadInfo(id: id, title: "Node.js", source: "nodejs.org", verification: L("verify.sha256"))
        case "mysql": DownloadInfo(id: id, title: "MySQL", source: "cdn.mysql.com", verification: L("verify.oracle"))
        case "redis": DownloadInfo(id: id, title: "Redis", source: "download.redis.io", verification: L("verify.redis"))
        case "postgres": DownloadInfo(id: id, title: "PostgreSQL", source: "ftp.postgresql.org", verification: L("verify.build"))
        case "mongodb": DownloadInfo(id: id, title: "MongoDB", source: "fastdl.mongodb.org", verification: L("verify.sha256"))
        case "valkey": DownloadInfo(id: id, title: "Valkey", source: "github.com/valkey-io", verification: L("verify.build"))
        case "meilisearch": DownloadInfo(id: id, title: "Meilisearch", source: "github.com/meilisearch", verification: L("verify.digest"))
        case "typesense": DownloadInfo(id: id, title: "Typesense", source: "dl.typesense.org", verification: L("verify.httpsOnly"))
        case "rustfs": DownloadInfo(id: id, title: "RustFS", source: "github.com/rustfs", verification: L("verify.sha256"))
        case "caddy": DownloadInfo(id: "caddy", title: "Caddy", source: "github.com/caddyserver", verification: L("verify.sha512"))
        case "java", "jdk": DownloadInfo(id: "jdk", title: "JDK", source: "adoptium.net (Eclipse Temurin)", verification: L("verify.sha256"))
        default: DownloadInfo(id: id, title: Tech.of(id).title, source: L("verify.official"), verification: L("verify.checksum"))
        }
    }
}
