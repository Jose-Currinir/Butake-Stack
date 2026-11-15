import Foundation

/// A commit as the graph needs it: its hash, its parents and its decorations (`%D`).
struct GitGraphCommit: Hashable, Sendable {
    var hash: String
    var parents: [String]
    var refs: String
    init(hash: String, parents: [String], refs: String = "") { self.hash = hash; self.parents = parents; self.refs = refs }
}

/// A branch, remote branch or tag that points at a commit, from its `%D` decorations.
struct GitCommitReference: Identifiable, Hashable, Sendable {
    enum Kind: Sendable { case head, branch, remote, tag }
    var name: String
    var kind: Kind
    var id: String { "\(kind)-\(name)" }

    static func parse(_ refs: String, localBranches: Set<String>) -> [GitCommitReference] {
        refs.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && $0 != "HEAD" }.map { item in
            if item.hasPrefix("HEAD -> ") { return GitCommitReference(name: String(item.dropFirst(8)), kind: .head) }
            if item.hasPrefix("tag: ") { return GitCommitReference(name: String(item.dropFirst(5)), kind: .tag) }
            if localBranches.contains(item) || !item.contains("/") { return GitCommitReference(name: item, kind: .branch) }
            return GitCommitReference(name: item, kind: .remote)
        }
    }
}

/// A line of the graph leaving a row: from one lane to another, starting at the node or passing by.
struct GitGraphSegment: Equatable, Sendable {
    var from: Int
    var to: Int
    var startsAtNode: Bool
}

/// One row of the graph: the commit's lane, the lanes that arrive from above and those that leave.
struct GitGraphRow: Equatable, Sendable {
    var column: Int
    var incoming: [Int]
    var outgoing: [GitGraphSegment]
    var laneCount: Int
}

/// Lanes of a history in topological order (children first), one row per commit.
struct GitCommitGraph: Sendable {
    var rows: [GitGraphRow] = []
    /// Most lanes open at once.
    var width = 1
    /// Branch each commit belongs to, following first parents down from decorated tips.
    var branchLabels: [String: String] = [:]

    /// `pruneMissingParents`: for filtered histories. A parent that is not in the list never arrives to
    /// close its lane, so every row kept one more lane open: thousands of lanes and seconds of work.
    init(commits: [GitGraphCommit], localBranches: Set<String> = [], pruneMissingParents: Bool = false) {
        branchLabels = Self.branchLabels(commits, localBranches: localBranches)
        let present: Set<String> = pruneMissingParents ? Set(commits.map(\.hash)) : []
        var active: [String] = []
        rows.reserveCapacity(commits.count)
        for original in commits {
            var commit = original
            if pruneMissingParents { commit.parents = commit.parents.filter(present.contains) }
            let incoming = Array(active.indices)
            let column: Int
            if let index = active.firstIndex(of: commit.hash) { column = index } else { column = active.count; active.append(commit.hash) }
            let before = active
            active.remove(at: column)
            for (index, parent) in commit.parents.enumerated() where !active.contains(parent) {
                if index == 0 { active.insert(parent, at: min(column, active.count)) } else { active.append(parent) }
            }
            var outgoing: [GitGraphSegment] = []
            for (index, identity) in before.enumerated() where identity != commit.hash {
                if let destination = active.firstIndex(of: identity) { outgoing.append(GitGraphSegment(from: index, to: destination, startsAtNode: false)) }
            }
            for parent in commit.parents {
                if let destination = active.firstIndex(of: parent) { outgoing.append(GitGraphSegment(from: column, to: destination, startsAtNode: true)) }
            }
            let count = max(before.count, active.count, 1)
            width = max(width, count)
            rows.append(GitGraphRow(column: column, incoming: incoming, outgoing: outgoing, laneCount: count))
        }
    }

    static func branchLabels(_ commits: [GitGraphCommit], localBranches: Set<String>) -> [String: String] {
        var labels: [String: String] = [:]
        for commit in commits {
            if labels[commit.hash] == nil {
                let refs = GitCommitReference.parse(commit.refs, localBranches: localBranches)
                if let ref = refs.first(where: { $0.kind == .head }) ?? refs.first(where: { $0.kind == .branch }) ?? refs.first(where: { $0.kind == .remote }) {
                    labels[commit.hash] = ref.name
                }
            }
            if let label = labels[commit.hash], let first = commit.parents.first, labels[first] == nil { labels[first] = label }
        }
        return labels
    }
}
