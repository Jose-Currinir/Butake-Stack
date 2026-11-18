import Foundation

/// `gitRewriteCandidates`: the commits of the branch that are on no remote (oldest first) and why
/// the list stops there.
struct GitRewriteCandidates: Decodable, Sendable {
    struct Commit: Decodable, Sendable, Hashable {
        var hash: String
        var subject: String
        var message: String
        var author: String
        var timestamp: String
        var short: String { String(hash.prefix(7)) }
    }
    var branch: String
    var head: String
    var base: String
    var commits: [Commit]
    /// "upstream", "merge", "root" or "limit".
    var boundary: String
}

/// A row of «Organizar commits»: one commit, or several combined into one.
struct GitOrganizeItem: Identifiable, Equatable, Sendable {
    let id = UUID()
    /// Oldest first.
    var commits: [GitRewriteCandidates.Commit]
    var message: String
    var drop = false

    init(_ commit: GitRewriteCandidates.Commit) {
        commits = [commit]
        message = commit.message
    }

    init(combining commits: [GitRewriteCandidates.Commit]) {
        self.commits = commits
        message = commits.first?.message ?? ""
    }

    var subject: String { message.components(separatedBy: "\n").first ?? "" }
    /// The message is not the one the first commit had (combined commits keep the first one's).
    var renamed: Bool { message != commits.first?.message }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.commits == rhs.commits && lhs.message == rhs.message && lhs.drop == rhs.drop
    }
}

/// The rules of «Organizar commits» without the window: combine, split, remove, reorder and the
/// plan for the engine. The list goes newest first, as Historial shows it.
struct GitOrganizePlan: Equatable, Sendable {
    var items: [GitOrganizeItem]
    let original: [GitOrganizeItem]
    let order: [String: Int]

    init(_ candidates: GitRewriteCandidates) {
        let items = candidates.commits.reversed().map(GitOrganizeItem.init)
        self.items = items
        original = items
        order = Dictionary(uniqueKeysWithValues: candidates.commits.enumerated().map { ($0.element.hash, $0.offset) })
    }

    private func signature(_ list: [GitOrganizeItem]) -> [String] {
        list.map { $0.commits.map(\.hash).joined(separator: "+") + "|\($0.drop)|" + $0.message }
    }
    var changed: Bool { signature(items) != signature(original) }
    var kept: Int { items.filter { !$0.drop }.count }
    var combined: Int { items.filter { $0.commits.count > 1 && !$0.drop }.count }
    var removed: Int { items.filter(\.drop).reduce(0) { $0 + $1.commits.count } }
    var renamed: Int { items.filter { $0.renamed && !$0.drop }.count }
    /// Every kept commit has a message, and at least one commit stays.
    var valid: Bool { kept > 0 && items.allSatisfy { $0.drop || !$0.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }

    /// Joins the rows into one, where the newest of them was; its commits keep their order.
    mutating func combine(_ ids: Set<UUID>) -> UUID? {
        let chosen = items.enumerated().filter { ids.contains($0.element.id) }
        guard chosen.count >= 2, let position = chosen.first?.offset else { return nil }
        let commits = chosen.flatMap(\.element.commits).sorted { (order[$0.hash] ?? 0) < (order[$1.hash] ?? 0) }
        let joined = GitOrganizeItem(combining: commits)
        items.removeAll { ids.contains($0.id) }
        items.insert(joined, at: min(position, items.count))
        return joined.id
    }

    /// Takes combined rows apart again.
    mutating func split(_ ids: Set<UUID>) {
        items = items.flatMap { item in
            ids.contains(item.id) && item.commits.count > 1 ? item.commits.reversed().map(GitOrganizeItem.init) : [item]
        }
    }

    /// Removes the rows, or keeps them again when all of them were removed.
    mutating func toggleDrop(_ ids: Set<UUID>) {
        let all = items.filter { ids.contains($0.id) }.allSatisfy(\.drop)
        for index in items.indices where ids.contains(items[index].id) { items[index].drop = !all }
    }

    /// One place up (newer) or down (older).
    mutating func move(_ id: UUID, by offset: Int) {
        guard let index = items.firstIndex(where: { $0.id == id }), items.indices.contains(index + offset) else { return }
        items.swapAt(index, index + offset)
    }

    mutating func reset() { items = original }

    /// The engine's plan: steps oldest first; a message only when it changed.
    func plan(_ candidates: GitRewriteCandidates) -> GitRewritePlan {
        GitRewritePlan(head: candidates.head, base: candidates.base, steps: items.reversed().map { item in
            GitRewritePlan.Step(hashes: item.commits.map(\.hash), drop: item.drop, message: item.renamed ? item.message : nil)
        })
    }
}
