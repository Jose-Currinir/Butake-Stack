import SwiftUI

/// «Importar skills existentes…»: the skills already in the folders of the assistants. First what was
/// found (checkboxes, a source picker when copies differ, the group), then the plan with every path
/// that changes, and only then the import. Real folders go to the import trash, never deleted.
struct ImportSkillsSheet: View {
    let tool: SkillsTool
    @State private var candidates: [ImportCandidate]?
    @State private var selected: Set<String> = []
    @State private var choices: [String: String] = [:]
    @State private var group = ""
    @State private var plan: ImportPlan?
    @State private var failed = false

    private var visibleCandidates: [ImportCandidate] { (candidates ?? []).filter { !$0.hidden } }
    private var hiddenCandidates: [ImportCandidate] { (candidates ?? []).filter(\.hidden) }
    private var chosenIds: [String] { (candidates ?? []).filter { selected.contains($0.id) }.map(\.id) }

    private var canAct: Bool {
        if let plan { return !plan.copy.isEmpty }
        return !chosenIds.isEmpty && !group.isEmpty
    }

    var body: some View {
        SheetFrame(title: plan == nil ? L("skills.sheet.import.title") : L("skills.sheet.import.planTitle"), symbol: Symbols.importing,
                   detail: plan == nil ? L("skills.sheet.import.detail") : nil, width: 620, height: 560,
                   actionTitle: plan == nil ? L("skills.sheet.import.review") : L("skills.sheet.import.apply"),
                   actionID: "skills.sheet.import.confirm", canAct: canAct, cancelID: "skills.sheet.import.cancel",
                   action: { await act() }, content: { content }, status: {
                       if plan != nil {
                           Button(L("skills.sheet.import.back")) { plan = nil }
                               .buttonStyle(.borderless).accessibilityIdentifier("skills.sheet.import.back")
                       }
                   })
            .task { await load() }
    }

    private func load() async {
        group = tool.groups.first?.id ?? ""
        guard let found = await tool.scanImport() else {
            failed = true
            return
        }
        candidates = found
        selected = Set(found.filter(\.preselected).map(\.id))
        for item in found where !item.identical { choices[item.id] = item.sources.first?.path }
        #if DEBUG
        if QAHooks.skillsImportPlan, canAct { _ = await act() }
        #endif
    }

    private func act() async -> Bool {
        if plan == nil {
            plan = await tool.planImport(ids: chosenIds, group: group, choices: choices)
            return false
        }
        return await tool.applyImport(ids: chosenIds, group: group, choices: choices)
    }

    @ViewBuilder private var content: some View {
        if let plan {
            ImportPlanView(tool: tool, plan: plan)
        } else if failed {
            ContentUnavailableView(L("skills.sheet.import.failed"), systemImage: Symbols.error)
        } else if let candidates {
            if candidates.isEmpty {
                ContentUnavailableView(L("skills.sheet.import.none"), systemImage: Symbols.skill,
                                       description: Text(L("skills.sheet.import.noneDetail")))
                    .accessibilityIdentifier("skills.sheet.import.none")
            } else {
                list
            }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var list: some View {
        Form {
            Picker(L("skills.group"), selection: $group) {
                ForEach(tool.groups) { Text($0.name).tag($0.id) }
            }
            .accessibilityIdentifier("skills.sheet.import.group")
            Section(L("skills.sheet.import.found")) {
                ForEach(visibleCandidates) { row($0) }
            }
            if !hiddenCandidates.isEmpty {
                Section {
                    ForEach(hiddenCandidates) { row($0) }
                } header: {
                    Text(L("skills.sheet.import.hidden"))
                } footer: {
                    SettingsFooter(L("skills.sheet.import.hiddenDetail"))
                }
            }
        }
        .formStyle(.grouped)
        .accessibilityIdentifier("skills.sheet.import.list")
    }

    private func row(_ item: ImportCandidate) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: Binding(get: { selected.contains(item.id) },
                                 set: { if $0 { selected.insert(item.id) } else { selected.remove(item.id) } })) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.name).lineLimit(1).truncationMode(.tail)
                    Text(subtitle(item)).font(.uiCaption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                }
            }
            .disabled(!item.valid)
            .accessibilityIdentifier("skills.sheet.import.row.\(item.id)")
            if let reason = item.reason {
                Text(reasonText(reason)).font(.uiCaption).foregroundStyle(Brand.danger)
                    .accessibilityIdentifier("skills.sheet.import.reason.\(item.id)")
            }
            if !item.identical && item.valid {
                Picker(L("skills.sheet.import.copyFrom"), selection: Binding(get: { choices[item.id] ?? "" }, set: { choices[item.id] = $0 })) {
                    // The AI's name is enough to choose (each has one folder); the path is in the plan and the help.
                    ForEach(item.sources, id: \.path) { source in
                        Text(tool.agent(source.agent)?.name ?? source.agent).tag(source.path)
                    }
                }
                .help(choices[item.id].map(SkillLinkSheet.shown) ?? "")
                .accessibilityIdentifier("skills.sheet.import.source.\(item.id)")
                Text(L("skills.sheet.import.differentDetail")).font(.uiCaption).foregroundStyle(.secondary)
            }
        }
    }

    /// Where it was found: the assistants' names.
    private func subtitle(_ item: ImportCandidate) -> String {
        let names = item.sources.map { tool.agent($0.agent)?.name ?? $0.agent }
        return Array(NSOrderedSet(array: names)).compactMap { $0 as? String }.joined(separator: ", ")
    }

    private func reasonText(_ reason: String) -> String {
        localized("skills.sheet.import.reason.\(reason)") ?? reason
    }
}

/// The plan of the import: per skill where it is copied from and to, each path that changes, what is
/// left as it is, and the one general warning.
struct ImportPlanView: View {
    let tool: SkillsTool
    let plan: ImportPlan

    var body: some View {
        Form {
            Section(L("skills.sheet.import.plan.copy")) {
                ForEach(plan.copy, id: \.self) { copy in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(copy.id).font(.uiCallout)
                        Text(String(format: L("skills.sheet.import.plan.copyLine"), SkillLinkSheet.shown(copy.from)))
                            .font(.uiCaption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(copy.from)
                    }
                }
            }
            .accessibilityIdentifier("skills.sheet.import.plan.copy")
            paths(L("skills.sheet.import.plan.trash"), plan.trash, id: "trash")
            paths(L("skills.sheet.import.plan.unlink"), plan.unlink, id: "unlink")
            if !plan.warnings.isEmpty {
                Section {
                    ForEach(plan.warnings, id: \.self) { warning in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(warning.id).font(.uiCallout)
                            Text(Self.omitted(warning.skipped)).font(.uiCaption).foregroundStyle(.secondary)
                                .lineLimit(3).truncationMode(.tail).help(warning.skipped.joined(separator: "\n"))
                        }
                        .accessibilityIdentifier("skills.sheet.import.plan.skipped.\(warning.id)")
                    }
                } header: {
                    Text(L("skills.sheet.import.plan.skipped"))
                } footer: {
                    SettingsFooter(L("skills.sheet.import.plan.skippedDetail"))
                }
                .accessibilityIdentifier("skills.sheet.import.plan.skipped")
            }
            if !plan.conflicts.isEmpty {
                Section {
                    ForEach(plan.conflicts, id: \.self) { conflict in
                        LabeledContent {
                            Text(localized("skills.sheet.import.reason.\(conflict.reason)") ?? conflict.reason)
                                .font(.uiCaption).foregroundStyle(.secondary)
                        } label: {
                            Text(SkillLinkSheet.shown(conflict.path)).lineLimit(1).truncationMode(.middle).help(conflict.path)
                        }
                    }
                } header: {
                    Text(L("skills.sheet.import.plan.conflicts"))
                } footer: {
                    SettingsFooter(L("skills.sheet.import.plan.conflictsDetail"))
                }
                .accessibilityIdentifier("skills.sheet.import.plan.conflicts")
            }
            if !plan.replace.isEmpty {
                Section {
                    Label(L("skills.sheet.import.plan.warning"), systemImage: Symbols.warning)
                        .font(.uiCaption).foregroundStyle(Brand.warning)
                        .accessibilityIdentifier("skills.sheet.import.plan.warning")
                } footer: {
                    SettingsFooter(L("skills.sheet.import.plan.trashDetail"))
                }
            }
        }
        .formStyle(.grouped)
    }

    /// The omitted paths, the first few by name.
    static func omitted(_ paths: [String]) -> String {
        let shown = paths.prefix(5).joined(separator: ", ")
        return paths.count > 5 ? String(format: L("skills.sheet.import.plan.skippedMore"), shown, paths.count - 5) : shown
    }

    @ViewBuilder private func paths(_ title: String, _ list: [String], id: String) -> some View {
        if !list.isEmpty {
            Section(title) {
                ForEach(list, id: \.self) { path in
                    Text(SkillLinkSheet.shown(path)).font(.uiCallout).lineLimit(1).truncationMode(.middle).help(path)
                }
            }
            .accessibilityIdentifier("skills.sheet.import.plan.\(id)")
        }
    }
}
