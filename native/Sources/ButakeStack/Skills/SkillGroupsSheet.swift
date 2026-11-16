import SwiftUI

/// «Grupos…»: create, rename, reorder and delete the groups. Deleting a group that has skills asks
/// where they go. Nothing is saved until «Guardar».
struct SkillGroupsSheet: View {
    let tool: SkillsTool
    @State private var groups: [SkillGroup] = []
    @State private var original: [SkillGroup] = []
    @State private var removed: [SkillGroup] = []
    @State private var newName = ""
    @State private var moveTo = ""

    /// Skills of the groups being deleted, which need somewhere to go.
    private var orphans: Int { removed.reduce(0) { $0 + tool.count(in: $1.id) } }
    private var changed: Bool { groups != original || !removed.isEmpty }
    private var valid: Bool {
        !groups.isEmpty && groups.allSatisfy { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty && $0.name.count <= 60 }
            && (orphans == 0 || groups.contains { $0.id == moveTo })
    }

    var body: some View {
        SheetFrame(title: L("skills.groups.title"), symbol: Symbols.folder, detail: L("skills.groups.detail"), width: 480, height: 420,
                   actionTitle: L("common.save"), actionID: "skills.sheet.groups.confirm", canAct: valid && changed,
                   cancelID: "skills.sheet.groups.cancel",
                   action: {
                       // The order is the one on screen (after dragging), not the one each group came with.
                       let final = groups.enumerated().map { SkillGroup(id: $1.id, name: $1.name.trimmingCharacters(in: .whitespaces), order: $0) }
                       return await tool.saveGroups(final, deleting: removed.map { ($0.id, moveTo) })
                   }) {
            // One grouped form, as the other sheets: the groups (drag to reorder), the new group and,
            // when a deleted group has skills, where they go. No empty gap between them.
            Form {
                Section {
                    ForEach($groups) { $group in
                        HStack {
                            TextField(L("skills.groups.name"), text: $group.name).labelsHidden()
                                .accessibilityIdentifier("skills.sheet.groups.name.\(group.id)")
                            Text(String(format: L("skills.count"), tool.count(in: group.id))).font(.uiCaption).foregroundStyle(.secondary)
                            Button { remove(group) } label: { Label(L("skills.groups.remove"), systemImage: Symbols.remove) }
                                .labelStyle(.iconOnly).buttonStyle(.borderless).disabled(groups.count == 1)
                                .help(L("skills.groups.removeHelp")).accessibilityIdentifier("skills.sheet.groups.remove.\(group.id)")
                        }
                    }
                    .onMove { groups.move(fromOffsets: $0, toOffset: $1) }
                }
                .accessibilityIdentifier("skills.sheet.groups.list")
                Section {
                    LabeledContent(L("skills.groups.new")) {
                        HStack {
                            TextField(L("skills.groups.new"), text: $newName, prompt: Text(L("skills.groups.newPrompt"))).labelsHidden()
                                .onSubmit(add).accessibilityIdentifier("skills.sheet.groups.newName")
                            Button(L("skills.groups.add"), action: add)
                                .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty).accessibilityIdentifier("skills.sheet.groups.add")
                        }
                    }
                }
                if orphans > 0 {
                    Section {
                        Picker(L("skills.groups.moveTo"), selection: $moveTo) {
                            ForEach(groups) { Text($0.name).tag($0.id) }
                        }
                        .accessibilityIdentifier("skills.sheet.groups.moveTo")
                    }
                }
            }
            .formStyle(.grouped)
        }
        .onAppear {
            original = tool.groups.sorted { $0.order < $1.order }.enumerated().map { SkillGroup(id: $1.id, name: $1.name, order: $0) }
            groups = original
            moveTo = groups.first?.id ?? ""
        }
    }

    private func add() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let id = SkillIDs.unique(SkillIDs.slug(name).isEmpty ? "grupo" : SkillIDs.slug(name), taken: Set((groups + removed).map(\.id)))
        groups.append(SkillGroup(id: id, name: name, order: groups.count))
        newName = ""
    }

    private func remove(_ group: SkillGroup) {
        groups.removeAll { $0.id == group.id }
        if tool.group(group.id) != nil { removed.append(group) }
        if !groups.contains(where: { $0.id == moveTo }) { moveTo = groups.first?.id ?? "" }
    }
}
