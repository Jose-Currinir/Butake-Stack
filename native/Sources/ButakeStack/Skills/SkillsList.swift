import SwiftUI

/// The skills of the scope on screen. Under «Todas» they go in a section per group.
struct SkillsList: View {
    @Bindable var tool: SkillsTool

    /// Tag of the «Salud» row: a skill id is only `[a-z0-9-]`, so it can never be one.
    private static let healthTag = "#health"

    /// One selection for the list: «Salud» opens the health of the skills in the detail, a skill its page.
    private var selection: Binding<String?> {
        Binding(get: { tool.scope == .health ? Self.healthTag : tool.selection },
                set: { value in
                    if value == Self.healthTag {
                        tool.requestHealth()
                    } else {
                        if tool.scope == .health { tool.scope = .all }
                        tool.requestSelection(value)
                    }
                })
    }

    var body: some View {
        let shown = tool.visible
        List(selection: selection) {
            Section {
                Label(L("skills.scope.health"), systemImage: Symbols.skillsHealth)
                    .badge(tool.problems.count)
                    .tag(Self.healthTag)
                    .accessibilityIdentifier("skills.list.health")
            }
            ForEach(tool.groups) { group in
                let members = shown.filter { $0.group == group.id }
                if !members.isEmpty {
                    Section(group.name) { rows(members) }
                }
            }
        }
        .listStyle(.sidebar)
        .themedScroll()
        .overlay { empty(shown) }
        .searchable(text: $tool.search, placement: .sidebar, prompt: L("skills.search"))
        .accessibilityIdentifier("skills.list")
        .confirmationDialog(L("skills.editor.switch.title"), isPresented: Binding(get: { tool.pendingSelection != nil },
                                                                                   set: { if !$0 { tool.keepEditing() } }),
                            titleVisibility: .visible) {
            Button(L("skills.editor.switch.discard"), role: .destructive) { tool.discardAndSwitch() }
                .accessibilityIdentifier("skills.editor.switch.discard")
            Button(L("common.cancel"), role: .cancel) { tool.keepEditing() }
                .accessibilityIdentifier("skills.editor.switch.keep")
        } message: {
            Text(L("skills.editor.switch.detail"))
        }
    }

    private func rows(_ skills: [Skill]) -> some View {
        ForEach(skills) { skill in
            SkillRow(skill: skill, tool: tool).tag(skill.id)
        }
    }

    @ViewBuilder private func empty(_ shown: [Skill]) -> some View {
        if !tool.loaded {
            ProgressView()
        } else if shown.isEmpty {
            if !tool.search.isEmpty {
                ContentUnavailableView.search(text: tool.search)
            } else if tool.filtering {
                ContentUnavailableView {
                    Label(L("skills.noMatches"), systemImage: Symbols.filter)
                } actions: {
                    Button(L("skills.filter.clear")) { tool.tagFilter = nil; tool.agentFilter = nil }
                        .accessibilityIdentifier("skills.empty.clearFilter")
                }
            } else if tool.scope == .health {
                ContentUnavailableView(L("skills.health.ok"), systemImage: Symbols.success, description: Text(L("skills.health.okDetail")))
            } else if tool.skills.isEmpty {
                // Only the title here: the detail says what to do and has «Nueva skill…» (said once per screen).
                ContentUnavailableView(L("skills.empty"), systemImage: Symbols.skill)
            } else {
                ContentUnavailableView(L("skills.group.empty"), systemImage: Symbols.folder, description: Text(L("skills.group.emptyDetail")))
            }
        }
    }
}

/// A skill in the list: its name, and under it whether it is off or which assistants use it.
struct SkillRow: View {
    let skill: Skill
    let tool: SkillsTool

    private var subtitle: String {
        if !skill.enabled { return L("skills.off") }
        let names = skill.agents.compactMap { tool.agent($0)?.name }
        return names.isEmpty ? L("skills.noAgents") : names.joined(separator: ", ")
    }

    private var attention: Bool { tool.problems.contains { $0.skill == skill.id && $0.kind != .unused } }

    var body: some View {
        HStack(spacing: 8) {
            IconTile(symbol: Symbols.skill, color: skill.enabled ? nil : .gray, size: 22)
            VStack(alignment: .leading, spacing: 1) {
                // A name reads from its start: cut at the end, never in the middle.
                Text(skill.name).font(.uiBody).lineLimit(1).truncationMode(.tail)
                Text(subtitle).font(.uiCaption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            }
            if attention {
                Spacer(minLength: 4)
                Image(systemName: Symbols.warning).font(.uiCaption).foregroundStyle(Brand.warning)
                    .help(L("skills.row.attention")).accessibilityLabel(L("skills.row.attention"))
            }
        }
        .help(skill.description.isEmpty ? skill.id : skill.description)
        .accessibilityIdentifier("skills.list.skill.\(skill.id)")
    }
}
