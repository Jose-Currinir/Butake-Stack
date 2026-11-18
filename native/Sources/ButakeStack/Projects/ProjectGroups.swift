import Foundation
import SwiftUI

/// A folder of sites. Order of `sites` is the order shown.
///
/// A folder may be a project of several parts (`kind == .project`): its sites are its parts (in
/// the order they start when `ordered`), plus repositories that are not a site and the Google
/// Cloud link its parts inherit. What the engine keeps in `groups.json`; the new fields are
/// written only when they say something, so a folder is saved as before.
struct ProjectGroup: Codable, Identifiable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable { case folder, project }

    var id: String
    var name: String
    var sites: [String]
    var kind: Kind = .folder
    /// Top folders of repositories added by hand to the project (a library, infrastructure).
    var repositories: [String] = []
    /// Its parts start one after another, in the order of `sites`.
    var ordered = false
    var gcp: GCPLink?
    /// The folder of the disk it is, relative to the projects folder (`Apps/Salud`), and the folder
    /// it is in. Only while the sidebar follows the disk: the engine draws the tree from the disk.
    var path: String?
    var parent: String?

    var isProject: Bool { kind == .project }

    init(id: String, name: String, sites: [String], kind: Kind = .folder, repositories: [String] = [], ordered: Bool = false, gcp: GCPLink? = nil,
         path: String? = nil, parent: String? = nil) {
        self.id = id
        self.name = name
        self.sites = sites
        self.kind = kind
        self.repositories = repositories
        self.ordered = ordered
        self.gcp = gcp
        self.path = path
        self.parent = parent
    }

    private enum CodingKeys: String, CodingKey { case id, name, sites, kind, repositories, ordered, gcp, path, parent }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        sites = try values.decodeIfPresent([String].self, forKey: .sites) ?? []
        // A kind this version does not know is a folder, like a missing one.
        kind = (try? values.decodeIfPresent(String.self, forKey: .kind)).flatMap { $0.flatMap(Kind.init(rawValue:)) } ?? .folder
        repositories = try values.decodeIfPresent([String].self, forKey: .repositories) ?? []
        ordered = try values.decodeIfPresent(Bool.self, forKey: .ordered) ?? false
        gcp = try values.decodeIfPresent(GCPLink.self, forKey: .gcp)
        path = try values.decodeIfPresent(String.self, forKey: .path)
        parent = try values.decodeIfPresent(String.self, forKey: .parent)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(name, forKey: .name)
        try values.encode(sites, forKey: .sites)
        if isProject { try values.encode(kind, forKey: .kind) }
        if !repositories.isEmpty { try values.encode(repositories, forKey: .repositories) }
        if ordered { try values.encode(ordered, forKey: .ordered) }
        try values.encodeIfPresent(gcp, forKey: .gcp)
        try values.encodeIfPresent(path, forKey: .path)
        try values.encodeIfPresent(parent, forKey: .parent)
    }
}

/// What the folder name prompt is for.
enum GroupNaming: Identifiable, Hashable {
    case new(sites: [String])
    case rename(String)
    var id: String { switch self { case .new(let sites): "new:" + sites.joined(separator: ","); case .rename(let id): "rename:" + id } }
}

extension StackStore {
    /// The folder a site is in, if any.
    func group(of site: String) -> ProjectGroup? { groups.first { $0.sites.contains(site) } }
    /// Sites not in any folder, in their usual order.
    var ungroupedProjects: [Project] {
        let placed = Set(groups.flatMap(\.sites))
        return projects.filter { !placed.contains($0.id) }
    }
    func projects(in group: ProjectGroup) -> [Project] {
        group.sites.compactMap { id in projects.first { $0.id == id } }
    }

    /// Applies the change right away (so the sidebar animates with it) and saves it. Saves are queued:
    /// several quick changes (an import placing many sites) never race, and the last state wins.
    func updateGroups(_ change: (inout [ProjectGroup]) -> Void) {
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
                    let _: [ProjectGroup] = try await call(["method": "saveSiteGroups", "groups": object])
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
        if followsDisk { createFolderOnDisk(named: name, with: sites); return "" }
        let base = name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }.reduce(into: "") { $0.append($1) }
            .split(separator: "-").joined(separator: "-")
        var id = base.isEmpty ? "carpeta" : String(base.prefix(30))
        var n = 2
        while groups.contains(where: { $0.id == id }) { id = "\(base.prefix(27))-\(n)"; n += 1 }
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        updateGroups { groups in
            for index in groups.indices { groups[index].sites.removeAll { sites.contains($0) } }
            groups.append(ProjectGroup(id: id, name: clean.isEmpty ? L("groups.untitled") : String(clean.prefix(60)), sites: sites))
        }
        return id
    }
    func renameGroup(_ id: String, to name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        if followsDisk { renameFolderOnDisk(id, to: clean); return }
        updateGroups { groups in
            if let index = groups.firstIndex(where: { $0.id == id }) { groups[index].name = String(clean.prefix(60)) }
        }
    }
    /// Removes the folder; its sites go back to the plain list.
    func deleteGroup(_ id: String) {
        if followsDisk { removeFolderOnDisk(id); return }
        updateGroups { $0.removeAll { $0.id == id } }
    }
    /// Moves a site into a folder (nil: out of any folder), at the end or right before another of its sites.
    func move(_ site: String, to group: String?, before other: String? = nil) {
        // On the disk a move is a move of the folder: confirmed, and it can be undone.
        if followsDisk { requestDiskMove(site, into: group); return }
        guard !site.hasPrefix(Self.folderDragPrefix) else { return }
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
