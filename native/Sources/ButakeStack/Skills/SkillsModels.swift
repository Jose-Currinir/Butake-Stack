import Foundation

/// A group of skills (a folder of the list; the skills themselves are flat on disk).
struct SkillGroup: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var order: Int
}

/// A skill as `skillsList` gives it. Its text (`SKILL.md`) only travels with `skillsRead`.
struct Skill: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let description: String
    let group: String
    let tags: [String]
    let enabled: Bool
    let agents: [String]
    let files: [String]
    /// Seconds since 1970 of the last change to `SKILL.md`.
    let modified: Int

    var modifiedDate: Date { Date(timeIntervalSince1970: TimeInterval(modified)) }

    func matches(_ text: String) -> Bool {
        text.isEmpty || [name, id, description].contains { $0.localizedCaseInsensitiveContains(text) }
            || tags.contains { $0.localizedCaseInsensitiveContains(text) }
    }
}

/// An AI assistant skills can be linked to: its folder (`mode` "link") or only exported (ChatGPT, Kiro).
struct SkillAgent: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let folder: String?
    let mode: String
    let builtin: Bool
    let exists: Bool

    var linksFolder: Bool { mode == "link" }
}

/// `skillsList`.
struct SkillsState: Decodable, Sendable {
    let groups: [SkillGroup]
    let skills: [Skill]
    let agents: [SkillAgent]
    let tags: [String]
}

/// One finding of `skillsHealth`.
struct SkillProblem: Decodable, Identifiable, Hashable, Sendable {
    enum Kind: String, Decodable, CaseIterable, Sendable {
        case noDescription = "no_description", brokenLink = "broken_link", duplicateName = "duplicate_name"
        case unused, conflict, missingFolder = "missing_folder"
        /// Links left in the former folder of a built-in assistant (`agent`, `path` = that folder).
        case movedFolder = "moved_folder"
    }
    let kind: Kind
    let skill: String?
    let agent: String?
    let path: String?

    var id: String { [kind.rawValue, skill ?? "", agent ?? "", path ?? ""].joined(separator: "|") }
}

/// A link to make (`on`) or remove between a skill and an assistant.
struct SkillLinkChange: Hashable, Sendable {
    let skill: String
    let agent: String
    let on: Bool
}

/// What `skillsLinkPlan` would do, and what applying it asks for: either changes of links, or
/// turning a whole skill on or off.
struct SkillLinkRequest: Identifiable, Hashable, Sendable {
    /// What the confirmation is for. Every one is planned by the engine (`plan: true`, same answer
    /// as `skillsLinkPlan`) and applied with `confirmed`.
    enum Operation: Hashable, Sendable {
        case links
        case rename(to: String)
        case delete
        /// The trash id of the skill to bring back.
        case restore(trashId: String)
        /// The id of the assistant to remove.
        case removeAgent(id: String)
        /// Moves the links of a built-in assistant from its former folder to the current one
        /// (`skillsLinkPlan` / `skillsLinkApply` with `migrate`).
        case migrate(agent: String)
    }

    let id = UUID()
    let skill: String
    var changes: [SkillLinkChange] = []
    /// Set when the whole skill is activated or deactivated.
    var enabled: Bool?
    var operation: Operation = .links
    /// What the sheet names when it is not a skill on screen (a deleted skill, an assistant).
    var subject: String?

    /// Rename, delete, restore and removing an assistant always do something, even with no links.
    var alwaysActs: Bool {
        switch operation {
        case .links, .migrate: false
        default: true
        }
    }

    /// The request of the operation's own method: its plan, or its apply once confirmed.
    func operationPayload(confirmed: Bool) -> [String: Any] {
        var request: [String: Any] = confirmed ? ["confirmed": true] : ["plan": true]
        switch operation {
        case .links: break
        case .migrate(let agent): request["method"] = confirmed ? "skillsLinkApply" : "skillsLinkPlan"; request["migrate"] = agent
        case .rename(let newId): request["method"] = "skillsRename"; request["id"] = skill; request["newId"] = newId
        case .delete: request["method"] = "skillsDelete"; request["id"] = skill
        case .restore(let trashId): request["method"] = "skillsRestore"; request["trashId"] = trashId
        case .removeAgent(let agent): request["method"] = "skillsAgentRemove"; request["id"] = agent
        }
        return request
    }

    func payload(method: String, confirmed: Bool = false) -> [String: Any] {
        var request: [String: Any] = ["method": method]
        if let enabled {
            request["skill"] = skill
            request["enabled"] = enabled
        } else {
            request["changes"] = changes.map { ["skill": $0.skill, "agent": $0.agent, "on": $0.on] as [String: Any] }
        }
        if confirmed { request["confirmed"] = true }
        return request
    }
}

/// `skillsLinkPlan`.
struct SkillLinkPlan: Decodable, Sendable {
    struct Conflict: Decodable, Hashable, Sendable { let path: String; let reason: String }
    let create: [String]
    let remove: [String]
    let conflicts: [Conflict]
    var isEmpty: Bool { create.isEmpty && remove.isEmpty && conflicts.isEmpty }
}

/// `skillsLinkApply`.
struct SkillLinkResult: Decodable, Sendable {
    let created: [String]
    let removed: [String]
    let conflicts: [SkillLinkPlan.Conflict]
}

/// `skillsRename` applied: the renamed skill and the names already taken in an AI folder (skipped, untouched).
struct SkillRenameResult: Decodable, Sendable {
    let skill: Skill
    let conflicts: [SkillLinkPlan.Conflict]
}

/// The starting texts of a new skill (the engine knows them by these names).
enum SkillTemplate: String, CaseIterable, Identifiable, Sendable {
    case blank, commits, publishApp = "publish-app"
    var id: String { rawValue }
    var title: String { L("skills.template.\(rawValue)") }
    var detail: String { L("skills.template.\(rawValue).detail") }
}

/// What the content column shows: every skill, one group, or the problems.
enum SkillsScope: Hashable, Sendable {
    case all, group(String), health
}

/// A skill just deleted, which «Deshacer» brings back.
struct DeletedSkill: Equatable, Sendable {
    let id: String
    let name: String
    let trashId: String
}

enum SkillIDs {
    /// An id for a name: lowercase letters and digits joined by dashes, at most 64 characters.
    static func slug(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).lowercased()
        var out = ""
        for scalar in folded.unicodeScalars {
            if scalar.isASCII, CharacterSet.alphanumerics.contains(scalar) { out.unicodeScalars.append(scalar) } else if !out.hasSuffix("-") { out += "-" }
        }
        return String(out.trimmingCharacters(in: CharacterSet(charactersIn: "-")).prefix(64)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    /// The engine's rule for skill and group ids: `[a-z0-9-]`, 1 to 64, no dash at either end.
    static func isValid(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64 && !id.hasPrefix("-") && !id.hasSuffix("-")
            && id.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-") }
    }

    /// The first id built from `base` that `taken` does not hold.
    static func unique(_ base: String, taken: Set<String>) -> String {
        guard taken.contains(base) else { return base }
        var number = 2
        while taken.contains("\(base.prefix(60))-\(number)") { number += 1 }
        return "\(base.prefix(60))-\(number)"
    }
}
