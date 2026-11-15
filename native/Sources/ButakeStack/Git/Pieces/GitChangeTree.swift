import Foundation

/// A folder or a file of the change tree. Folders with a single subfolder and no files of their own
/// are joined into one row ("app/Http/Controllers").
struct GitChangeNode: Identifiable, Hashable, Sendable {
    /// The file's path, or the folder's path with a trailing "/".
    var id: String
    var name: String
    var change: GitChange?
    var children: [GitChangeNode]?
    /// Every file under the node (the node itself for a file).
    var changes: [GitChange]
    var additions = 0
    var deletions = 0
    var isFolder: Bool { change == nil }
}

/// The change tree: building it from paths, flattening it into rows and the state of each checkbox.
enum GitChangeTree {
    /// A visible row: the node and how deep it sits.
    struct Row: Identifiable, Hashable, Sendable {
        let node: GitChangeNode
        let depth: Int
        var id: String { node.id }
    }

    /// Folders first, then files, each sorted by name ignoring case. Built off the main thread by the
    /// caller when there are thousands of files.
    static func build(_ changes: [GitChange]) -> [GitChangeNode] {
        final class Box { var dirs: [String: Box] = [:]; var files: [GitChange] = [] }
        let root = Box()
        for change in changes {
            var node = root
            for part in change.path.split(separator: "/").dropLast() {
                let key = String(part)
                if let next = node.dirs[key] { node = next } else { let next = Box(); node.dirs[key] = next; node = next }
            }
            node.files.append(change)
        }
        func build(_ box: Box, prefix: String) -> [GitChangeNode] {
            var result: [GitChangeNode] = []
            // Precomputed lowercase keys: a localized comparison inside the sort took ~300 ms with 3 000 files.
            for (_, name, child) in box.dirs.map({ ($0.key.lowercased(), $0.key, $0.value) }).sorted(by: { $0.0 < $1.0 }) {
                var label = name, path = prefix + name, current = child
                while current.files.isEmpty, current.dirs.count == 1, let (next, box) = current.dirs.first {
                    label += "/" + next; path += "/" + next; current = box
                }
                let children = build(current, prefix: path + "/")
                result.append(GitChangeNode(id: path + "/", name: label, change: nil, children: children, changes: children.flatMap(\.changes),
                                            additions: children.reduce(0) { $0 + $1.additions }, deletions: children.reduce(0) { $0 + $1.deletions }))
            }
            for (_, change) in box.files.map({ ($0.name.lowercased(), $0) }).sorted(by: { $0.0 < $1.0 }) {
                result.append(GitChangeNode(id: change.path, name: change.name, change: change, children: nil, changes: [change],
                                            additions: change.stats.additions ?? 0, deletions: change.stats.deletions ?? 0))
            }
            return result
        }
        return build(root, prefix: "")
    }

    /// The rows on screen: every node whose folders are open.
    static func flatten(_ nodes: [GitChangeNode], collapsed: Set<String>, depth: Int = 0) -> [Row] {
        var result: [Row] = []
        func walk(_ nodes: [GitChangeNode], depth: Int) {
            for node in nodes {
                result.append(Row(node: node, depth: depth))
                if let children = node.children, !collapsed.contains(node.id) { walk(children, depth: depth + 1) }
            }
        }
        walk(nodes, depth: depth)
        return result
    }

    /// Ids of every folder (for «Plegar todas»).
    static func folderIDs(_ nodes: [GitChangeNode]) -> Set<String> {
        var ids: Set<String> = []
        func walk(_ nodes: [GitChangeNode]) { for node in nodes where node.isFolder { ids.insert(node.id); walk(node.children ?? []) } }
        walk(nodes)
        return ids
    }

    /// Whole in the commit, partly or not at all. Conflicts do not count: they are resolved, not chosen.
    static func inclusion(of changes: [GitChange], pending: [String: Bool] = [:]) -> GitInclusion {
        var all = true, any = false, counted = false
        for change in changes where !change.isConflict {
            counted = true
            let state: GitInclusion = pending[change.path].map { $0 ? .full : .none } ?? change.inclusion
            if state != .full { all = false }
            if state != .none { any = true }
            if !all && any { return .partial }
        }
        guard counted else { return .none }
        return all ? .full : any ? .partial : .none
    }
}
