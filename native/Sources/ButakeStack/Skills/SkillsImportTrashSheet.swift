import SwiftUI

/// «Papelera de importación…»: the real folders an import replaced with links. They stay until the
/// user empties it. Each entry can be undone, and everything can be emptied, both only after a
/// confirmation that lists the exact paths.
struct ImportTrashSheet: View {
    let tool: SkillsTool
    @State private var entries: [ImportTrashEntry]?
    @State private var confirmation: ImportConfirmation?

    var body: some View {
        SheetFrame(title: L("skills.sheet.import.trash.title"), symbol: Symbols.delete, detail: L("skills.sheet.import.trash.detail"),
                   width: 600, height: 480, actionTitle: L("skills.sheet.import.trash.empty"),
                   actionID: "skills.sheet.import.trash.empty", canAct: !(entries ?? []).isEmpty, cancelID: "skills.sheet.import.trash.close",
                   action: {
                       confirmation = .empty(entries ?? [])
                       return false
                   }, content: { content })
            .task { await reload() }
            .sheet(item: $confirmation) { item in
                ImportConfirmSheet(tool: tool, confirmation: item) { await reload() }
            }
    }

    private func reload() async { entries = await tool.importTrash() }

    @ViewBuilder private var content: some View {
        if let entries {
            if entries.isEmpty {
                ContentUnavailableView(L("skills.sheet.import.trash.none"), systemImage: Symbols.delete,
                                       description: Text(L("skills.sheet.import.trash.noneDetail")))
                    .accessibilityIdentifier("skills.sheet.import.trash.none")
            } else {
                Form {
                    ForEach(entries) { entry in
                        Section {
                            ForEach(entry.sources, id: \.path) { source in
                                LabeledContent {
                                    Text(source.isLink ? L("skills.sheet.import.kind.link") : L("skills.sheet.import.kind.folder"))
                                        .font(.uiCaption).foregroundStyle(.secondary)
                                } label: {
                                    Text(SkillLinkSheet.shown(source.path)).lineLimit(1).truncationMode(.middle).help(source.path)
                                }
                            }
                            Button(L("skills.sheet.import.trash.undo")) { confirmation = .undo(entry) }
                                .accessibilityIdentifier("skills.sheet.import.trash.undo.\(entry.id)")
                        } header: {
                            Text("\(entry.id) · \(entry.createdDate.formatted(date: .abbreviated, time: .shortened))")
                        }
                    }
                }
                .formStyle(.grouped)
                .accessibilityIdentifier("skills.sheet.import.trash.list")
            }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// The confirmation of an undo or of emptying the import trash: what it does, path by path.
struct ImportConfirmSheet: View {
    let tool: SkillsTool
    let confirmation: ImportConfirmation
    let done: () async -> Void
    @State private var undoPlan: ImportUndoPlan?
    @State private var emptyPlan: ImportEmptyPlan?
    @State private var failed = false

    private var isUndo: Bool {
        if case .undo = confirmation { true } else { false }
    }

    private var canAct: Bool {
        if let undoPlan { return undoPlan.conflicts.isEmpty }
        return emptyPlan != nil
    }

    var body: some View {
        SheetFrame(title: isUndo ? L("skills.sheet.import.undo.title") : L("skills.sheet.import.empty.title"), symbol: Symbols.delete,
                   note: isUndo ? L("skills.sheet.import.undo.note") : L("skills.sheet.import.empty.note"), width: 560,
                   actionTitle: isUndo ? L("skills.sheet.import.undo.apply") : L("skills.sheet.import.empty.apply"),
                   actionID: "skills.sheet.import.confirm.apply", canAct: canAct, cancelID: "skills.sheet.import.confirm.cancel",
                   action: { await run() }, content: { content })
            .task { await plan() }
    }

    private func plan() async {
        switch confirmation {
        case .undo(let entry): undoPlan = await tool.planUndo(entry)
        case .empty(let entries): emptyPlan = await tool.planEmpty(entries)
        }
        failed = undoPlan == nil && emptyPlan == nil
    }

    private func run() async -> Bool {
        let ok: Bool
        switch confirmation {
        case .undo(let entry): ok = await tool.applyUndo(entry)
        case .empty(let entries): ok = await tool.applyEmpty(entries)
        }
        if ok { await done() }
        return ok
    }

    @ViewBuilder private var content: some View {
        if let undoPlan {
            Form {
                paths(L("skills.sheet.import.undo.restore"), undoPlan.restore.map { "\($0.from) → \($0.to)" })
                paths(L("skills.sheet.import.undo.relink"), undoPlan.relink.map { "\($0.path) → \($0.target)" })
                paths(L("skills.sheet.import.undo.remove"), undoPlan.remove)
                paths(L("skills.sheet.import.undo.trash"), undoPlan.trash)
                if !undoPlan.conflicts.isEmpty {
                    Section {
                        ForEach(undoPlan.conflicts, id: \.self) { conflict in
                            LabeledContent {
                                Text(localized("skills.sheet.import.reason.\(conflict.reason)") ?? conflict.reason)
                                    .font(.uiCaption).foregroundStyle(.secondary)
                            } label: {
                                Text(SkillLinkSheet.shown(conflict.path)).lineLimit(1).truncationMode(.middle).help(conflict.path)
                            }
                        }
                    } header: {
                        Text(L("skills.sheet.import.undo.conflicts"))
                    } footer: {
                        SettingsFooter(L("skills.sheet.import.undo.conflictsDetail"))
                    }
                    .accessibilityIdentifier("skills.sheet.import.undo.conflicts")
                }
            }
            .formStyle(.grouped)
        } else if let emptyPlan {
            Form { paths(L("skills.sheet.import.empty.delete"), emptyPlan.delete) }.formStyle(.grouped)
        } else if failed {
            ContentUnavailableView(L("skills.links.failed"), systemImage: Symbols.error)
        } else {
            ProgressView().frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder private func paths(_ title: String, _ list: [String]) -> some View {
        if !list.isEmpty {
            Section(title) {
                ForEach(list, id: \.self) { path in
                    Text(SkillLinkSheet.shown(path)).font(.uiCallout).lineLimit(1).truncationMode(.middle).help(path)
                }
            }
        }
    }
}
