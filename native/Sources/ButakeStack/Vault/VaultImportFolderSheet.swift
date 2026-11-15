import SwiftUI

/// The preview of a folder import: first the summary of what comes in and what stays out, by category
/// (`VaultImportSummaryPanel`), then by app and service each file that is imported when ticked, with its
/// kind, part and stage, and what travels with it (a password, a value, its fields) said without its
/// value. A service is one block whatever its accounts (its subfolders), each under its name. Folders a
/// link proposed (`linked`) are said first, so a link is never taken for the user's own choice.
struct VaultImportFolderSheet: View {
    @Bindable var vault: VaultSession
    @State var groups: [VaultFolder.Group]
    var linked: [String] = []
    @State private var working = false
    var selectedCount: Int { groups.flatMap(\.files).filter { $0.selected && !$0.kind.isRetired }.count }
    /// Nothing ticked can still gather the accounts an earlier import kept apart, or fill an existing
    /// app's notes.
    private var canImport: Bool {
        selectedCount > 0 || groups.contains { !$0.legacy.isEmpty || ($0.existing != nil && !$0.readmes.isEmpty) }
    }
    var body: some View {
        SheetFrame(title: L("vault.importFolder"),
                   symbol: Symbols.newFolder,
                   detail: L("vault.importFolderDetail"),
                   width: 860,
                   height: 640,
                   actionTitle: String(format: L("vault.importCount"), selectedCount),
                   actionID: "vault.sheet.importFolder.confirm",
                   canAct: !working && canImport,
                   cancelID: "vault.sheet.importFolder.cancel",
                   action: { await run(); return false }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !linked.isEmpty {
                        Notice(.warning, L("vault.link.proposed"), detail: linked.joined(separator: "\n"), symbol: Symbols.link)
                            .accessibilityIdentifier("vault.sheet.importFolder.linked")
                    }
                    VaultImportSummaryPanel(groups: $groups)
                    ForEach($groups) { $group in
                        let kept = group.files.indices.filter { VaultImportSummary.leftCategory(group.files[$0]) == nil }
                        if !kept.isEmpty || !group.legacy.isEmpty { block($group, kept) }
                    }
                }
            }
            .themedScroll()
        } status: {
            Label(L("vault.importFolderSafe"), systemImage: Symbols.vault).font(.uiCaption).foregroundStyle(.secondary)
        }
    }

    private func block(_ group: Binding<VaultFolder.Group>, _ kept: [Int]) -> some View {
        let value = group.wrappedValue
        let isApp = value.kind == .app
        // A service's own files first, then each account under its name.
        let ordered = kept.sorted { (value.files[$0].account ?? "", $0) < (value.files[$1].account ?? "", $1) }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                IconTile(symbol: isApp ? Symbols.app : Symbols.server, size: 22)
                Text(isApp ? value.folderName : value.name).font(.uiHeadline)
                Chip(text: value.existing == nil ? L("vault.import.new") : L("vault.import.merge"), tint: value.existing == nil ? Brand.accent : .secondary)
                if !value.readmes.isEmpty { Chip(text: "README.md", symbol: Symbols.notes) }
                if !value.legacy.isEmpty {
                    Chip(text: String(format: L("vault.import.gathers"), value.legacy.count), symbol: Symbols.user, tint: Brand.info,
                         help: L("vault.import.gathersHelp"))
                }
                Spacer()
            }
            if !ordered.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(ordered, id: \.self) { position in
                        let account = value.files[position].account
                        if !isApp, let account, ordered.first(where: { value.files[$0].account == account }) == position {
                            Label(VaultContainer.accountTitle(account), systemImage: Symbols.user)
                                .font(.uiCaption.weight(.semibold)).foregroundStyle(.secondary)
                                .padding(.horizontal, 10).padding(.top, 6)
                                .accessibilityIdentifier("vault.sheet.importFolder.account.\(account)")
                        }
                        VaultImportFileRow(file: group.files[position], isApp: isApp)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.035)))
            }
        }
        .accessibilityIdentifier("vault.sheet.importFolder.group.\(value.folderName)")
    }

    func run() async {
        working = true
        defer { working = false }
        let result = await vault.importFolder(groups, folders: vault.importFolders)
        vault.notice = String(format: L("vault.importedFolder"), result.added)
        if result.failed > 0 { vault.message = String(format: L("vault.importFailed"), result.failed) }
        if let id = groups.lazy.compactMap({ vault.matchContainer($0) }).first { vault.selection = .container(id) }
        // What came in and what stayed out, kept as «Última importación».
        vault.sheet = .lastImport
    }
}

/// A file to import: its checkbox, kind, name and path; under them what it brings and why it is left
/// out; at the end its kind, part and stage.
private struct VaultImportFileRow: View {
    @Binding var file: VaultFolder.Candidate
    let isApp: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Toggle(file.name, isOn: $file.selected).toggleStyle(.checkbox).labelsHidden()
                .disabled(file.kind.isRetired)
                .accessibilityIdentifier("vault.sheet.importFolder.file.\(file.relative)")
            Image(systemName: file.kind.symbol).foregroundStyle(VaultStyle.tint(file.kind)).frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(file.name).font(.uiCallout).lineLimit(1).truncationMode(.middle).help(file.name)
                Text(file.relative).font(.uiCaption.monospaced()).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle).help(file.relative)
                chips
                ForEach($file.companions, id: \.url) { $companion in
                    if !companion.certain {
                        // Not certain: proposed, and taken only if the user ticks it.
                        Toggle(String(format: L("vault.import.propose"), companion.name, roles(companion)), isOn: $companion.accepted)
                            .toggleStyle(.checkbox).font(.uiCaption)
                            .accessibilityIdentifier("vault.sheet.importFolder.companion.\(file.relative).\(companion.name)")
                    }
                }
            }
            Spacer(minLength: 6)
            if file.kind.isRetired {
                Chip(text: L("vault.import.retired.\(file.kind.rawValue)"), symbol: Symbols.info, tint: .secondary)
                    .help(L("vault.retired.\(file.kind.rawValue)"))
            } else {
                Picker(L("common.type"), selection: $file.kind) {
                    ForEach(VaultItemKind.offered) { Text(L("vault.kind.\($0.rawValue)")).tag($0) }
                }
                .labelsHidden().frame(width: 170).accessibilityIdentifier("vault.sheet.importFolder.kind.\(file.relative)")
                if isApp {
                    Picker(L("vault.section"), selection: $file.section) {
                        Text(L("vault.part.none")).tag(VaultSection?.none)
                        ForEach(VaultSection.allCases) { Text($0.title).tag(VaultSection?.some($0)) }
                    }
                    .labelsHidden().frame(width: 110).accessibilityIdentifier("vault.sheet.importFolder.section.\(file.relative)")
                }
                Picker(L("vault.environment"), selection: $file.environment) {
                    ForEach(VaultEnvironment.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden().frame(width: 130).accessibilityIdentifier("vault.sheet.importFolder.environment.\(file.relative)")
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .opacity(file.selected ? 1 : 0.6)
    }

    @ViewBuilder private var chips: some View {
        let used = file.companions.filter { $0.certain }
        if file.duplicate || file.copyOf != nil || file.exclusion != nil || file.dataFile != nil || !used.isEmpty {
            HStack(spacing: 4) {
                if file.duplicate { Chip(text: L("vault.import.already"), tint: .secondary) }
                if let copy = file.copyOf { Chip(text: L("vault.import.copy"), symbol: Symbols.copy, tint: .secondary, help: String(format: L("vault.import.copyHelp"), copy)) }
                if let exclusion = file.exclusion { Chip(text: L("vault.import.excluded.\(exclusion.rawValue)"), symbol: Symbols.history, tint: .secondary, help: L("vault.import.excludedHelp")) }
                if file.dataFile != nil { Chip(text: L("vault.import.withFields"), symbol: Symbols.withFields, tint: Brand.info) }
                ForEach(used, id: \.url) { companion in
                    // Never the value: only that it travels with the file, and from where.
                    Chip(text: L("vault.import.companion.\(companion.source.rawValue)"), symbol: Symbols.success, tint: Brand.success,
                         help: String(format: L("vault.import.companionHelp"), companion.name))
                }
            }
        }
    }

    private func roles(_ companion: VaultCompanions.Companion) -> String {
        companion.roles.map { L("vault.field.\($0.rawValue)").lowercased() }.joined(separator: ", ")
    }
}
