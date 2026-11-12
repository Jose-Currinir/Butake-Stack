import Foundation
import SwiftUI

/// A folder of sites. Order of `sites` is the order shown.
struct SiteGroup: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var sites: [String]
}

/// What the folder name prompt is for.
enum GroupNaming: Identifiable, Hashable {
    case new(sites: [String])
    case rename(String)
    var id: String { switch self { case .new(let sites): "new:" + sites.joined(separator: ","); case .rename(let id): "rename:" + id } }
}

extension StackStore {
    /// The folder a site is in, if any.
    func group(of site: String) -> SiteGroup? { groups.first { $0.sites.contains(site) } }
    /// Sites not in any folder, in their usual order.
    var ungroupedProjects: [Project] {
        let placed = Set(groups.flatMap(\.sites))
        return projects.filter { !placed.contains($0.id) }
    }
    func projects(in group: SiteGroup) -> [Project] {
        group.sites.compactMap { id in projects.first { $0.id == id } }
    }

    /// Applies the change right away (so the sidebar animates with it) and saves it. Saves are queued:
    /// several quick changes (an import placing many sites) never race, and the last state wins.
    func updateGroups(_ change: (inout [SiteGroup]) -> Void) {
        var next = groups
        change(&next)
        guard next != groups else { return }
        withAnimation(.snappy(duration: 0.28)) { groups = next }
        groupsDirty = true
        guard !groupsSaving else { return }
        groupsSaving = true
        Task {
            while groupsDirty {
                groupsDirty = false
                let snapshot = groups
                guard let object = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) else { break }
                do {
                    let _: [SiteGroup] = try await call(["method": "saveSiteGroups", "groups": object])
                } catch {
                    report(error)
                    if !groupsDirty { groups = (try? await call(["method": "siteGroups"])) ?? groups }
                }
            }
            groupsSaving = false
        }
    }
    /// A new folder, optionally with sites in it; returns its id.
    @discardableResult
    func createGroup(named name: String, with sites: [String] = []) -> String {
        let base = name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }.reduce(into: "") { $0.append($1) }
            .split(separator: "-").joined(separator: "-")
        var id = base.isEmpty ? "carpeta" : String(base.prefix(30))
        var n = 2
        while groups.contains(where: { $0.id == id }) { id = "\(base.prefix(27))-\(n)"; n += 1 }
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        updateGroups { groups in
            for index in groups.indices { groups[index].sites.removeAll { sites.contains($0) } }
            groups.append(SiteGroup(id: id, name: clean.isEmpty ? L("groups.untitled") : String(clean.prefix(60)), sites: sites))
        }
        return id
    }
    func renameGroup(_ id: String, to name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        updateGroups { groups in
            if let index = groups.firstIndex(where: { $0.id == id }) { groups[index].name = String(clean.prefix(60)) }
        }
    }
    /// Removes the folder; its sites go back to the plain list.
    func deleteGroup(_ id: String) {
        updateGroups { $0.removeAll { $0.id == id } }
    }
    /// Moves a site into a folder (nil: out of any folder), at the end or right before another of its sites.
    func move(_ site: String, to group: String?, before other: String? = nil) {
        updateGroups { groups in
            for index in groups.indices { groups[index].sites.removeAll { $0 == site } }
            guard let group, let index = groups.firstIndex(where: { $0.id == group }) else { return }
            if let other, let position = groups[index].sites.firstIndex(of: other) {
                groups[index].sites.insert(site, at: position)
            } else {
                groups[index].sites.append(site)
            }
        }
    }
}
