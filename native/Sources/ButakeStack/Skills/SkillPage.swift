import SwiftUI

/// The Skills tool's detail: the selected skill, the health of the skills (under «Salud» with no
/// skill selected) or why there is nothing to show. Its actions live in the toolbar: «Nueva
/// skill…», «Duplicar», «Exportar…» and the rest in «Más».
struct SkillPage: View {
    @Bindable var store: StackStore
    @Bindable var tool = SkillsTool.shared

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .top, spacing: 0) { VStack(spacing: 0) { deletedNotice; renameConflictsNotice } }
            .toolbar { toolbar }
            .skillsSheets(tool)
            .task {
                await tool.load()
                #if DEBUG
                await QAHooks.skills(tool)
                #endif
            }
    }

    @ViewBuilder private var content: some View {
        if let skill = tool.selected {
            SkillDetail(tool: tool, skill: skill).id(skill.id)
        } else if !tool.loaded {
            ProgressView()
        } else if tool.loadFailed {
            ContentUnavailableView {
                Label(L("skills.loadFailed"), systemImage: Symbols.error)
            } actions: {
                Button { Task { await tool.load() } } label: { Label(L("common.retry"), systemImage: Symbols.reload) }
                    .buttonStyle(.bordered).accessibilityIdentifier("skills.empty.retry")
            }
        } else if tool.scope == .health {
            SkillsHealthPanel(tool: tool)
        } else if tool.skills.isEmpty {
            ContentUnavailableView {
                Label(L("skills.empty"), systemImage: Symbols.skill)
            } description: {
                Text(L("skills.emptyDetail"))
            } actions: {
                Button { tool.sheet = .newSkill } label: { Label(L("skills.newEllipsis"), systemImage: Symbols.add) }
                    .buttonStyle(.borderedProminent).accessibilityIdentifier("skills.detail.empty.new")
            }
        } else {
            ContentUnavailableView(L("skills.noSelection"), systemImage: Symbols.skill, description: Text(L("skills.noSelectionDetail")))
        }
    }

    /// After deleting: what went and the way back.
    @ViewBuilder private var deletedNotice: some View {
        if let deleted = tool.deleted {
            Notice(.success, String(format: L("skills.deleted"), deleted.name), detail: L("skills.deletedDetail")) {
                Button(L("skills.undo")) { tool.requestUndoDelete() }
                    .buttonStyle(.bordered).accessibilityIdentifier("skills.deleted.undo")
                Button { tool.deleted = nil } label: { Label(L("common.close"), systemImage: Symbols.close) }
                    .labelStyle(.iconOnly).buttonStyle(.borderless).help(L("common.close"))
                    .accessibilityIdentifier("skills.deleted.close")
            }
            .padding(12)
        }
    }

    /// After renaming: the AI folders where the new name was already taken (nothing there was touched).
    @ViewBuilder private var renameConflictsNotice: some View {
        if !tool.renameConflicts.isEmpty {
            Notice(.warning, L("skills.renameConflicts"),
                   detail: tool.renameConflicts.map(\.path).joined(separator: "\n") + "\n" + L("skills.renameConflictsDetail")) {
                Button(L("skills.renameConflictsHealth")) { tool.showHealthAfterRename() }
                    .buttonStyle(.bordered).accessibilityIdentifier("skills.renameConflicts.health")
                Button { tool.renameConflicts = [] } label: { Label(L("common.close"), systemImage: Symbols.close) }
                    .labelStyle(.iconOnly).buttonStyle(.borderless).help(L("common.close"))
                    .accessibilityIdentifier("skills.renameConflicts.close")
            }
            .padding(12)
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            // «Nueva skill…» lives in the window's own «+» (one per window), like the Terminal's additions.
            Button { if let skill = tool.selected { Task { await tool.duplicate(skill) } } } label: {
                Label(L("skills.duplicate"), systemImage: Symbols.duplicate)
            }
            .disabled(tool.selected == nil).help(L("skills.duplicateHelp")).accessibilityIdentifier("skills.toolbar.duplicate")
            Menu {
                if let skill = tool.selected { SkillExportMenu(tool: tool, skill: skill) }
            } label: { Label(L("skills.exportEllipsis"), systemImage: Symbols.share) }
                .disabled(tool.selected == nil).help(L("skills.exportHelp")).accessibilityIdentifier("skills.toolbar.export")
            Menu {
                if let skill = tool.selected { SkillMoreMenu(tool: tool, skill: skill) }
            } label: { Label(L("skills.more"), systemImage: Symbols.more) }
                .disabled(tool.selected == nil).help(L("skills.more")).accessibilityIdentifier("skills.toolbar.more")
        }
    }
}

/// «Exportar…»: the skill as text for ChatGPT or Kiro, or as a Markdown file.
struct SkillExportMenu: View {
    let tool: SkillsTool
    let skill: Skill
    var body: some View {
        Button { Task { await tool.copyExport(skill) } } label: { Label(L("skills.export.copy"), systemImage: Symbols.copy) }
            .accessibilityIdentifier("skills.menu.exportCopy")
        Button { Task { await tool.saveExport(skill) } } label: { Label(L("skills.export.saveEllipsis"), systemImage: Symbols.save) }
            .accessibilityIdentifier("skills.menu.exportSave")
    }
}

/// The actions on a skill in the toolbar's «Más».
struct SkillMoreMenu: View {
    let tool: SkillsTool
    let skill: Skill
    var body: some View {
        Button { tool.sheet = .move(skill.id) } label: { Label(L("skills.moveEllipsis"), systemImage: Symbols.moveToGroup) }
            .accessibilityIdentifier("skills.menu.move")
        Button { tool.sheet = .rename(skill.id) } label: { Label(L("skills.renameEllipsis"), systemImage: Symbols.renameProject) }
            .accessibilityIdentifier("skills.menu.rename")
        Button { tool.requestLinks(SkillLinkRequest(skill: skill.id, enabled: !skill.enabled)) } label: {
            Label(skill.enabled ? L("skills.deactivate") : L("skills.activate"), systemImage: Symbols.activate)
        }
        .accessibilityIdentifier("skills.menu.toggle")
        Divider()
        Button(role: .destructive) { tool.requestDelete(skill) } label: { Label(L("skills.deleteEllipsis"), systemImage: Symbols.delete) }
            .accessibilityIdentifier("skills.menu.delete")
    }
}

/// A skill's card: what it is, how it is filed, which assistants use it and its text.
struct SkillDetail: View {
    @Bindable var tool: SkillsTool
    let skill: Skill
    @State private var tags = ""

    private var chip: some View {
        Group {
            if !skill.enabled { Chip(text: L("skills.off"), symbol: Symbols.activate, help: L("skills.off.help")) }
        }
    }

    var body: some View {
        Form {
            Section {
                CloudCardHeader(symbol: Symbols.skill, title: skill.name, subtitle: skill.id,
                                titleIdentifier: "skills.detail.name", selectable: true) { chip }
                if !skill.description.isEmpty {
                    Text(skill.description).font(.uiCallout).foregroundStyle(.secondary).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).accessibilityIdentifier("skills.detail.description")
                }
                if !skill.enabled {
                    Notice(.warning, L("skills.off.title"), detail: L("skills.off.detail")) {
                        Button(L("skills.activate")) { tool.requestLinks(SkillLinkRequest(skill: skill.id, enabled: true)) }
                            .buttonStyle(.bordered).accessibilityIdentifier("skills.detail.activate")
                    }
                }
            }
            details
            SkillAgentsSection(tool: tool, skill: skill)
            SkillEditorPanel(tool: tool, skill: skill)
        }
        .formStyle(.grouped).themedScroll()
        .accessibilityIdentifier("skills.detail")
        .onAppear { tags = skill.tags.joined(separator: ", ") }
        .onChange(of: skill.tags) { tags = skill.tags.joined(separator: ", ") }
    }

    private var details: some View {
        Section(L("skills.section.details")) {
            Picker(L("skills.group"), selection: Binding(get: { skill.group }, set: { new in Task { await tool.update(skill, group: new) } })) {
                ForEach(tool.groups) { Text($0.name).tag($0.id) }
            }
            .accessibilityIdentifier("skills.detail.group")
            LabeledContent(L("skills.tags")) {
                TextField(L("skills.tags"), text: $tags, prompt: Text(L("skills.tags.prompt")))
                    .labelsHidden().multilineTextAlignment(.trailing)
                    .onSubmit { Task { await tool.update(skill, tags: Self.parse(tags)) } }
                    .accessibilityIdentifier("skills.detail.tags")
            }
            .help(L("skills.tags.help"))
            LabeledContent(L("skills.modified")) {
                Text(skill.modifiedDate, format: .dateTime.day().month().year().hour().minute()).foregroundStyle(.secondary)
            }
            .accessibilityIdentifier("skills.detail.modified")
            if skill.files.count > 1 {
                LabeledContent(L("skills.files")) {
                    Text(skill.files.joined(separator: ", ")).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                }
                .help(skill.files.joined(separator: "\n")).accessibilityIdentifier("skills.detail.files")
            }
        }
    }

    /// Tags as typed: separated by commas, without blanks or repeats.
    static func parse(_ text: String) -> [String] {
        var seen: [String] = []
        for part in text.split(separator: ",") {
            let tag = part.trimmingCharacters(in: .whitespaces).lowercased()
            if !tag.isEmpty, !seen.contains(tag) { seen.append(tag) }
        }
        return seen
    }
}
