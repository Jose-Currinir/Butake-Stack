import SwiftUI

/// A version on this Mac, as the list of a language or a service shows it.
struct InstalledVersion: Identifiable, Hashable {
    /// What removing it or making it global acts on (a version, a PHP series, a Python line…).
    let id: String
    let version: String
    /// Release line, to find its support cycle and a newer build of the same line.
    var line: String
    /// Replaces "<product> <version>" when the version has a name of its own (Xcode's Swift).
    var name: String?
    var detail: String?
    var global = false
    /// Said instead of the detail when the version can't be used as it is.
    var problem: String?
    /// Folder of its binaries, relative to Stack's data folder.
    var folder: String?
    var removable = true
    var canBeGlobal = true
}

/// A version the official catalog offers.
struct CatalogVersion: Identifiable, Hashable {
    /// What installing it asks for (a version, a Python line, a Rust channel…).
    let id: String
    let version: String
    var line: String
    var detail: String?
}

/// A version typed by hand when the catalog is a set of channels (Rust: stable, beta, nightly).
struct CustomVersion {
    let title: String
    let placeholder: String
    let pattern: String
}

/// An action of a version's menu beyond the common ones (PHP: open its php.ini folder).
struct VersionMenuItem: Identifiable {
    let id: String
    let title: String
    let symbol: String
    let action: () -> Void
}

/// What a language or a service has installed and offers, and how to act on it. One per product;
/// `VersionsSection` and `VersionPickerSheet` draw any of them the same way.
struct VersionProvider {
    /// Engine id: php, python, node, jdk, rust, swift, mysql…
    let id: String
    let title: String
    /// Logo of the rows.
    var logo: String
    /// Tool whose support cycles (endoflife.date) apply to its lines; nil when they don't.
    var lifecycle: String?
    var installed: [InstalledVersion]
    /// Newest first.
    var catalog: [CatalogVersion]
    var catalogFailed = false
    /// Why the catalog could not be read (no connection, GitHub's limit…), when it is known.
    var catalogError: String?
    /// Where a version comes from and how it is checked, said before installing it.
    var source: String
    var removeDetail: String?
    var custom: CustomVersion?
    /// A utility the versions need first (rustup, swiftly): its row stands in for the list.
    var requirement: String?
    let load: @MainActor (_ refresh: Bool) async -> Void
    /// The install, followed step by step by the picker and stoppable (`InstallMonitor`): the
    /// engine's log, the product for `installSteps`, and the stoppable call itself.
    let install: FollowedInstall
    var remove: (@MainActor (InstalledVersion) async -> Void)?
    var setGlobal: (@MainActor (InstalledVersion) async -> Void)?
    var menu: (InstalledVersion) -> [VersionMenuItem] = { _ in [] }

    func title(of item: InstalledVersion) -> String { item.name ?? "\(title) \(item.version)" }
    /// A newer build of the same line than the installed one, if the catalog has it.
    func update(for item: InstalledVersion) -> CatalogVersion? {
        catalog.first { $0.line == item.line && Self.newer($0.version, than: item.version) }
    }
    static func newer(_ version: String, than other: String) -> Bool {
        version.compare(other, options: .numeric) == .orderedDescending && version.first?.isNumber == true
    }
    func installed(_ entry: CatalogVersion) -> Bool { installed.contains { $0.version == entry.version } }
}

/// The versions of a language or a service, as a section of a grouped form: one row per installed
/// version (global marked, update and the rest in its menu) and «Instalar versión…», which opens
/// the official catalog. Nothing is downloaded until the user picks a version and confirms.
struct VersionsSection: View {
    @Bindable var store: StackStore
    let provider: VersionProvider
    /// Identifier prefix: language.<name> or service.<category>.<engine>.
    let scope: String
    var footer: String?
    @State private var picking = false
    /// The version the picker opens on: an update of an installed line, or its own suggestion.
    @State private var preset: CatalogVersion.ID?
    @State private var removing: InstalledVersion?

    var body: some View {
        Section {
            if let requirement = provider.requirement {
                ToolRow(store: store, tool: requirement, padded: false)
            } else if provider.installed.isEmpty, store.pageFailures[.runtimes] == nil {
                ContentUnavailableView {
                    Label(String(format: L("runtimes.noneTitle"), provider.title), systemImage: Symbols.versions)
                } description: {
                    Text(L("runtimes.noneDetail"))
                } actions: {
                    installButton.buttonStyle(.borderedProminent)
                }
            } else {
                ForEach(provider.installed) { item in
                    InstalledVersionRow(store: store, provider: provider, item: item, scope: scope,
                                        update: provider.update(for: item), remove: { removing = item },
                                        install: { preset = $0.id; picking = true })
                }
                HStack {
                    Spacer()
                    installButton
                }
            }
        } header: {
            Text(L("versions.title"))
        } footer: {
            if let footer { Text(footer).font(.uiCaption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading) }
        }
        .task(id: provider.id) {
            if let lifecycle = provider.lifecycle { await store.loadLifecycle(lifecycle) }
            if provider.catalog.isEmpty && provider.requirement == nil { await provider.load(false) }
            #if DEBUG
            if QAHooks.versionPicker == provider.id { picking = true }
            #endif
        }
        .sheet(isPresented: $picking) { VersionPickerSheet(store: store, provider: provider, scope: scope, preset: preset).themedSheet() }
        .confirmationDialog(removing.map { String(format: L("runtimes.confirmRemove"), provider.title(of: $0)) } ?? "",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), presenting: removing) { item in
            Button(L("common.remove"), role: .destructive) { Task { await provider.remove?(item) } }
                .accessibilityIdentifier("\(scope).version.confirmRemove")
            Button(L("common.cancel"), role: .cancel) {}
        } message: { _ in
            if let detail = provider.removeDetail { Text(detail) }
        }
    }

    private var installButton: some View {
        Button { preset = nil; picking = true } label: { Label(L("runtimes.installVersion"), systemImage: Symbols.install) }
            .disabled(store.busy != nil)
            .accessibilityIdentifier("\(scope).versions.install")
    }
}

extension VersionsSection {
    /// A service's versions where a page still lists them by tool (the web server's Caddy).
    init(store: StackStore, info: DownloadInfo) {
        self.init(store: store, provider: .tool(store, info.id), scope: "service.web.\(info.id)")
    }
}

/// One installed version: logo, name, global mark and support cycle; update and menu at the end.
private struct InstalledVersionRow: View {
    @Bindable var store: StackStore
    let provider: VersionProvider
    let item: InstalledVersion
    let scope: String
    let update: CatalogVersion?
    let remove: () -> Void
    /// Opens the picker on `update`, where it is installed step by step.
    let install: (CatalogVersion) -> Void
    var cycle: Cycle? { provider.lifecycle.flatMap { store.cycle($0, for: item.line) } }
    var busy: Bool { store.busy != nil }

    var body: some View {
        LogoRow {
            HStack(spacing: 8) {
                if let update {
                    Button { install(update) } label: {
                        Label(String(format: L("versions.update"), update.version), systemImage: Symbols.update)
                    }
                    .controlSize(.small).disabled(busy)
                    .accessibilityIdentifier("\(scope).version.\(item.id).update")
                }
                menu
            }
        } label: {
            HStack(spacing: 10) {
                TechLogo(tech: .of(provider.logo), size: 26)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(provider.title(of: item)).monospacedDigit().lineLimit(1)
                        if item.global { Chip(text: L("runtimes.global"), symbol: Symbols.global, tint: Brand.accent).fixedSize() }
                    }
                    // The support cycle under the name: a chip that wrapped beside it would break the row.
                    HStack(spacing: 6) {
                        if let cycle { Chip(cycle: cycle).fixedSize() }
                        if let problem = item.problem {
                            Label(problem, systemImage: Symbols.warning).font(.uiCaption).foregroundStyle(Brand.warning)
                        } else if let detail = item.detail {
                            Text(detail).font(.uiCaption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
        }
        .accessibilityIdentifier("\(scope).version.\(item.id)")
        // The same actions as the row's «⋯» menu, with the update first when there is one.
        .contextMenu {
            if let update {
                Button { install(update) } label: { Label(String(format: L("versions.update"), update.version), systemImage: Symbols.update) }
                    .disabled(busy)
                    .accessibilityIdentifier("\(scope).version.\(item.id).update.context")
                Divider()
            }
            menuItems
        }
    }

    private var menu: some View {
        Menu { menuItems } label: {
            Label(L("runtimes.actions"), systemImage: Symbols.more).labelStyle(.iconOnly)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help(L("runtimes.actions"))
        .accessibilityIdentifier("\(scope).version.\(item.id).menu")
    }

    @ViewBuilder private var menuItems: some View {
            if let setGlobal = provider.setGlobal, item.canBeGlobal {
                Button { Task { await setGlobal(item) } } label: { Label(L("runtimes.useGlobal"), systemImage: Symbols.global) }
                    .disabled(item.global || busy)
            }
            if let folder = item.folder {
                Button { Folder.open(folder) } label: { Label(L("runtimes.openBinary"), systemImage: Symbols.folder) }
            }
            ForEach(provider.menu(item)) { extra in
                Button(action: extra.action) { Label(extra.title, systemImage: extra.symbol) }
            }
            if provider.remove != nil && item.removable {
                Divider()
                Button(role: .destructive, action: remove) { Label(L("runtimes.removeVersion"), systemImage: Symbols.delete) }
                    .disabled(busy)
            }
    }
}

/// The official catalog of a product, to pick one version and install it: the newest of each line
/// in view (every build one click away), what is installed marked, where it comes from said above
/// the button, and the progress until it is installed and verified.
/// See `VersionProvider.install`.
struct FollowedInstall {
    let log: String
    let tool: String
    let run: @MainActor (CatalogVersion) async throws -> Void
}

struct VersionPickerSheet: View {
    @Bindable var store: StackStore
    let provider: VersionProvider
    let scope: String
    var preset: CatalogVersion.ID?
    @State private var monitor: InstallMonitor?
    @State private var installing: String = ""
    @State private var selection: CatalogVersion.ID?
    @State private var showAll = false
    @State private var custom = ""

    /// Newest build of each line, unless every build is asked for.
    var visible: [CatalogVersion] {
        guard !showAll else { return provider.catalog }
        var seen = Set<String>()
        return provider.catalog.filter { seen.insert($0.line).inserted }
    }
    var customVersion: CatalogVersion? {
        let text = custom.trimmingCharacters(in: .whitespaces)
        guard let format = provider.custom, !text.isEmpty, text.range(of: format.pattern, options: .regularExpression) != nil else { return nil }
        return CatalogVersion(id: text, version: text, line: text)
    }
    var chosen: CatalogVersion? { customVersion ?? provider.catalog.first { $0.id == selection } }

    var body: some View {
        SheetFrame(title: String(format: L("runtimes.installTitle"), provider.title), symbol: Symbols.versions,
                   note: monitor == nil ? provider.source : nil, width: TextScale.points(500), height: TextScale.points(460),
                   actionTitle: monitor?.finished == true ? L("progress.close")
                       : chosen.map { String(format: L("runtimes.installNamed"), provider.title, $0.version) } ?? L("common.install"),
                   actionSymbol: monitor?.finished == true ? nil : Symbols.install,
                   actionID: monitor?.finished == true ? "\(scope).picker.close" : "\(scope).picker.install",
                   canAct: monitor?.finished == true
                       || (monitor == nil && chosen.map { !provider.installed($0) } == true && store.busy == nil),
                   cancelID: monitor?.finished == true ? nil : "\(scope).picker.cancel",
                   action: {
                       if monitor?.finished == true { return true }
                       guard let chosen else { return false }
                       let followed = provider.install
                       let monitor = InstallMonitor(log: followed.log, tool: followed.tool)
                       installing = "\(provider.title) \(chosen.version)"
                       self.monitor = monitor
                       monitor.start(store) { try await followed.run(chosen) }
                       return false
                   }) {
            if let monitor {
                InstallProgressView(monitor: monitor, name: installing, scope: "\(scope).picker.progress")
            } else {
                choice
            }
        } status: {
            if monitor == nil { footer }
        }
        .following(monitor)
        .task {
            if let lifecycle = provider.lifecycle { await store.loadLifecycle(lifecycle) }
            if provider.catalog.isEmpty { await provider.load(false) }
            if selection == nil { selection = preset ?? suggested?.id }
            #if DEBUG
            if let phase = QAHooks.installPhase {
                let followed = provider.install
                let monitor = InstallMonitor(log: followed.log, tool: followed.tool)
                installing = "\(provider.title) \(suggested?.version ?? "")"
                self.monitor = monitor
                QAHooks.show(phase, on: monitor)
            }
            #endif
        }
        .onChange(of: provider.catalog) { if selection == nil { selection = suggested?.id } }
    }

    @ViewBuilder private var choice: some View {
        catalog
        if let format = provider.custom {
            LabeledContent(format.title) {
                TextField(format.title, text: $custom, prompt: Text(verbatim: format.placeholder))
                    .labelsHidden().textFieldStyle(.roundedBorder).frame(maxWidth: 140)
                    .accessibilityIdentifier("\(scope).picker.custom")
            }
        }
    }

    @ViewBuilder private var footer: some View {
        if let busy = store.busy, !provider.catalog.isEmpty {
            Text(busy).font(.uiCaption).foregroundStyle(.secondary).lineLimit(1)
        } else {
            Button { Task { await provider.load(true) } } label: { Label(L("runtimes.reloadCatalog"), systemImage: Symbols.reload) }
                .disabled(store.busy != nil)
                .accessibilityIdentifier("\(scope).picker.reload")
        }
    }

    /// The newest supported line that is not installed: LTS first, like the catalogs recommend.
    var suggested: CatalogVersion? {
        let free = visible.filter { !provider.installed($0) }
        return free.first { cycle($0)?.status == .lts } ?? free.first { cycle($0)?.status != .ended }
    }
    func cycle(_ entry: CatalogVersion) -> Cycle? { provider.lifecycle.flatMap { store.cycle($0, for: entry.line) } }

    @ViewBuilder private var catalog: some View {
        if provider.catalogFailed && provider.catalog.isEmpty {
            ContentUnavailableView {
                Label(L("runtimes.catalogFailed"), systemImage: Symbols.warning)
            } description: {
                Text(provider.catalogError ?? L("runtimes.catalogFailedDetail"))
            } actions: {
                Button { Task { await provider.load(true) } } label: { Label(L("common.retry"), systemImage: Symbols.reload) }
                    .buttonStyle(.bordered).accessibilityIdentifier("versions.catalog.retry")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if provider.catalog.isEmpty {
            ContentUnavailableView {
                Label(L("busy.catalog"), systemImage: Symbols.versions)
            } description: {
                ProgressView().controlSize(.small)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(selection: $selection) {
                ForEach(visible) { entry in
                    let installed = provider.installed(entry)
                    HStack(spacing: 10) {
                        Text("\(provider.title) \(entry.version)").font(.uiBody).monospacedDigit().lineLimit(1)
                        if let cycle = cycle(entry) { Chip(cycle: cycle).fixedSize() }
                        Spacer(minLength: 8)
                        if installed {
                            Label(L("runtimes.installedShort"), systemImage: Symbols.success).font(.uiCaption).foregroundStyle(Brand.success)
                        } else if let detail = entry.detail {
                            Text(detail).font(.uiCaption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                    .tag(entry.id)
                    .selectionDisabled(installed)
                    .accessibilityIdentifier("\(scope).picker.version.\(entry.id)")
                }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            .frame(minHeight: 220)
            if provider.catalog.count > visible.count || showAll {
                Toggle(L("runtimes.showAllVersions"), isOn: $showAll)
                    .toggleStyle(.checkbox)
                    .accessibilityIdentifier("\(scope).picker.showAll")
            }
        }
    }
}
