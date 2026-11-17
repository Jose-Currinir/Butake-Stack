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
        #"[{"kind": "no_description", "skill": "publicar"}, {"kind": "broken_link", "skill": "commits", "agent": "claude", "path": "/qa/x"}, {"kind": "missing_folder", "agent": "mia", "path": "/qa/y"}, {"kind": "agent_path", "skill": "commits", "agent": "claude", "path": "/qa/.claude/skills"}]"#.utf8))
    #expect(problems.map(\.kind) == [.noDescription, .brokenLink, .missingFolder, .agentPath])
    #expect(Set(problems.map(\.id)).count == 4)

    let plan = try JSONDecoder().decode(SkillLinkPlan.self, from: Data(
        #"{"create": ["/qa/a"], "remove": [], "conflicts": [{"path": "/qa/b", "reason": "exists"}]}"#.utf8))
    #expect(plan.create == ["/qa/a"] && plan.conflicts.first?.reason == "exists" && !plan.isEmpty)
}

/// `skillsRename` answers the skill and the names it could not link.
@Test func skillRenameResultDecodes() throws {
    let skill = #"{"id": "b", "name": "b", "description": "", "group": "personal", "tags": [], "enabled": true, "agents": ["gemini"], "files": [], "modified": 1760000000}"#
    let withConflict = try JSONDecoder().decode(SkillRenameResult.self, from: Data(
        #"{"skill": \#(skill), "conflicts": [{"path": "/qa/.claude/skills/b", "reason": "exists"}]}"#.utf8))
    #expect(withConflict.skill.id == "b" && withConflict.conflicts.map(\.path) == ["/qa/.claude/skills/b"] && withConflict.conflicts[0].reason == "exists")
    let clean = try JSONDecoder().decode(SkillRenameResult.self, from: Data(#"{"skill": \#(skill), "conflicts": []}"#.utf8))
    #expect(clean.conflicts.isEmpty)
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

/// `skillsImportScan` answers the candidates with their sources.
@Test func skillsImportScanDecodes() throws {
    let found = try JSONDecoder().decode([ImportCandidate].self, from: Data(
        #"""
        [{"id": "notas", "name": "Notas", "description": "Toma notas", "identical": true, "valid": true, "hidden": false,
          "sources": [{"agent": "claude", "path": "/qa/.claude/skills/notas", "kind": "folder"},
                      {"agent": "codex", "path": "/qa/.agents/skills/notas", "kind": "link"}]},
         {"id": "Mi Skill", "name": "Mi Skill", "description": "", "identical": false, "valid": false, "reason": "skills_invalid_id",
          "hidden": false, "sources": [{"agent": "gemini", "path": "/qa/.gemini/skills/Mi Skill", "kind": "folder"}]},
         {"id": ".sistema", "name": ".sistema", "description": "", "identical": true, "valid": false, "reason": "skills_invalid_id",
          "hidden": true, "sources": []}]
        """#.utf8))
    #expect(found.count == 3 && found[0].sources.map(\.kind) == ["folder", "link"] && found[0].sources[1].isLink)
    #expect(found[0].preselected && found[0].reason == nil)
    #expect(!found[1].preselected && found[1].reason == "skills_invalid_id" && !found[1].identical)
    #expect(found[2].hidden && !found[2].preselected)
}

/// `skillsImportPlan` and `skillsImportApply` answers.
@Test func skillsImportPlanAndResultDecode() throws {
    let plan = try JSONDecoder().decode(ImportPlan.self, from: Data(
        #"""
        {"copy": [{"from": "/qa/.claude/skills/notas", "id": "notas"}],
         "replace": ["/qa/.claude/skills/notas", "/qa/.agents/skills/notas"],
         "trash": ["/qa/.claude/skills/notas"], "unlink": ["/qa/.agents/skills/notas"],
         "warnings": [{"id": "notas", "skipped": ["enlace", "deep/roto"]}],
         "conflicts": [{"path": "/qa/.gemini/skills/notas", "reason": "not_chosen"}]}
        """#.utf8))
    #expect(plan.copy == [ImportPlan.Copy(from: "/qa/.claude/skills/notas", id: "notas")])
    #expect(plan.replace.count == 2 && plan.trash.count == 1 && plan.unlink == ["/qa/.agents/skills/notas"])
    #expect(plan.conflicts.first?.reason == "not_chosen")
    #expect(plan.warnings == [ImportPlan.Warning(id: "notas", skipped: ["enlace", "deep/roto"])])

    let skill = #"{"id": "notas", "name": "Notas", "description": "", "group": "personal", "tags": [], "enabled": true, "agents": ["claude", "codex"], "files": [], "modified": 1760000000}"#
    let result = try JSONDecoder().decode(ImportResult.self, from: Data(
        #"{"imported": [\#(skill)], "conflicts": [{"path": "/qa/x", "reason": "cannot_move"}]}"#.utf8))
    #expect(result.imported.map(\.id) == ["notas"] && result.imported[0].agents == ["claude", "codex"])
    #expect(result.conflicts.map(\.reason) == ["cannot_move"])
}

/// The import trash: its entries, the undo plan and the plan to empty it.
@Test func skillsImportTrashDecodes() throws {
    let list = try JSONDecoder().decode([ImportTrashEntry].self, from: Data(
        #"""
        [{"trashId": "import-notas-1760000000", "id": "notas", "created": 1760000000, "path": "/qa/skills-trash/import-notas-1760000000",
          "sources": [{"agent": "claude", "path": "/qa/.claude/skills/notas", "kind": "folder"}]}]
        """#.utf8))
    #expect(list[0].trashId == "import-notas-1760000000" && list[0].createdDate == Date(timeIntervalSince1970: 1_760_000_000))
    #expect(ImportConfirmation.undo(list[0]).id != ImportConfirmation.empty(list).id)

    let undo = try JSONDecoder().decode(ImportUndoPlan.self, from: Data(
        #"""
        {"restore": [{"from": "/qa/t/sources/0", "to": "/qa/.claude/skills/notas"}],
         "relink": [{"path": "/qa/.agents/skills/notas", "target": "/qa/otro/notas"}],
         "remove": ["/qa/.claude/skills/notas"], "trash": ["/qa/skills/notas"],
         "conflicts": [{"path": "/qa/skills/notas", "reason": "changed"}]}
        """#.utf8))
    #expect(undo.restore.first?.to == "/qa/.claude/skills/notas" && undo.relink.first?.target == "/qa/otro/notas")
    #expect(undo.remove.count == 1 && undo.trash == ["/qa/skills/notas"] && undo.conflicts.first?.reason == "changed")

    let empty = try JSONDecoder().decode(ImportEmptyPlan.self, from: Data(#"{"delete": ["/qa/skills-trash/import-notas-1760000000"]}"#.utf8))
    #expect(empty.delete.count == 1)
    let undone = try JSONDecoder().decode(ImportUndoResult.self, from: Data(#"{"restored": ["/qa/a"], "conflicts": []}"#.utf8))
    #expect(undone.restored == ["/qa/a"] && undone.conflicts.isEmpty)
}

/// The editor and a change of `SKILL.md` made outside Stack: nothing typed is lost, and an outside
/// change is never overwritten without the user choosing.
@Test func editorSyncKeepsWhatWasTypedAndTakesOutsideChanges() {
    // The file says what the editor last saved: nothing to do (also the case after Stack's own save).
    #expect(SkillEditorSync.resolve(disk: "a", saved: "a", text: "a") == .none)
    #expect(SkillEditorSync.resolve(disk: "a", saved: "a", text: "a, editado") == .none)
    // Our own save landed before the editor noted it.
    #expect(SkillEditorSync.resolve(disk: "b", saved: "a", text: "b") == .markSaved)
    // Changed outside with nothing typed: reload it.
    #expect(SkillEditorSync.resolve(disk: "b", saved: "a", text: "a") == .reload)
    // Changed outside while typing: ask.
    #expect(SkillEditorSync.resolve(disk: "b", saved: "a", text: "a, editado") == .conflict)
}

/// Changing skill with unsaved text asks first; «Seguir editando» stays, «Descartar» goes.
@MainActor @Test func switchingSkillWithUnsavedTextAsksFirst() {
    let tool = SkillsTool()
    tool.selection = "commits"
    tool.requestSelection("publicar")
    #expect(tool.selection == "publicar" && tool.pendingSelection == nil)

    tool.unsavedSkill = "publicar"
    tool.requestSelection("commits")
    #expect(tool.selection == "publicar" && tool.pendingSelection == .some("commits"))
    tool.keepEditing()
    #expect(tool.selection == "publicar" && tool.pendingSelection == nil && tool.unsavedSkill == "publicar")

    tool.requestSelection(nil)
    #expect(tool.pendingSelection == .some(nil))
    tool.discardAndSwitch()
    #expect(tool.selection == nil && tool.pendingSelection == nil && tool.unsavedSkill == nil)

    // The same skill again is not a change.
    tool.selection = "commits"
    tool.unsavedSkill = "commits"
    tool.requestSelection("commits")
    #expect(tool.pendingSelection == nil)
}

/// The «Filtros» menu follows the same rule as the list: a change that would hide the skill whose
/// editor holds unsaved text asks first; one that keeps it on screen (or with nothing unsaved) just applies.
@MainActor @Test func changingFiltersWithUnsavedTextAsksOnlyWhenItHidesTheSkill() throws {
    let tool = SkillsTool()
    tool.state = try JSONDecoder().decode(SkillsState.self, from: Data(listJSON.utf8))
    tool.selection = "commits"
    tool.unsavedSkill = "commits"

    // Still shown (personal, tag git, assistant claude): applied without asking.
    tool.requestFilter(.group("personal"))
    #expect(tool.scope == .group("personal") && tool.pendingFilter == nil && tool.selection == "commits")
    tool.requestFilter(.tag("git"))
    tool.requestFilter(.agent("claude"))
    #expect(tool.tagFilter == "git" && tool.agentFilter == "claude" && tool.pendingFilter == nil)

    // It would hide «commits»: nothing changes until the user answers.
    tool.requestFilter(.group("trabajo"))
    #expect(tool.scope == .group("personal") && tool.pendingFilter != nil && tool.selection == "commits")
    tool.keepEditing()
    #expect(tool.pendingFilter == nil && tool.scope == .group("personal") && tool.unsavedSkill == "commits")
    tool.requestFilter(.agent(nil))
    tool.requestFilter(.tag("otra"))
    #expect(tool.tagFilter == "git" && tool.pendingFilter != nil)
    tool.discardAndSwitch()
    #expect(tool.tagFilter == "otra" && tool.selection == nil && tool.unsavedSkill == nil && tool.pendingFilter == nil)

    // Widening never asks, and without unsaved text a hiding change just applies and clears the selection.
    tool.selection = "commits"
    tool.unsavedSkill = "commits"
    tool.requestFilter(.clear)
    #expect(tool.scope == .all && tool.tagFilter == nil && tool.pendingFilter == nil && tool.selection == "commits")
    tool.unsavedSkill = nil
    tool.requestFilter(.group("trabajo"))
    #expect(tool.scope == .group("trabajo") && tool.selection == nil && tool.pendingFilter == nil)
}

/// A skill with exactly one support file lists it: `files` never includes `SKILL.md`.
@Test func aSkillWithOneSupportFileShowsIt() throws {
    let state = try JSONDecoder().decode(SkillsState.self, from: Data(listJSON.utf8))
    let one = try JSONDecoder().decode(Skill.self, from: Data(
        #"{"id": "uno", "name": "Uno", "description": "", "group": "personal", "tags": [], "enabled": true, "agents": [], "files": ["helper.sh"], "modified": 1}"#.utf8))
    #expect(one.showsFiles)
    #expect(state.skills[0].showsFiles)
    #expect(!state.skills[1].showsFiles)
}

/// Two imports of the same skill are two entries: each has its own identity (the trash folder).
@Test func importTrashEntriesOfTheSameSkillHaveDifferentIdentity() throws {
    let list = try JSONDecoder().decode([ImportTrashEntry].self, from: Data(
        #"""
        [{"trashId": "import-notas-1760000000", "id": "notas", "created": 1760000000, "path": "/qa/skills-trash/import-notas-1760000000", "sources": []},
         {"trashId": "import-notas-1760000500", "id": "notas", "created": 1760000500, "path": "/qa/skills-trash/import-notas-1760000500", "sources": []}]
        """#.utf8))
    #expect(Set(list.map(\.id)).count == 2)
    #expect(list.map(\.id) == list.map(\.trashId))
    #expect(list.map(\.skill) == ["notas", "notas"])
}

/// «Skills eliminadas…»: each entry decodes with its dates and restores through the usual `.restore` request.
@Test func deletedTrashEntriesDecodeAndRestoreThroughTheLinksRequest() throws {
    let list = try JSONDecoder().decode([DeletedTrashEntry].self, from: Data(
        #"""
        [{"trashId": "notas-1760000000", "id": "notas", "name": "Notas", "description": "Toma notas", "deleted": 1760000000, "expires": 1762592000, "group": "personal"},
         {"trashId": "notas-1760000500", "id": "notas", "name": "Notas", "description": "", "deleted": 1760000500, "expires": 1762592500, "group": "personal"}]
        """#.utf8))
    #expect(Set(list.map(\.id)).count == 1)
    #expect(Set(list.map(\.trashId)).count == 2)
    #expect(list[0].expiresDate.timeIntervalSince(list[0].deletedDate) == 30 * 86_400)
    let request = list[1].restoreRequest
    #expect(request.skill == "notas")
    #expect(request.subject == "Notas")
    #expect(request.alwaysActs)
    if case .restore(let trashId) = request.operation { #expect(trashId == "notas-1760000500") } else { Issue.record("not a restore") }
    let plan = request.operationPayload(confirmed: false)
    #expect(plan["method"] as? String == "skillsRestore")
    #expect(plan["trashId"] as? String == "notas-1760000500")
    #expect(plan["plan"] as? Bool == true)
}

/// «Salud» rereads the files of every skill: a change asks for it only when it touches links or while
/// «Salud» is open, and opening «Salud» asks for it.
@MainActor @Test func healthIsRequestedOnlyWhenItCanChange() async {
    let tool = SkillsTool()
    await tool.change("x") {}
    #expect(tool.healthRequests == 0)
    await tool.change("x", health: true) {}
    #expect(tool.healthRequests == 1)
    tool.scope = .health
    await tool.change("x") {}
    #expect(tool.healthRequests == 2)
    tool.scope = .all
    tool.scope = .health
    tool.scopeChanged()
    await tool.waitForHealth()
    #expect(tool.healthRequests == 3)
}
