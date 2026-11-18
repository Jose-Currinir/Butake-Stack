import SwiftUI

/// The confirmation of a change to the assistants' folders: the exact links it makes and removes,
/// and what it leaves alone because something else is already there. Stack only ever removes links
/// that point into its own skills folder.
struct SkillLinkSheet: View {
    let tool: SkillsTool
    let request: SkillLinkRequest
    @State private var plan: SkillLinkPlan?
    @State private var failed = false

    private var title: String {
        switch request.operation {
        case .rename: L("skills.rename.title")
        case .delete: L("skills.links.titleDelete")
        case .restore: L("skills.links.titleRestore")
        case .removeAgent: L("skills.links.titleRemoveAgent")
        case .links:
            switch request.enabled {
            case true?: L("skills.links.titleActivate")
            case false?: L("skills.links.titleDeactivate")
            case nil: L("skills.links.title")
            }
        }
    }

    private var actionTitle: String {
        switch request.operation {
        case .rename: L("skills.links.renameApply")
        case .delete: L("skills.links.deleteApply")
        case .restore: L("skills.links.restoreApply")
        case .removeAgent: L("skills.links.removeAgentApply")
        case .links: L("skills.links.apply")
        }
    }

    /// What the change does besides the links.
    private var note: String? {
        switch request.operation {
        case .rename: nil
        case .delete: L("skills.deleteDetail")
        case .restore: L("skills.links.restoreNote")
        case .removeAgent: L("skills.agent.removeDetail")
        case .links: nil
        }
    }

    /// Something to do: a link to make or remove, the whole skill switched on or off, or a change
    /// that always does something (rename, delete, restore, remove an assistant) once the plan is
    /// in. A plan of only conflicts changes nothing.
    private var canApply: Bool {
        guard let plan else { return false }
        return request.alwaysActs || request.enabled != nil || !plan.create.isEmpty || !plan.remove.isEmpty
    }

    var body: some View {
        SheetFrame(title: title, symbol: Symbols.link, detail: request.subject ?? tool.skill(request.skill)?.name, note: note, width: 560,
                   actionTitle: actionTitle, actionID: "skills.sheet.links.confirm", canAct: canApply,
                   cancelID: "skills.sheet.links.cancel",
                   action: { await tool.apply(request) }) {
            content.frame(minHeight: 120)
        }
        .task {
            plan = await tool.plan(request)
            failed = plan == nil
        }
    }

    @ViewBuilder private var content: some View {
        if let plan {
            Form {
                if plan.isEmpty && !request.alwaysActs {
                    Text(L("skills.links.nothing")).foregroundStyle(.secondary).accessibilityIdentifier("skills.sheet.links.nothing")
                }
                paths(L("skills.links.create"), plan.create, id: "create")
                paths(L("skills.links.remove"), plan.remove, id: "remove")
                if !plan.conflicts.isEmpty {
                    Section {
                        ForEach(plan.conflicts, id: \.self) { conflict in
                            LabeledContent {
                                Text(localized("skills.links.reason.\(conflict.reason)") ?? L("skills.links.reason.exists")).font(.uiCaption).foregroundStyle(.secondary)
                            } label: {
                                Text(Self.shown(conflict.path)).lineLimit(1).truncationMode(.middle).help(conflict.path)
                            }
                        }
                    } header: {
                        Text(L("skills.links.conflicts"))
                    } footer: {
                        SettingsFooter(L("skills.links.conflictsDetail"))
                    }
                    .accessibilityIdentifier("skills.sheet.links.conflicts")
                }
            }
            .formStyle(.grouped)
        } else if failed {
            ContentUnavailableView(L("skills.links.failed"), systemImage: Symbols.error)
        } else {
            ProgressView().frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder private func paths(_ title: String, _ list: [String], id: String) -> some View {
        if !list.isEmpty {
            Section(title) {
                ForEach(list, id: \.self) { path in
                    Text(Self.shown(path)).font(.uiCallout).lineLimit(1).truncationMode(.middle).help(path)
                }
            }
            .accessibilityIdentifier("skills.sheet.links.\(id)")
        }
    }

    static func shown(_ path: String) -> String { path.replacingOccurrences(of: NSHomeDirectory(), with: "~") }
}
