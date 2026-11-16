#if DEBUG
import Foundation

/// Screenshots of the Skills tool (debug builds with BUTAKE_QA_WINDOW and a separate
/// BUTAKE_STACK_HOME and HOME): the AI folders are the ones of the temporary home, never the owner's.
///
///     BUTAKE_QA_SKILLS=<id>            the selected skill
///     BUTAKE_QA_SKILLS_SCOPE=health    «Salud» (or a group id)
///     BUTAKE_QA_SKILLS_SHEET=new|groups|move|rename|agent|links   a sheet on the selected skill
extension QAHooks {
    private static func skillsValue(_ name: String) -> String? {
        let env = ProcessInfo.processInfo.environment
        return StackStore.qaWindow && env["BUTAKE_STACK_HOME"] != nil ? env[name] : nil
    }

    static func skills(_ tool: SkillsTool) async {
        if let scope = skillsValue("BUTAKE_QA_SKILLS_SCOPE") {
            tool.scope = scope == "health" ? .health : tool.group(scope) == nil ? .all : .group(scope)
        }
        if let id = skillsValue("BUTAKE_QA_SKILLS") { tool.selection = id }
        guard let sheet = skillsValue("BUTAKE_QA_SKILLS_SHEET") else { return }
        let selected = tool.selection ?? tool.skills.first?.id ?? ""
        switch sheet {
        case "new": tool.sheet = .newSkill
        case "groups": tool.sheet = .groups
        case "move": tool.sheet = .move(selected)
        case "rename": tool.sheet = .rename(selected)
        case "agent": tool.sheet = .agent(nil)
        case "links":
            if let agent = tool.agents.first(where: \.linksFolder) {
                tool.requestLinks(SkillLinkRequest(skill: selected, changes: [SkillLinkChange(skill: selected, agent: agent.id, on: true)]))
            }
        default: break
        }
    }
}
#endif
