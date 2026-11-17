import SwiftUI

/// «Skills eliminadas…»: the skills deleted in the last 30 days, each with «Restaurar», which opens
/// the same confirmation as «Deshacer» (the links it recreates). Nothing is deleted from here: what
/// lasts more than 30 days goes away by itself.
struct DeletedTrashSheet: View {
    let tool: SkillsTool
    @State private var entries: [DeletedTrashEntry]?
    @State private var request: SkillLinkRequest?

    var body: some View {
        SheetFrame(title: L("skills.sheet.deletedTrash.title"), symbol: Symbols.delete, detail: L("skills.sheet.deletedTrash.detail"),
                   width: 600, height: 480, actionTitle: L("common.close"),
                   actionID: "skills.sheet.deletedTrash.close", canAct: true, cancelID: nil,
                   action: { true }, content: { content })
            .task { await reload() }
            .sheet(item: $request, onDismiss: { Task { await reload() } }) { request in
                SkillLinkSheet(tool: tool, request: request)
            }
    }

    private func reload() async { entries = await tool.deletedTrash() ?? entries ?? [] }

    @ViewBuilder private var content: some View {
        if let entries {
            if entries.isEmpty {
                ContentUnavailableView(L("skills.sheet.deletedTrash.none"), systemImage: Symbols.delete,
                                       description: Text(L("skills.sheet.deletedTrash.noneDetail")))
                    .accessibilityIdentifier("skills.sheet.deletedTrash.none")
            } else {
                Form {
                    ForEach(entries) { entry in
                        Section {
                            LabeledContent(L("skills.sheet.deletedTrash.deleted"), value: entry.deletedDate.formatted(date: .abbreviated, time: .shortened))
                            LabeledContent(L("skills.sheet.deletedTrash.expires"), value: entry.expiresDate.formatted(date: .abbreviated, time: .omitted))
                            Button(L("skills.sheet.deletedTrash.restore")) { request = entry.restoreRequest }
                                .accessibilityIdentifier("skills.sheet.deletedTrash.restore.\(entry.trashId)")
                        } header: {
                            Text("\(entry.name) · \(entry.id)")
                        }
                    }
                }
                .formStyle(.grouped)
                .accessibilityIdentifier("skills.sheet.deletedTrash.list")
            }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
