import Foundation
import Testing
@testable import ButakeStack

private let listJSON = """
{"groups": [{"id": "personal", "name": "Personal", "order": 0}, {"id": "trabajo", "name": "Trabajo", "order": 1}],
 "skills": [
   {"id": "commits", "name": "Commits", "description": "Reglas de commits", "group": "personal", "tags": ["git"],
    "enabled": true, "agents": ["claude"], "files": ["helper.sh"], "modified": 1760000000},
   {"id": "publicar", "name": "Publicar", "description": "", "group": "trabajo", "tags": [],
    "enabled": false, "agents": [], "files": [], "modified": 1760000100}],
 "agents": [{"id": "claude", "name": "Claude", "folder": "~/.claude/skills", "mode": "link", "builtin": true, "exists": false},
            {"id": "chatgpt", "name": "ChatGPT", "folder": null, "mode": "export", "builtin": true, "exists": false},
            {"id": "kiro", "name": "Kiro", "folder": null, "mode": "export", "builtin": true, "exists": false}],
 "tags": ["git"]}
"""

/// What the engine sends decodes as the tool reads it.
@Test func skillsStateDecodes() throws {
    let state = try JSONDecoder().decode(SkillsState.self, from: Data(listJSON.utf8))
    #expect(state.groups.map(\.id) == ["personal", "trabajo"] && state.tags == ["git"])
    #expect(state.skills[0].agents == ["claude"] && state.skills[0].files == ["helper.sh"] && !state.skills[1].enabled)
    #expect(state.agents[0].linksFolder && !state.agents[1].linksFolder && state.agents[1].folder == nil)
    #expect(state.agents[2].id == "kiro" && !state.agents[2].linksFolder && state.agents[2].folder == nil)
    #expect(state.skills[0].matches("COMMITS") && state.skills[0].matches("git") && !state.skills[0].matches("nada"))

    let problems = try JSONDecoder().decode([SkillProblem].self, from: Data(
        #"[{"kind": "no_description", "skill": "publicar"}, {"kind": "broken_link", "skill": "commits", "agent": "claude", "path": "/qa/x"}, {"kind": "missing_folder", "agent": "mia", "path": "/qa/y"}, {"kind": "moved_folder", "agent": "codex", "path": "/qa/.codex/skills"}]"#.utf8))
    #expect(problems.map(\.kind) == [.noDescription, .brokenLink, .missingFolder, .movedFolder])
    #expect(Set(problems.map(\.id)).count == 4)

    let plan = try JSONDecoder().decode(SkillLinkPlan.self, from: Data(
        #"{"create": ["/qa/a"], "remove": [], "conflicts": [{"path": "/qa/b", "reason": "exists"}]}"#.utf8))
    #expect(plan.create == ["/qa/a"] && plan.conflicts.first?.reason == "exists" && !plan.isEmpty)
}

/// The list the content column shows: the scope, then the filters and the search.
@Test @MainActor func visibleSkillsFollowScopeFiltersAndSearch() throws {
    let tool = SkillsTool()
    tool.state = try JSONDecoder().decode(SkillsState.self, from: Data(listJSON.utf8))
    #expect(tool.visible.map(\.id) == ["commits", "publicar"])
    tool.scope = .group("trabajo")
    #expect(tool.visible.map(\.id) == ["publicar"])
    tool.scope = .all
    tool.tagFilter = "git"
    #expect(tool.visible.map(\.id) == ["commits"] && tool.filtering)
    tool.tagFilter = nil
    tool.agentFilter = "claude"
    #expect(tool.visible.map(\.id) == ["commits"])
    tool.agentFilter = nil
    tool.search = "publi"
    #expect(tool.visible.map(\.id) == ["publicar"])
    tool.search = ""
    tool.problems = [SkillProblem(kind: .noDescription, skill: "publicar", agent: nil, path: nil)]
    // «Salud» opens in the detail: the list keeps every skill.
    tool.scope = .health
    #expect(tool.visible.count == tool.skills.count)
    tool.selection = "commits"
    tool.scopeChanged()
    #expect(tool.selection == nil)
    #expect(tool.count(in: "personal") == 1 && tool.groupName("trabajo") == "Trabajo")
}

/// Ids follow the engine's rule, and a request names the links exactly as the engine reads them.
@Test func skillIDsAndLinkRequests() throws {
    #expect(SkillIDs.slug("Publicar la app") == "publicar-la-app" && SkillIDs.slug("  Diseño & Código ") == "diseno-codigo")
    #expect(SkillIDs.slug("***").isEmpty && SkillIDs.slug(String(repeating: "a", count: 90)).count == 64)
    for good in ["commits", "a", "publicar-app-2"] { #expect(SkillIDs.isValid(good), "\(good)") }
    for bad in ["", "-a", "a-", "A", "a b", "ñ", String(repeating: "a", count: 65)] { #expect(!SkillIDs.isValid(bad), "\(bad)") }
    #expect(SkillIDs.unique("copia", taken: ["copia", "copia-2"]) == "copia-3" && SkillIDs.unique("nueva", taken: ["copia"]) == "nueva")

    let change = SkillLinkRequest(skill: "commits", changes: [SkillLinkChange(skill: "commits", agent: "claude", on: true)])
    let plan = change.payload(method: "skillsLinkPlan")
    #expect(plan["method"] as? String == "skillsLinkPlan" && plan["confirmed"] == nil)
    let listed = try #require(plan["changes"] as? [[String: Any]])
    #expect(listed.first?["skill"] as? String == "commits" && listed.first?["agent"] as? String == "claude" && listed.first?["on"] as? Bool == true)
    let migrate = SkillLinkRequest(skill: "", operation: .migrate(agent: "codex"))
    #expect(migrate.operationPayload(confirmed: false)["method"] as? String == "skillsLinkPlan" && migrate.operationPayload(confirmed: false)["confirmed"] == nil)
    #expect(migrate.operationPayload(confirmed: true)["method"] as? String == "skillsLinkApply" && migrate.operationPayload(confirmed: true)["migrate"] as? String == "codex")
    let off = SkillLinkRequest(skill: "commits", enabled: false).payload(method: "skillsLinkApply", confirmed: true)
    #expect(off["skill"] as? String == "commits" && off["enabled"] as? Bool == false && off["confirmed"] as? Bool == true && off["changes"] == nil)
    #expect(SkillDetail.parse(" Git, publicar,git ,, ") == ["git", "publicar"])
}

/// Rename, delete, restore and removing an assistant are planned (`plan`) before they are applied (`confirmed`).
@Test func skillOperationsArePlannedThenConfirmed() throws {
    let cases: [(SkillLinkRequest.Operation, String, String, String)] = [
        (.rename(to: "b"), "skillsRename", "id", "a"), (.delete, "skillsDelete", "id", "a"),
        (.restore(trashId: "a-1"), "skillsRestore", "trashId", "a-1"), (.removeAgent(id: "mia"), "skillsAgentRemove", "id", "mia"),
    ]
    for (operation, method, key, value) in cases {
        let request = SkillLinkRequest(skill: "a", operation: operation)
        let plan = request.operationPayload(confirmed: false)
        #expect(plan["method"] as? String == method && plan[key] as? String == value && plan["plan"] as? Bool == true && plan["confirmed"] == nil)
        let apply = request.operationPayload(confirmed: true)
        #expect(apply["method"] as? String == method && apply["confirmed"] as? Bool == true && apply["plan"] == nil)
        #expect(request.alwaysActs)
    }
    #expect(!SkillLinkRequest(skill: "a").alwaysActs)
}

/// Off, the tool answers `plugin_disabled`: nothing of it reaches the disk.
@Test func skillsMethodsAreOffByDefault() async throws {
    do {
        let _: SkillsState = try await StackEngine().call(["method": "skillsList"])
        Issue.record("The tool is off: it must refuse")
    } catch let error as EngineFailure {
        #expect(error.code == "plugin_disabled")
    }
}
