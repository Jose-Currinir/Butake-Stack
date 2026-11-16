import AppKit
import Foundation
import SwiftUI

/// The sheets of the Skills tool, all presented by the detail (`SkillsSheets`).
enum SkillsSheet: Identifiable {
    case newSkill, groups, move(String), rename(String), agent(String?), links(SkillLinkRequest)

    var id: String {
        switch self {
        case .newSkill: "new"
        case .groups: "groups"
        case .move(let id): "move.\(id)"
        case .rename(let id): "rename.\(id)"
        case .agent(let id): "agent.\(id ?? "")"
        case .links(let request): "links.\(request.id)"
        }
    }
}

/// The Skills tool's state, shared by its list (content column) and its page (detail). Only the
/// engine writes to disk; the app asks, shows the plan of every change to an assistant's folder
/// and applies it once confirmed.
@MainActor @Observable final class SkillsTool {
    static let shared = SkillsTool()

    var state: SkillsState?
    var problems: [SkillProblem] = []
    var loaded = false
    var loadFailed = false
    var scope: SkillsScope = .all
    var selection: String?
    var search = ""
    var tagFilter: String?
    var agentFilter: String?
    var sheet: SkillsSheet?
    /// The skill just deleted, while «Deshacer» is on offer.
    var deleted: DeletedSkill?

    private var store: StackStore { .shared }

    var skills: [Skill] { state?.skills ?? [] }
    var groups: [SkillGroup] { state?.groups ?? [] }
    var agents: [SkillAgent] { state?.agents ?? [] }
    var tags: [String] { state?.tags ?? [] }
    var selected: Skill? { skills.first { $0.id == selection } }
    func skill(_ id: String) -> Skill? { skills.first { $0.id == id } }
    func agent(_ id: String) -> SkillAgent? { agents.first { $0.id == id } }
    func group(_ id: String) -> SkillGroup? { groups.first { $0.id == id } }
    func groupName(_ id: String) -> String { group(id)?.name ?? id }
    func count(in group: String) -> Int { skills.filter { $0.group == group }.count }
    var filtering: Bool { tagFilter != nil || agentFilter != nil }

    /// The skills the content column shows: the scope's, then the filters and the search.
    var visible: [Skill] {
        skills.filter { skill in
            switch scope {
            case .all: true
            case .group(let id): skill.group == id
            // «Salud» is shown in the detail; the list keeps every skill.
            case .health: true
            }
        }
        .filter { skill in tagFilter.map { skill.tags.contains($0) } ?? true }
        .filter { skill in agentFilter.map { skill.agents.contains($0) } ?? true }
        .filter { $0.matches(search) }
    }

    /// The skill on screen stays only while the list still shows it; «Salud» starts without one.
    func scopeChanged() {
        if scope == .health { selection = nil } else { keepSelectionVisible() }
    }

    /// Opens a skill's page (from a finding of «Salud»).
    func select(_ id: String) {
        if scope == .health { scope = .all }
        selection = id
        if !visible.contains(where: { $0.id == id }) { search = ""; tagFilter = nil; agentFilter = nil }
    }

    func keepSelectionVisible() {
        if let selection, !visible.contains(where: { $0.id == selection }) { self.selection = nil }
    }

    func load() async {
        do {
            apply(try await store.call(["method": "skillsList"]))
            loadFailed = false
        } catch {
            loadFailed = state == nil
            store.report(error)
        }
        await loadProblems()
        loaded = true
    }

    func loadProblems() async {
        if let list: [SkillProblem] = try? await store.call(["method": "skillsHealth"]) { problems = list }
    }

    private func apply(_ state: SkillsState) {
        self.state = state
        if let selection, skill(selection) == nil { self.selection = nil }
        if case .group(let id) = scope, group(id) == nil { scope = .all }
        if let tag = tagFilter, !state.tags.contains(tag) { tagFilter = nil }
        if let agent = agentFilter, self.agent(agent) == nil { agentFilter = nil }
    }

    /// Asks the engine, reads the list again and says what was done. False when it failed (the
    /// engine's message is already shown).
    @discardableResult private func change(_ label: String, done: String? = nil, _ work: @escaping @MainActor () async throws -> Void) async -> Bool {
        var ok = false
        await store.run(label) {
            try await work()
            ok = true
        }
        guard ok else { return false }
        if let state: SkillsState = try? await store.call(["method": "skillsList"]) { apply(state) }
        await loadProblems()
        if let done { store.notify(done) }
        return true
    }

    // MARK: Text

    func read(_ id: String) async -> String? {
        struct Text: Decodable { let text: String }
        do {
            let value: Text = try await store.call(["method": "skillsRead", "id": id])
            return value.text
        } catch {
            store.report(error)
            return nil
        }
    }

    func save(_ id: String, text: String) async -> Bool {
        await change(L("skills.saving"), done: L("skills.saved")) {
            let _: Skill = try await self.store.call(["method": "skillsSave", "id": id, "text": text])
        }
    }

    // MARK: Skills

    func create(id: String, group: String, template: SkillTemplate, name: String, description: String) async -> Bool {
        let made = await change(L("skills.creating"), done: L("skills.created")) {
            let _: Skill = try await self.store.call(["method": "skillsCreate", "id": id, "group": group, "template": template.rawValue,
                                                      "name": name, "description": description])
        }
        if made { selection = id; scope = scopeShowing(group) }
        return made
    }

    /// Stays in the group on screen unless the new skill lives elsewhere.
    private func scopeShowing(_ group: String) -> SkillsScope {
        if case .group = scope { return .group(group) }
        return scope == .health ? .all : scope
    }

    func update(_ skill: Skill, group: String? = nil, tags: [String]? = nil) async {
        var request: [String: Any] = ["method": "skillsUpdate", "id": skill.id]
        if let group { request["group"] = group }
        if let tags { request["tags"] = tags }
        await change(L("skills.updating")) { let _: Skill = try await self.store.call(request) }
    }

    func duplicate(_ skill: Skill) async {
        let copy = SkillIDs.unique("\(skill.id.prefix(56))-\(L("skills.copySuffix"))", taken: Set(skills.map(\.id)))
        if await change(L("skills.duplicating"), done: L("skills.duplicated"), {
            let _: Skill = try await self.store.call(["method": "skillsDuplicate", "id": skill.id, "newId": copy])
        }) { selection = copy }
    }

    private func rename(_ skill: Skill, to newId: String) async -> Bool {
        let renamed = await change(L("skills.renaming"), done: L("skills.renamed")) {
            let _: Skill = try await self.store.call(["method": "skillsRename", "id": skill.id, "newId": newId, "confirmed": true])
        }
        if renamed { selection = newId }
        return renamed
    }

    private func delete(_ skill: Skill) async -> Bool {
        struct Trashed: Decodable { let trashId: String }
        var trashed: Trashed?
        await change(L("skills.deleting")) {
            trashed = try await self.store.call(["method": "skillsDelete", "id": skill.id, "confirmed": true])
        }
        guard let trashed else { return false }
        deleted = DeletedSkill(id: skill.id, name: skill.name, trashId: trashed.trashId)
        return true
    }

    private func restore(trashId: String) async -> Bool {
        let restored = await change(L("skills.restoring"), done: L("skills.restored")) {
            let back: Skill = try await self.store.call(["method": "skillsRestore", "trashId": trashId, "confirmed": true])
            self.selection = back.id
        }
        if restored { deleted = nil }
        return restored
    }

    /// Opens the confirmation of deleting a skill: the links it removes.
    func requestDelete(_ skill: Skill) { requestLinks(SkillLinkRequest(skill: skill.id, operation: .delete, subject: skill.name)) }

    /// Opens the confirmation of «Deshacer»: the links it recreates.
    func requestUndoDelete() {
        guard let deleted else { return }
        requestLinks(SkillLinkRequest(skill: deleted.id, operation: .restore(trashId: deleted.trashId), subject: deleted.name))
    }

    func requestRename(_ skill: Skill, to newId: String) {
        requestLinks(SkillLinkRequest(skill: skill.id, operation: .rename(to: newId), subject: skill.name))
    }

    func requestRemoveAgent(_ agent: SkillAgent) {
        requestLinks(SkillLinkRequest(skill: "", operation: .removeAgent(id: agent.id), subject: agent.name))
    }

    // MARK: Groups and assistants

    func saveGroups(_ groups: [SkillGroup], deleting removed: [(id: String, moveTo: String)]) async -> Bool {
        await change(L("skills.groups.saving"), done: L("skills.groups.saved")) {
            // A group only goes after its skills moved: the new list goes first, deletions after it.
            let kept = Set(groups.map(\.id))
            let current = Set(self.groups.map(\.id))
            let adding = groups.filter { !current.contains($0.id) }
            if !adding.isEmpty {
                let merged = (self.groups + adding)
                let _: [SkillGroup] = try await self.store.call(["method": "skillsGroupSave", "groups": Self.json(merged)])
            }
            for (id, moveTo) in removed where current.contains(id) && !kept.contains(id) {
                let _: [SkillGroup] = try await self.store.call(["method": "skillsGroupDelete", "id": id, "moveTo": moveTo])
            }
            let ordered = groups.enumerated().map { SkillGroup(id: $1.id, name: $1.name, order: $0) }
            let _: [SkillGroup] = try await self.store.call(["method": "skillsGroupSave", "groups": Self.json(ordered)])
        }
    }

    private static func json(_ groups: [SkillGroup]) -> [[String: Any]] {
        groups.map { ["id": $0.id, "name": $0.name, "order": $0.order] }
    }

    func saveAgent(id: String, name: String, folder: String) async -> Bool {
        await change(L("skills.agent.saving"), done: L("skills.agent.saved")) {
            let _: [SkillAgent] = try await self.store.call(["method": "skillsAgentSave", "id": id, "name": name, "folder": folder])
        }
    }

    private func removeAgent(id: String) async -> Bool {
        await change(L("skills.agent.removing"), done: L("skills.agent.removed")) {
            let _: [SkillAgent] = try await self.store.call(["method": "skillsAgentRemove", "id": id, "confirmed": true])
        }
    }

    // MARK: Links

    /// Opens the confirmation of a change to the assistants' folders; nothing changes before it.
    func requestLinks(_ request: SkillLinkRequest) { sheet = .links(request) }

    func plan(_ request: SkillLinkRequest) async -> SkillLinkPlan? {
        let payload = request.operation == .links ? request.payload(method: "skillsLinkPlan") : request.operationPayload(confirmed: false)
        do { return try await store.call(payload) } catch {
            store.report(error)
            return nil
        }
    }

    /// Applies the confirmed request; false when it failed (the engine's message is already shown).
    func apply(_ request: SkillLinkRequest) async -> Bool {
        switch request.operation {
        case .links: await applyLinks(request) != nil
        case .rename(let newId):
            if let skill = skill(request.skill) { await rename(skill, to: newId) } else { false }
        case .delete:
            if let skill = skill(request.skill) { await delete(skill) } else { false }
        case .restore(let trashId): await restore(trashId: trashId)
        case .removeAgent(let id): await removeAgent(id: id)
        }
    }

    private func applyLinks(_ request: SkillLinkRequest) async -> SkillLinkResult? {
        var result: SkillLinkResult?
        await change(L("skills.links.applying")) {
            result = try await self.store.call(request.payload(method: "skillsLinkApply", confirmed: true))
        }
        if let result { store.notify(result.conflicts.isEmpty ? L("skills.links.applied") : L("skills.links.appliedWithConflicts")) }
        return result
    }

    // MARK: Export

    func exportText(_ skill: Skill) async -> String? {
        struct Exported: Decodable { let text: String }
        do {
            let value: Exported = try await store.call(["method": "skillsExport", "id": skill.id, "format": "markdown"])
            return value.text
        } catch {
            store.report(error)
            return nil
        }
    }

    func copyExport(_ skill: Skill) async {
        guard let text = await exportText(skill) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        store.notify(L("skills.export.copied"))
    }

    func saveExport(_ skill: Skill) async {
        guard let text = await exportText(skill) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(skill.id).md"
        panel.allowedContentTypes = [.init(filenameExtension: "md") ?? .plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            store.notify(L("skills.export.saved"))
        } catch {
            store.report(error)
        }
    }
}
