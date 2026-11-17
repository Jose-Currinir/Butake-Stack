import AppKit
import SwiftUI

extension View {
    /// Every sheet and dialog of the Skills tool, presented by the page (the content column only
    /// sets `tool.sheet`).
    func skillsSheets(_ tool: SkillsTool) -> some View {
        modifier(SkillsSheets(tool: tool))
    }
}

private struct SkillsSheets: ViewModifier {
    @Bindable var tool: SkillsTool

    func body(content: Content) -> some View {
        content
            .sheet(item: $tool.sheet) { sheet in
                switch sheet {
                case .newSkill: NewSkillSheet(tool: tool)
                case .groups: SkillGroupsSheet(tool: tool)
                case .move(let id): MoveSkillSheet(tool: tool, skillID: id)
                case .rename(let id): RenameSkillSheet(tool: tool, skillID: id)
                case .agent(let id): CustomAgentSheet(tool: tool, agentID: id)
                case .links(let request): SkillLinkSheet(tool: tool, request: request)
                case .importExisting: ImportSkillsSheet(tool: tool)
                case .importTrash: ImportTrashSheet(tool: tool)
                case .deletedTrash: DeletedTrashSheet(tool: tool)
                }
            }
    }
}

/// «Nueva skill…»: a template, a name, what it is for and its group.
struct NewSkillSheet: View {
    let tool: SkillsTool
    @State private var template = SkillTemplate.blank
    @State private var name = ""
    @State private var id = ""
    @State private var idEdited = false
    @State private var description = ""
    @State private var group = ""

    private var taken: Bool { tool.skill(id) != nil }
    private var valid: Bool { SkillIDs.isValid(id) && !taken && !group.isEmpty && name.count <= 100 && description.count <= 1024 }

    var body: some View {
        SheetFrame(title: L("skills.new.title"), symbol: Symbols.skill, detail: L("skills.new.detail"), width: 520,
                   actionTitle: L("common.create"), actionID: "skills.sheet.new.confirm", canAct: valid, cancelID: "skills.sheet.new.cancel",
                   action: {
                       await tool.create(id: id, group: group, template: template, name: name.trimmingCharacters(in: .whitespaces),
                                         description: description.trimmingCharacters(in: .whitespacesAndNewlines))
                   }) {
            Form {
                Picker(L("skills.new.template"), selection: $template) {
                    ForEach(SkillTemplate.allCases) { Text($0.title).tag($0) }
                }
                .help(template.detail).accessibilityIdentifier("skills.sheet.new.template")
                TextField(L("skills.new.name"), text: $name, prompt: Text(L("skills.new.namePrompt")))
                    .accessibilityIdentifier("skills.sheet.new.name")
                    .onChange(of: name) { if !idEdited { id = SkillIDs.slug(name) } }
                TextField(L("skills.new.id"), text: $id, prompt: Text(L("skills.new.idPrompt")))
                    .onChange(of: id) { if id != SkillIDs.slug(name) { idEdited = true } }
                    .accessibilityIdentifier("skills.sheet.new.id")
                if taken {
                    Text(L("error.skills_exists")).font(.uiCaption).foregroundStyle(Brand.danger)
                        .accessibilityIdentifier("skills.sheet.new.taken")
                } else if !id.isEmpty && !SkillIDs.isValid(id) {
                    Text(L("error.skills_invalid_id")).font(.uiCaption).foregroundStyle(Brand.danger)
                        .accessibilityIdentifier("skills.sheet.new.invalid")
                }
                TextField(L("skills.new.description"), text: $description, prompt: Text(L("skills.new.descriptionPrompt")), axis: .vertical)
                    .lineLimit(2...4).accessibilityIdentifier("skills.sheet.new.description")
                Picker(L("skills.group"), selection: $group) {
                    ForEach(tool.groups) { Text($0.name).tag($0.id) }
                }
                .accessibilityIdentifier("skills.sheet.new.group")
            }
            .formStyle(.grouped)
        }
        .onAppear { group = defaultGroup }
    }

    /// The group on screen, else the first one.
    private var defaultGroup: String {
        if case .group(let id) = tool.scope, tool.group(id) != nil { return id }
        return tool.groups.first?.id ?? ""
    }
}

/// «Mover a grupo…».
struct MoveSkillSheet: View {
    let tool: SkillsTool
    let skillID: String
    @State private var group = ""

    var body: some View {
        let skill = tool.skill(skillID)
        SheetFrame(title: L("skills.move.title"), symbol: Symbols.moveToGroup, detail: skill?.name, width: 420,
                   actionTitle: L("skills.move.action"), actionID: "skills.sheet.move.confirm",
                   canAct: skill != nil && group != skill?.group && !group.isEmpty, cancelID: "skills.sheet.move.cancel",
                   action: {
                       guard let skill else { return false }
                       await tool.update(skill, group: group)
                       return true
                   }) {
            Form {
                Picker(L("skills.group"), selection: $group) {
                    ForEach(tool.groups) { Text($0.name).tag($0.id) }
                }
                .accessibilityIdentifier("skills.sheet.move.group")
            }
            .formStyle(.grouped)
        }
        .onAppear { group = skill?.group ?? "" }
    }
}

/// «Renombrar…»: the skill's identifier (its folder and the name in its file). «Continuar» opens
/// the confirmation with the links of the assistants that go and the ones made under the new name.
struct RenameSkillSheet: View {
    let tool: SkillsTool
    let skillID: String
    @State private var id = ""

    private var taken: Bool { id != skillID && tool.skill(id) != nil }

    var body: some View {
        let skill = tool.skill(skillID)
        SheetFrame(title: L("skills.rename.title"), symbol: Symbols.renameProject, detail: skill?.name,
                   note: (skill?.agents.isEmpty ?? true) ? nil : L("skills.rename.note"), width: 440,
                   actionTitle: L("skills.rename.review"), actionID: "skills.sheet.rename.confirm",
                   canAct: skill != nil && id != skillID && SkillIDs.isValid(id) && !taken, cancelID: "skills.sheet.rename.cancel",
                   action: {
                       guard let skill else { return false }
                       // The links it removes and creates are shown (and confirmed) next, in this same sheet.
                       tool.requestRename(skill, to: id)
                       return false
                   }) {
            Form {
                TextField(L("skills.new.id"), text: $id).accessibilityIdentifier("skills.sheet.rename.id")
                if taken {
                    Text(L("error.skills_exists")).font(.uiCaption).foregroundStyle(Brand.danger)
                } else if !id.isEmpty && !SkillIDs.isValid(id) {
                    Text(L("error.skills_invalid_id")).font(.uiCaption).foregroundStyle(Brand.danger)
                }
            }
            .formStyle(.grouped)
        }
        .onAppear { id = skillID }
    }
}

/// «Agregar IA…» (or its edit): an assistant that is not built in, with the folder where it reads
/// skills. The folder must be inside the home folder.
struct CustomAgentSheet: View {
    let tool: SkillsTool
    let agentID: String?
    @State private var name = ""
    @State private var folder = ""

    private var existing: SkillAgent? { agentID.flatMap(tool.agent) }
    private var id: String {
        agentID ?? SkillIDs.unique(SkillIDs.slug(name).isEmpty ? "ia" : SkillIDs.slug(name), taken: Set(tool.agents.map(\.id)))
    }
    private var valid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && name.count <= 40 && (folder.hasPrefix("~") || folder.hasPrefix("/"))
    }

    var body: some View {
        SheetFrame(title: agentID == nil ? L("skills.agent.new.title") : L("skills.agent.edit.title"), symbol: Symbols.ai,
                   detail: L("skills.agent.new.detail"), width: 520,
                   actionTitle: agentID == nil ? L("common.create") : L("common.save"), actionID: "skills.sheet.agent.confirm",
                   canAct: valid, cancelID: "skills.sheet.agent.cancel",
                   action: { await tool.saveAgent(id: id, name: name.trimmingCharacters(in: .whitespaces), folder: folder) }) {
            Form {
                TextField(L("skills.agent.name"), text: $name, prompt: Text(L("skills.agent.namePrompt")))
                    .accessibilityIdentifier("skills.sheet.agent.name")
                LabeledContent(L("skills.agent.folder")) {
                    HStack {
                        TextField(L("skills.agent.folder"), text: $folder, prompt: Text(L("skills.agent.folderPrompt")))
                            .labelsHidden().truncationMode(.middle).accessibilityIdentifier("skills.sheet.agent.folder")
                        Button(L("skills.agent.chooseEllipsis")) { choose() }.accessibilityIdentifier("skills.sheet.agent.choose")
                    }
                }
            }
            .formStyle(.grouped)
        }
        .onAppear {
            name = existing?.name ?? ""
            folder = existing?.folder ?? ""
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory())
        if panel.runModal() == .OK, let url = panel.url { folder = (url.path as NSString).abbreviatingWithTildeInPath }
    }
}
