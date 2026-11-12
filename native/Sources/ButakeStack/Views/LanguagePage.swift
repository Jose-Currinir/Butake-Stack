import AppKit
import SwiftUI

/// PHP or Node: installed versions, which sites use them and the official catalog.
struct LanguagePage: View {
    @Bindable var store: StackStore
    let name: String
    var tech: Tech { .of(name) }
    var body: some View {
        PageScroll {
            HeaderCard(tech: tech, title: tech.title, subtitle: L("language.\(name).summary")) { EmptyView() }
            LazyVGrid(columns: pageColumns, alignment: .leading, spacing: 22) {
                if name == "php" {
                    CardBlock(title: L("runtimes.installedVersions"), symbol: "checkmark.seal", footer: L("runtimes.phpHelp")) {
                        Button { store.installPhpPackage() } label: { Label(L("runtimes.installPackage"), systemImage: "plus") }.controlSize(.small)
                    } content: {
                        ForEach(Array(store.phpRuntimes.enumerated()), id: \.element.id) { index, runtime in
                            if index > 0 { Divider() }
                            VersionRow(
                                version: runtime.manifest?.version ?? runtime.series,
                                detail: runtime.manifest.map { String(format: L("runtimes.extensions"), $0.extensions.count) } ?? "",
                                verified: runtime.verified,
                                badges: runtime.series == store.globalPhp ? [L("runtimes.global")] : [],
                                cycle: store.cycle("php", for: runtime.series)
                            ) {
                                Button { Task { await store.setGlobalPhp(runtime.series) } } label: { Label(L("runtimes.useGlobal"), systemImage: "star") }
                                    .disabled(runtime.series == store.globalPhp)
                                Button { Folder.open("runtimes/php/\(runtime.series)/bin") } label: { Label(L("runtimes.openBinary"), systemImage: "folder") }
                                Button { Folder.open("config/php/\(runtime.series)") } label: { Label(L("runtimes.openIni"), systemImage: "doc.text") }
                            }
                        }
                    }
                    PhpCatalogSection(store: store)
                } else {
                    VersionsSection(store: store, info: ToolInfo.of(name))
                }
                CardBlock(title: L("engine.sites"), symbol: "globe") {
                    let users = store.projects.filter { name == "php" ? $0.php != nil : $0.node != nil }
                    if users.isEmpty { Text(L("engine.noSites")).foregroundStyle(.secondary) }
                    ForEach(Array(users.enumerated()), id: \.element.id) { index, project in
                        if index > 0 { Divider() }
                        SiteLinkRow(project: project, detail: "\(tech.title) \((name == "php" ? project.php : project.node) ?? "")") { store.openSite(project.id) }
                    }
                }
            }
        }
        .task { await store.refreshRuntimes(); await store.loadLifecycle("php") }
    }
}

/// PHP builds published by Butake Stack (release `runtimes`), one per line; installing one asks first.
private struct PhpCatalogSection: View {
    @Bindable var store: StackStore
    @State private var pending: PhpCatalogEntry?
    var installedSeries: Set<String> { Set(store.phpRuntimes.filter(\.installed).map(\.series)) }
    var body: some View {
        CardBlock(title: L("php.catalog"), symbol: "arrow.down.circle", footer: L("php.catalogFooter")) {
            Button { Task { await store.loadPhpCatalog(refresh: true) } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless).help(L("runtimes.reloadCatalog")).disabled(store.busy != nil)
        } content: {
            if store.phpCatalogFailed { Text(L("setup.phpOffline")).foregroundStyle(.secondary) }
            else if store.phpCatalog.isEmpty { HStack { ProgressView().controlSize(.small); Text(L("busy.catalog")).foregroundStyle(.secondary) } }
            ForEach(Array(store.phpCatalog.sorted { $0.version.compare($1.version, options: .numeric) == .orderedDescending }.enumerated()), id: \.element.id) { index, entry in
                if index > 0 { Divider() }
                HStack(spacing: 10) {
                    Text("PHP \(entry.version)").font(.ui(size: 13, weight: .semibold)).monospacedDigit()
                    if let cycle = store.cycle("php", for: entry.series) { LifecycleChip(cycle: cycle) }
                    Spacer()
                    if let bytes = entry.size_bytes { Text(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)).font(.uiCaption).foregroundStyle(.secondary) }
                    if installedSeries.contains(entry.series) {
                        Label(L("runtimes.installed"), systemImage: "checkmark.seal.fill").font(.uiCaption).foregroundStyle(Brand.success)
                    } else {
                        Button { pending = entry } label: { Label(L("runtimes.install"), systemImage: "arrow.down.circle") }
                            .controlSize(.small).disabled(store.busy != nil).accessibilityIdentifier("php.install.\(entry.version)")
                    }
                }
            }
        }
        .task { if store.phpCatalog.isEmpty { await store.loadPhpCatalog() } }
        .confirmationDialog(pending.map { String(format: L("runtimes.confirmInstall"), "PHP", $0.version) } ?? "", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), presenting: pending) { entry in
            Button(L("runtimes.install")) { Task { await store.downloadPhp(entry.version) } }
        } message: { _ in Text(L("setup.phpSource")) }
    }
}

enum Folder {
    static func open(_ relative: String) {
        let base = ProcessInfo.processInfo.environment["BUTAKE_STACK_HOME"] ?? NSHomeDirectory() + "/Library/Application Support/Butake Stack"
        NSWorkspace.shared.open(URL(fileURLWithPath: base + "/" + relative))
    }
}

struct ToolInfo: Identifiable, Hashable {
    let id: String
    let title: String
    let source: String
    let verification: String
    @MainActor static func of(_ id: String) -> ToolInfo {
        switch id {
        case "node": ToolInfo(id: id, title: "Node.js", source: "nodejs.org", verification: L("verify.sha256"))
        case "mysql": ToolInfo(id: id, title: "MySQL", source: "cdn.mysql.com", verification: L("verify.oracle"))
        case "redis": ToolInfo(id: id, title: "Redis", source: "download.redis.io", verification: L("verify.redis"))
        case "postgres": ToolInfo(id: id, title: "PostgreSQL", source: "ftp.postgresql.org", verification: L("verify.build"))
        case "mongodb": ToolInfo(id: id, title: "MongoDB", source: "fastdl.mongodb.org", verification: L("verify.sha256"))
        case "valkey": ToolInfo(id: id, title: "Valkey", source: "github.com/valkey-io", verification: L("verify.build"))
        case "meilisearch": ToolInfo(id: id, title: "Meilisearch", source: "github.com/meilisearch", verification: L("verify.digest"))
        case "typesense": ToolInfo(id: id, title: "Typesense", source: "dl.typesense.org", verification: L("verify.httpsOnly"))
        case "rustfs": ToolInfo(id: id, title: "RustFS", source: "github.com/rustfs", verification: L("verify.sha256"))
        case "caddy": ToolInfo(id: "caddy", title: "Caddy", source: "github.com/caddyserver", verification: L("verify.sha512"))
        default: ToolInfo(id: id, title: Tech.of(id).title, source: L("verify.official"), verification: L("verify.checksum"))
        }
    }
}

/// Versions grouped by release line, like a release train: each line shows its support status
/// (LTS, active, maintenance, end of life), what is installed and one clear action. Only what
/// matters is in view (installed lines, the newest line and supported LTS lines); older lines
/// wait under "Más versiones".
struct VersionsSection: View {
    @Bindable var store: StackStore
    let info: ToolInfo
    @State private var removing: ToolManifest?
    @State private var pending: AvailableVersion?
    @State private var showAll = false
    var installed: [ToolManifest] { store.installedTools[info.id] ?? [] }
    var available: [AvailableVersion] { store.availableTools[info.id] ?? [] }
    /// Line of a version: the lifecycle cycle that matches it, else its major (minor for MySQL/Redis-like).
    func line(_ version: String) -> String {
        if let cycle = store.cycle(info.id, for: version) { return cycle.cycle }
        let parts = version.split(separator: ".")
        return info.id == "node" || info.id == "postgres" ? String(parts.first ?? "") : parts.prefix(2).joined(separator: ".")
    }
    var lines: [String] {
        var order: [String] = []
        for v in installed.map(\.version) + available.map(\.version) where !order.contains(line(v)) { order.append(line(v)) }
        return order.sorted { $0.split(separator: ".").compactMap { Int($0) }.lexicographicallyPrecedes($1.split(separator: ".").compactMap { Int($0) }) == false }
    }
    func cycle(_ line: String) -> Cycle? { store.lifecycles[info.id]?.first { $0.cycle == line } }
    func primary(_ name: String, at index: Int) -> Bool {
        index == 0 || installed.contains { line($0.version) == name } || cycle(name)?.status == .lts
    }
    var body: some View {
        let all = lines
        let main = all.enumerated().filter { primary($0.element, at: $0.offset) }.map(\.element)
        let rest = all.filter { !main.contains($0) }
        CardBlock(title: L("versions.title"), symbol: "square.stack.3d.up", footer: String(format: L("versions.footer"), info.source, info.verification)) {
            Button { Task { await store.loadAvailable(info.id, refresh: true) } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless).help(L("runtimes.reloadCatalog")).disabled(store.busy != nil)
        } content: {
            if all.isEmpty {
                HStack { ProgressView().controlSize(.small); Text(L("busy.catalog")).foregroundStyle(.secondary) }
            }
            ForEach(Array(main.enumerated()), id: \.element) { index, name in
                if index > 0 { Divider() }
                row(name)
            }
            if !rest.isEmpty {
                Divider()
                DisclosureGroup(isExpanded: $showAll) {
                    ForEach(rest, id: \.self) { name in
                        Divider()
                        row(name)
                    }
                } label: {
                    Text(String(format: L("versions.more"), rest.count)).font(.uiCallout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        .onTapGesture { withAnimation(.snappy(duration: 0.22)) { showAll.toggle() } }
                }
                .accessibilityIdentifier("versions.more.\(info.id)")
            }
        }
        .task(id: info.id) {
            await store.loadLifecycle(info.id)
            if available.isEmpty { await store.loadAvailable(info.id) }
        }
        .confirmationDialog(pending.map { String(format: L("runtimes.confirmInstall"), info.title, $0.version) } ?? "", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), presenting: pending) { item in
            Button(L("runtimes.install")) { Task { await store.installTool(info.id, item.version) } }.accessibilityIdentifier("runtime.confirmInstall")
        } message: { _ in Text(String(format: L("runtimes.installDetail"), info.source + " · " + info.verification)) }
        .confirmationDialog(removing.map { String(format: L("runtimes.confirmRemove"), $0.version) } ?? "", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), presenting: removing) { item in
            Button(L("runtimes.remove"), role: .destructive) { Task { await store.removeTool(item.tool, item.version) } }
        }
    }
    private func row(_ name: String) -> some View {
        ReleaseLine(store: store, info: info, line: name,
                    installed: installed.filter { line($0.version) == name },
                    available: available.filter { line($0.version) == name },
                    cycle: cycle(name),
                    install: { pending = $0 }, remove: { removing = $0 })
    }
}

private struct ReleaseLine: View {
    let store: StackStore
    let info: ToolInfo
    let line: String
    let installed: [ToolManifest]
    let available: [AvailableVersion]
    let cycle: Cycle?
    let install: (AvailableVersion) -> Void
    let remove: (ToolManifest) -> Void
    @State private var expanded = false
    @State private var hovering = false
    var newest: AvailableVersion? { available.first }
    var current: ToolManifest? { installed.first }
    var updatable: AvailableVersion? {
        guard let current, let newest else { return nil }
        return newest.version.split(separator: ".").compactMap { Int($0) }.lexicographicallyPrecedes(current.version.split(separator: ".").compactMap { Int($0) }) || newest.version == current.version ? nil : newest
    }
    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            ForEach(available) { version in
                HStack(spacing: 10) {
                    Text(version.version).font(.ui(size: 12.5, weight: .medium)).monospacedDigit()
                    if let date = version.date { Text(date).font(.uiCaption).foregroundStyle(.tertiary) }
                    Spacer()
                    if let item = installed.first(where: { $0.version == version.version }) {
                        Label(L("runtimes.installed"), systemImage: "checkmark.seal.fill").font(.uiCaption).foregroundStyle(Brand.success)
                        Button(role: .destructive) { remove(item) } label: { Image(systemName: "trash") }.buttonStyle(.borderless).help(L("runtimes.remove"))
                    } else {
                        Button { install(version) } label: { Label(L("versions.download"), systemImage: "arrow.down.circle") }
                            .controlSize(.small).disabled(store.busy != nil).accessibilityIdentifier("catalog.install.\(version.version)")
                    }
                }
                .padding(.leading, 4).padding(.vertical, 1)
            }
            ForEach(installed.filter { item in !available.contains { $0.version == item.version } }) { item in
                HStack {
                    Text(item.version).font(.ui(size: 12.5, weight: .medium)).monospacedDigit()
                    Spacer()
                    Label(L("runtimes.installed"), systemImage: "checkmark.seal.fill").font(.uiCaption).foregroundStyle(Brand.success)
                    Button(role: .destructive) { remove(item) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                }
                .padding(.leading, 4)
            }
        } label: {
            HStack(spacing: 10) {
                Text("\(info.title) \(line)").font(.ui(size: 13, weight: .semibold))
                if let cycle { LifecycleChip(cycle: cycle) }
                Spacer()
                if let current {
                    Label(current.version, systemImage: "checkmark.seal.fill").font(.uiCaption.monospacedDigit()).foregroundStyle(Brand.success)
                }
                if let updatable {
                    Button { install(updatable) } label: { Label(String(format: L("versions.update"), updatable.version), systemImage: "arrow.up.circle.fill") }
                        .buttonStyle(.borderedProminent).controlSize(.small).disabled(store.busy != nil)
                } else if current == nil, let newest {
                    // Quiet until the pointer is on the row: a column of identical buttons is noise.
                    if hovering {
                        Button { install(newest) } label: { Label(String(format: L("versions.installVersion"), newest.version), systemImage: "arrow.down.circle") }
                            .controlSize(.small).disabled(store.busy != nil).accessibilityIdentifier("line.install.\(info.id).\(line)")
                    } else {
                        Text(newest.version).font(.uiCaption.monospacedDigit()).foregroundStyle(.tertiary)
                    }
                }
            }
            .frame(minHeight: 22)
            // The whole row toggles, not only the disclosure arrow.
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.snappy(duration: 0.22)) { expanded.toggle() } }
            .onHover { hovering = $0 }
            .help(expanded ? L("versions.collapse") : L("versions.expand"))
        }
    }
}

struct LifecycleChip: View {
    let cycle: Cycle
    var body: some View {
        switch cycle.status {
        case .lts: Chip(text: "LTS" + until, symbol: "shield.fill", tint: Brand.success)
        case .active: Chip(text: L("lifecycle.active") + until, symbol: "bolt.fill", tint: Brand.info)
        case .maintenance: Chip(text: L("lifecycle.maintenance") + until, symbol: "wrench.adjustable", tint: Brand.warning)
        case .ended: Chip(text: L("lifecycle.ended"), symbol: "xmark.octagon.fill", tint: Brand.danger)
        }
    }
    var until: String { cycle.eolDate.map { " · " + String(format: L("lifecycle.until"), $0) } ?? "" }
}

struct VersionRow<MenuContent: View>: View {
    let version: String
    let detail: String
    let verified: Bool
    let badges: [String]
    var cycle: Cycle? = nil
    @ViewBuilder let menu: MenuContent
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: verified ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(verified ? Brand.success : Brand.warning)
                .help(verified ? L("runtimes.installed") : L("runtimes.invalid"))
            Text(version).font(.ui(size: 13, weight: .semibold)).monospacedDigit()
            ForEach(badges, id: \.self) { Chip(text: $0, tint: Brand.accent) }
            if let cycle { LifecycleChip(cycle: cycle) }
            Spacer()
            if !detail.isEmpty { Text(detail).font(.uiCaption).foregroundStyle(.secondary) }
            Menu { menu } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityIdentifier("runtime.menu.\(version)")
        }
        .padding(.vertical, 2)
    }
}
