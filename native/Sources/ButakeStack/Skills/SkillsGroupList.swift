import SwiftUI

/// The Skills tool's content column: one list (Salud on top, then a section per group, as Git's
/// sidebar), and at the bottom the filters and «Grupos…». Everything scrolls under the toolbar with
/// the same background, so there is no band of its own above the list.
struct SkillsGroupList: View {
    @Bindable var tool: SkillsTool

    var body: some View {
        VStack(spacing: 0) {
            SkillsList(tool: tool)
            HStack {
                SkillsFilterMenu(tool: tool)
                Spacer()
                Button { tool.sheet = .groups } label: { Label(L("skills.groups.manage"), systemImage: Symbols.folder) }
                    .buttonStyle(.borderless).labelStyle(.iconOnly)
                    .help(L("skills.groups.manageHelp")).accessibilityIdentifier("skills.list.groups")
            }
            .padding(.horizontal, 10).frame(height: 29)
            .overlay(alignment: .top) { Divider() }
        }
    }
}

/// Filters of the list: by group, by tag and by assistant.
struct SkillsFilterMenu: View {
    @Bindable var tool: SkillsTool

    private var groupFiltered: Bool { if case .group = tool.scope { true } else { false } }

    private var title: String {
        let active = [tool.tagFilter, tool.agentFilter].compactMap { $0 }.count + (groupFiltered ? 1 : 0)
        return active == 0 ? L("skills.filter") : String(format: L("skills.filter.active"), active)
    }

    private var tag: Binding<String?> { Binding(get: { tool.tagFilter }, set: { tool.requestFilter(.tag($0)) }) }
    private var agent: Binding<String?> { Binding(get: { tool.agentFilter }, set: { tool.requestFilter(.agent($0)) }) }

    /// «Cualquiera» or one group; Salud is a row of the list, not a filter.
    private var group: Binding<String?> {
        Binding(get: { if case .group(let id) = tool.scope { id } else { nil } },
                set: { tool.requestFilter(.group($0)) })
    }

    var body: some View {
        Menu {
            Picker(L("skills.filter.group"), selection: group) {
                Text(L("skills.filter.any")).tag(String?.none)
                ForEach(tool.groups) { Text($0.name).tag(String?.some($0.id)) }
            }
            Picker(L("skills.filter.tag"), selection: tag) {
                Text(L("skills.filter.any")).tag(String?.none)
                ForEach(tool.tags, id: \.self) { Text($0).tag(String?.some($0)) }
            }
            Picker(L("skills.filter.agent"), selection: agent) {
                Text(L("skills.filter.any")).tag(String?.none)
                ForEach(tool.agents) { Text($0.name).tag(String?.some($0.id)) }
            }
            if tool.filtering || groupFiltered {
                Divider()
                Button(L("skills.filter.clear")) { tool.requestFilter(.clear) }
                    .accessibilityIdentifier("skills.list.filter.clear")
            }
        } label: { Label(title, systemImage: Symbols.filter) }
            .menuStyle(.borderlessButton).fixedSize()
            .help(L("skills.filter.help")).accessibilityIdentifier("skills.list.filter")
    }
}
