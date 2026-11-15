import SwiftUI

/// What an import brings and leaves out, by category, each with its count and, unfolded, its paths
/// (names only, never content). In the preview the history and what nobody recognized can be ticked
/// here to include them; dumps and quarantines are only told, with why. Once imported (`stored`), the
/// same summary is read from the vault as «Última importación», with the way to Entornos for the `.env`.
struct VaultImportSummaryPanel: View {
    /// The preview's groups, whose ticks this panel changes; nil for a stored summary.
    var groups: Binding<[VaultFolder.Group]>?
    var stored: VaultImportSummary?
    var openEnvironments: ((String) -> Void)?
    @State private var expanded: Set<String> = Self.initiallyExpanded

    private typealias Category = VaultImportSummary.Category
    private struct Row: Identifiable {
        var id: String { path + (reason ?? "") }
        var path: String
        var reason: String?
        var position: (group: Int, file: Int)?
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Category.allCases) { category in
                let rows = rows(category)
                if category != .unselected || !rows.isEmpty {
                    section(category, rows)
                    if category != Category.allCases.last { Divider().padding(.leading, 38) }
                }
            }
        }
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.035)))
        .accessibilityIdentifier("vault.importSummary")
    }

    private func section(_ category: Category, _ rows: [Row]) -> some View {
        let count = count(category, rows)
        let isExpanded = Binding(get: { expanded.contains(category.rawValue) },
                                 set: { if $0 { expanded.insert(category.rawValue) } else { expanded.remove(category.rawValue) } })
        return DisclosureGroup(isExpanded: isExpanded) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L("vault.importSummary.why.\(category.rawValue)")).font(.uiCaption).foregroundStyle(.secondary)
                if category == .env, stored != nil, openEnvironments != nil, !rows.isEmpty { environmentsButton }
                ForEach(rows) { row in line(category, row) }
            }
            .padding(.leading, 30).padding(.vertical, 4)
        } label: {
            HStack(spacing: 8) {
                IconTile(symbol: symbol(category), color: color(category), size: 20)
                Text(L("vault.importSummary.\(category.rawValue)")).font(.uiBody)
                Spacer(minLength: 6)
                Text("\(count)").font(.uiSubheadline.weight(.medium)).foregroundStyle(count > 0 && category.isLeftOut ? .primary : .secondary).monospacedDigit()
            }
        }
        .disabled(rows.isEmpty)
        .padding(.horizontal, 10).padding(.vertical, 4)
        .accessibilityIdentifier("vault.importSummary.\(category.rawValue)")
    }

    @ViewBuilder private func line(_ category: Category, _ row: Row) -> some View {
        HStack(spacing: 6) {
            if let groups, let position = row.position, category.includable,
               !groups.wrappedValue[position.group].files[position.file].kind.isRetired {
                Toggle(isOn: groups[position.group].files[position.file].selected) { path(row.path) }
                    .toggleStyle(.checkbox)
                    .help(L("vault.importSummary.include"))
                    .accessibilityIdentifier("vault.importSummary.include.\(row.path)")
            } else {
                path(row.path)
            }
            Spacer(minLength: 4)
            if let reason = row.reason { Chip(text: L("vault.summary.reason.\(reason)"), tint: .secondary) }
        }
    }

    private func path(_ text: String) -> some View {
        Text(text).font(.uiCaption.monospaced()).lineLimit(1).truncationMode(.middle).help(text)
    }

    /// «Abrir Entornos»: only goes to a project's Entornos; nothing is imported.
    @ViewBuilder private var environmentsButton: some View {
        let projects = StackStore.shared.projects.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        if projects.isEmpty {
            Button {} label: { Label(L("vault.importSummary.openEnvironments"), systemImage: Symbols.environments) }
                .buttonStyle(.bordered).disabled(true).help(L("vault.importSummary.noProjects"))
                .accessibilityIdentifier("vault.importSummary.openEnvironments")
        } else {
            Menu {
                ForEach(projects) { project in Button(project.title) { openEnvironments?(project.id) } }
            } label: { Label(L("vault.importSummary.openEnvironments"), systemImage: Symbols.environments) }
                .menuStyle(.button).buttonStyle(.bordered).fixedSize()
                .help(L("vault.importSummary.openEnvironmentsHelp"))
                .accessibilityIdentifier("vault.importSummary.openEnvironments")
        }
    }

    private static var initiallyExpanded: Set<String> {
        #if DEBUG
        VaultQA.summaryOpen
        #else
        []
        #endif
    }

    // MARK: Rows

    private func rows(_ category: Category) -> [Row] {
        if let stored { return stored.list(category).map { Row(path: $0.path, reason: $0.reason) } }
        guard let groups = groups?.wrappedValue else { return [] }
        if category == .readme {
            return VaultImportSummary.make(groups, folders: []).list(.readme).map { Row(path: $0.path, reason: $0.reason) }
        }
        var rows: [Row] = []
        for g in groups.indices {
            for f in groups[g].files.indices {
                let file = groups[g].files[f]
                let left = VaultImportSummary.leftCategory(file)
                let matches = switch category {
                case .imported: file.selected && !file.kind.isRetired
                case .unselected: left == nil && !file.selected
                default: left == category
                }
                guard matches else { continue }
                let reason = left.flatMap { VaultImportSummary.reason(file, in: $0) }
                rows.append(Row(path: file.relative, reason: category == .imported ? nil : reason, position: (g, f)))
            }
            if category == .unrecognized {
                rows += groups[g].skipped.map { Row(path: $0.relative, reason: "skip.\($0.reason.rawValue)") }
            }
        }
        return rows
    }

    /// In the preview a ticked history file is counted as imported, not as left out.
    private func count(_ category: Category, _ rows: [Row]) -> Int {
        guard let groups = groups?.wrappedValue, category.includable else { return rows.count }
        return rows.filter { row in row.position.map { !groups[$0.group].files[$0.file].selected } ?? true }.count
    }

    private func symbol(_ category: Category) -> String {
        switch category {
        case .imported: Symbols.success
        case .readme: Symbols.notes
        case .history: Symbols.history
        case .dump: Symbols.database
        case .env: Symbols.environments
        case .quarantine: Symbols.locked
        case .duplicate: Symbols.copy
        case .unrecognized: Symbols.info
        case .unselected: Symbols.remove
        }
    }

    private func color(_ category: Category) -> Color {
        switch category {
        case .imported: Brand.success
        case .quarantine, .dump: TileColor.security
        case .env: TileColor.terminal
        default: TileColor.system
        }
    }
}

/// «Última importación…»: the summary of the last folder import, as it was kept (paths and counts).
struct VaultLastImportSheet: View {
    @Bindable var vault: VaultSession
    var body: some View {
        let summary = vault.index.lastImport
        SheetFrame(title: L("vault.lastImport.title"), symbol: Symbols.review,
                   detail: summary.map { String(format: L("vault.lastImport.detail"), $0.date.formatted(date: .long, time: .shortened),
                                                $0.folders.isEmpty ? "—" : $0.folders.joined(separator: ", ")) },
                   width: 640, height: 560,
                   actionTitle: L("common.done"), actionID: "vault.sheet.lastImport.done",
                   action: { true }) {
            if let summary {
                ScrollView {
                    VaultImportSummaryPanel(stored: summary) { project in
                        vault.sheet = nil
                        VaultProjects.openProject(project, tab: .envs)
                    }
                }
                .themedScroll()
            } else {
                ContentUnavailableView(L("vault.lastImport.none"), systemImage: Symbols.review)
            }
        } status: {
            Label(L("vault.lastImport.safe"), systemImage: Symbols.vault).font(.uiCaption).foregroundStyle(.secondary)
        }
    }
}
