import SwiftUI

/// One switch per AI assistant: on, the assistant's folder gets a link to the skill. A change opens
/// the confirmation with the exact links to make or remove; nothing happens before it.
struct SkillAgentsSection: View {
    let tool: SkillsTool
    let skill: Skill

    var body: some View {
        Section {
            ForEach(tool.agents) { agent in
                if agent.linksFolder {
                    SkillAgentRow(tool: tool, skill: skill, agent: agent)
                } else {
                    LabeledContent(agent.name) {
                        Button { Task { await tool.copyExport(skill) } } label: { Label(L("skills.agent.copyText"), systemImage: Symbols.copy) }
                            .accessibilityIdentifier("skills.agent.\(agent.id).copy")
                    }
                    .help(agent.id == "kiro" ? L("skills.agent.exportHelp.kiro") : L("skills.agent.exportHelp"))
                    .accessibilityIdentifier("skills.agent.\(agent.id)")
                }
            }
            Button { tool.sheet = .agent(nil) } label: { Label(L("skills.agent.addEllipsis"), systemImage: Symbols.add) }
                .accessibilityIdentifier("skills.agent.add")
        } header: {
            Text(L("skills.section.agents"))
        } footer: {
            SettingsFooter(skill.enabled ? L("skills.agents.footer") : L("skills.agents.footerOff"))
        }
    }
}

/// An assistant whose folder takes the links, with its switch and, for the ones the user added, a menu.
struct SkillAgentRow: View {
    let tool: SkillsTool
    let skill: Skill
    let agent: SkillAgent

    private var isOn: Binding<Bool> {
        Binding(get: { skill.agents.contains(agent.id) }, set: { on in
            tool.requestLinks(SkillLinkRequest(skill: skill.id, changes: [SkillLinkChange(skill: skill.id, agent: agent.id, on: on)]))
        })
    }

    var body: some View {
        HStack {
            Toggle(isOn: isOn) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(agent.name)
                    Text(agent.folder ?? "").font(.uiCaption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            .disabled(!skill.enabled)
            .help(skill.enabled ? (agent.folder ?? "") : L("skills.agents.footerOff"))
            .accessibilityIdentifier("skills.agent.\(agent.id)")
            if !agent.builtin {
                Menu {
                    Button { tool.sheet = .agent(agent.id) } label: { Label(L("skills.agent.editEllipsis"), systemImage: Symbols.edit) }
                        .accessibilityIdentifier("skills.agent.\(agent.id).edit")
                    Button(role: .destructive) { tool.requestRemoveAgent(agent) } label: { Label(L("skills.agent.removeEllipsis"), systemImage: Symbols.delete) }
                        .accessibilityIdentifier("skills.agent.\(agent.id).remove")
                } label: { Label(L("skills.more"), systemImage: Symbols.more) }
                    .menuStyle(.borderlessButton).labelStyle(.iconOnly).fixedSize()
                    .help(L("skills.more")).accessibilityIdentifier("skills.agent.\(agent.id).more")
            }
        }
    }
}
