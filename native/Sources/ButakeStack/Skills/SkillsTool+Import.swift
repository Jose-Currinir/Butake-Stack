import Foundation

/// The import of existing skills: scan, plan, apply, and the import trash. Every change is planned
/// by the engine first; the sheets show the exact paths and apply only once confirmed.
extension SkillsTool {
    func scanImport() async -> [ImportCandidate]? {
        do { return try await StackStore.shared.call(["method": "skillsImportScan"]) } catch {
            StackStore.shared.report(error)
            return nil
        }
    }

    private func importPayload(_ method: String, ids: [String], group: String, choices: [String: String]) -> [String: Any] {
        ["method": method, "ids": ids, "group": group,
         "choices": choices.map { ["id": $0.key, "from": $0.value] as [String: Any] }]
    }

    func planImport(ids: [String], group: String, choices: [String: String]) async -> ImportPlan? {
        do { return try await StackStore.shared.call(importPayload("skillsImportPlan", ids: ids, group: group, choices: choices)) } catch {
            StackStore.shared.report(error)
            return nil
        }
    }

    /// Applies the confirmed import; false when it failed (the engine's message is already shown).
    func applyImport(ids: [String], group: String, choices: [String: String]) async -> Bool {
        var request = importPayload("skillsImportApply", ids: ids, group: group, choices: choices)
        request["confirmed"] = true
        var result: ImportResult?
        await change(L("skills.sheet.import.applying")) {
            result = try await StackStore.shared.call(request)
        }
        guard let result else { return false }
        if let first = result.imported.first { selection = first.id }
        StackStore.shared.notify(result.conflicts.isEmpty ? L("skills.sheet.import.done") : L("skills.sheet.import.doneWithConflicts"))
        return true
    }

    // MARK: Import trash

    func importTrash() async -> [ImportTrashEntry] {
        (try? await StackStore.shared.call(["method": "skillsImportTrashList"])) ?? []
    }

    func planUndo(_ entry: ImportTrashEntry) async -> ImportUndoPlan? {
        do { return try await StackStore.shared.call(["method": "skillsImportUndo", "trashId": entry.trashId, "plan": true]) } catch {
            StackStore.shared.report(error)
            return nil
        }
    }

    func applyUndo(_ entry: ImportTrashEntry) async -> Bool {
        var result: ImportUndoResult?
        await change(L("skills.sheet.import.undoing")) {
            result = try await StackStore.shared.call(["method": "skillsImportUndo", "trashId": entry.trashId, "confirmed": true])
        }
        guard let result else { return false }
        StackStore.shared.notify(result.conflicts.isEmpty ? L("skills.sheet.import.undone") : L("skills.sheet.import.undoneWithConflicts"))
        return result.conflicts.isEmpty
    }

    func planEmpty(_ entries: [ImportTrashEntry]) async -> ImportEmptyPlan? {
        do {
            return try await StackStore.shared.call(["method": "skillsImportTrashEmpty", "trashIds": entries.map(\.trashId), "plan": true])
        } catch {
            StackStore.shared.report(error)
            return nil
        }
    }

    func applyEmpty(_ entries: [ImportTrashEntry]) async -> Bool {
        var ok = false
        await change(L("skills.sheet.import.emptying"), done: L("skills.sheet.import.emptied")) {
            let _: ImportEmptyResult = try await StackStore.shared.call(
                ["method": "skillsImportTrashEmpty", "trashIds": entries.map(\.trashId), "confirmed": true])
            ok = true
        }
        return ok
    }
}

/// `skillsImportUndo` applied: where the folders went back, and what was left as it was.
struct ImportUndoResult: Decodable, Sendable {
    let restored: [String]
    let conflicts: [SkillLinkPlan.Conflict]
}

/// `skillsImportTrashEmpty` applied.
struct ImportEmptyResult: Decodable, Sendable {
    let removed: [String]
}
