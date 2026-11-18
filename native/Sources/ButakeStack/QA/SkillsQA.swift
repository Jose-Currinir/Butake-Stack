#if DEBUG
import Foundation

/// Screenshots of the Skills tool (debug builds with BUTAKE_QA_WINDOW and a separate
/// BUTAKE_STACK_HOME and HOME): the AI folders are the ones of the temporary home, never the owner's.
///
///     BUTAKE_QA_SKILLS=<id>            the selected skill
///     BUTAKE_QA_SKILLS_SCOPE=health    «Salud» (or a group id)
///     BUTAKE_QA_SKILLS_SHEET=new|groups|move|rename|agent|links|import|importTrash|deletedTrash   a sheet
///     BUTAKE_QA_SKILLS_TYPE=<text>     the editor of the selected skill gets that text typed (unsaved)
///     BUTAKE_QA_SKILLS_OUTSIDE=1       two seconds later its SKILL.md changes on disk, as another program would
///     BUTAKE_QA_SKILLS_IMPORT=plan     «Importar skills existentes…» goes on to its plan by itself
extension QAHooks {
    private static func skillsValue(_ name: String) -> String? {
        let env = ProcessInfo.processInfo.environment
        return StackStore.qaWindow && env["BUTAKE_STACK_HOME"] != nil ? env[name] : nil
    }

    /// The import sheet shows its plan (what the preselected skills would change) without a click.
    static var skillsImportPlan: Bool { skillsValue("BUTAKE_QA_SKILLS_IMPORT") == "plan" }

    /// Text the editor appends once it has loaded the skill, as if the user had typed it.
    static var skillsTyped: String? { skillsValue("BUTAKE_QA_SKILLS_TYPE") }

    /// Rewrites `SKILL.md` of `id` in the temporary data folder and reads the list again, so the
    /// editor sees a change made outside Stack.
    private static func changeOutside(_ tool: SkillsTool, id: String) async {
        guard let home = skillsValue("BUTAKE_STACK_HOME") else { return }
        let file = URL(fileURLWithPath: home).appendingPathComponent("skills/\(id)/SKILL.md")
        guard let old = try? String(contentsOf: file, encoding: .utf8) else { return }
        try? (old + "\nLínea agregada desde otro programa.\n").write(to: file, atomically: true, encoding: .utf8)
        await tool.load()
    }

    static func skills(_ tool: SkillsTool) async {
        if let scope = skillsValue("BUTAKE_QA_SKILLS_SCOPE") {
            tool.scope = scope == "health" ? .health : tool.group(scope) == nil ? .all : .group(scope)
        }
        if let id = skillsValue("BUTAKE_QA_SKILLS") { tool.selection = id }
        if skillsValue("BUTAKE_QA_SKILLS_OUTSIDE") == "1", let id = tool.selection {
            try? await Task.sleep(for: .seconds(2))
            await changeOutside(tool, id: id)
        }
        guard let sheet = skillsValue("BUTAKE_QA_SKILLS_SHEET") else { return }
        let selected = tool.selection ?? tool.skills.first?.id ?? ""
        switch sheet {
        case "new": tool.sheet = .newSkill
        case "groups": tool.sheet = .groups
        case "move": tool.sheet = .move(selected)
        case "rename": tool.sheet = .rename(selected)
        case "agent": tool.sheet = .agent(nil)
        case "import": tool.sheet = .importExisting
        case "importTrash": tool.sheet = .importTrash
        case "deletedTrash": tool.sheet = .deletedTrash
        case "links":
            if let agent = tool.agents.first(where: \.linksFolder) {
                tool.requestLinks(SkillLinkRequest(skill: selected, changes: [SkillLinkChange(skill: selected, agent: agent.id, on: true)]))
            }
        default: break
        }
    }
}
#endif
