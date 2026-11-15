import AppKit
import Foundation

/// A project of several parts (P-39): a folder marked as a project, whose sites are its parts
/// («Web», «App y servidor»), each with its own repository. What changes from a folder is that it
/// has a page, starts its parts together (in order, if asked), groups their Git and gives its
/// parts the vault's apps and the Google Cloud link linked to it. Turning it back into a folder
/// loses nothing: its parts, repositories and link stay saved for when it is a project again.
extension StackStore {
    /// The project of several parts with that id (a plain folder is not one).
    func composite(_ id: String) -> ProjectGroup? { groups.first { $0.id == id && $0.isProject } }
    /// The project of several parts a site is a part of.
    func composite(of site: String) -> ProjectGroup? { groups.first { $0.isProject && $0.sites.contains(site) } }
    var composites: [ProjectGroup] { groups.filter(\.isProject) }

    func openComposite(_ id: String) { route = .composite(id) }

    /// «Convertir en proyecto» (opens its page) and «Volver a carpeta» (nothing is removed).
    func setKind(_ id: String, _ kind: ProjectGroup.Kind) {
        updateGroups { groups in
            if let index = groups.firstIndex(where: { $0.id == id }) { groups[index].kind = kind }
        }
        if kind == .project { openComposite(id) } else if route == .composite(id) { route = .home }
    }

    /// «Iniciar en orden»: each part waits for the one before it to answer.
    func setOrdered(_ id: String, _ ordered: Bool) {
        updateGroups { groups in
            if let index = groups.firstIndex(where: { $0.id == id }) { groups[index].ordered = ordered }
        }
    }

    /// Moves a part one place earlier (-1) or later (+1) in the start order.
    func moveStart(_ site: String, in id: String, by offset: Int) {
        updateGroups { groups in
            guard let index = groups.firstIndex(where: { $0.id == id }),
                  let position = groups[index].sites.firstIndex(of: site) else { return }
            let target = position + offset
            guard groups[index].sites.indices.contains(target) else { return }
            groups[index].sites.swapAt(position, target)
        }
    }

    func addRepository(_ path: String, to id: String) {
        updateGroups { groups in
            if let index = groups.firstIndex(where: { $0.id == id }), !groups[index].repositories.contains(path) {
                groups[index].repositories.append(path)
            }
        }
    }

    /// «Quitar del proyecto»: the folder stays as it is.
    func removeRepository(_ path: String, from id: String) {
        updateGroups { groups in
            if let index = groups.firstIndex(where: { $0.id == id }) { groups[index].repositories.removeAll { $0 == path } }
        }
    }

    /// «Agregar repositorio al proyecto…»: a folder inside a repository; the project keeps its top folder.
    func chooseRepository(for id: String) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = L("git.repo.addPrompt")
        panel.message = L("composite.git.addMessage")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let root = Self.repositoryRoot(of: url.path) else { errorMessage = L("composite.git.notRepository"); return }
        addRepository(root, to: id)
    }

    /// The top folder of the repository that holds `path` (a `.git` folder, or a `.git` file of a
    /// worktree), or nil when it is in none.
    nonisolated static func repositoryRoot(of path: String, files: FileManager = .default) -> String? {
        // Not standardized: that would drop «/private» of a temporary folder and change the path.
        var folder = URL(fileURLWithPath: path)
        while true {
            if files.fileExists(atPath: folder.appendingPathComponent(".git").path) { return folder.path }
            let parent = folder.deletingLastPathComponent()
            if parent.path == folder.path { return nil }
            folder = parent
        }
    }

    // MARK: Starting and stopping

    /// «Iniciar todo»: every part that is off. In order, each one waits until the one before it
    /// answers (or fails, or a minute goes by).
    func startAll(_ group: ProjectGroup) async {
        guard compositeWorking == nil else { return }
        compositeWorking = group.id
        defer { compositeWorking = nil }
        for part in projects(in: group) where !part.isMissing {
            if !part.enabled { await setSite(part, enabled: true) }
            if group.ordered { await waitUntilAnswering(part.id) }
        }
    }

    /// «Detener todo»: the parts that are on, the last to start first.
    func stopAll(_ group: ProjectGroup) async {
        guard compositeWorking == nil else { return }
        compositeWorking = group.id
        defer { compositeWorking = nil }
        for part in projects(in: group).reversed() where part.enabled {
            await setSite(part, enabled: false)
        }
    }

    private func waitUntilAnswering(_ id: String) async {
        let until = Date().addingTimeInterval(60)
        while Date() < until, !Task.isCancelled {
            guard let part = projects.first(where: { $0.id == id }) else { return }
            if [.running, .crashed].contains(sitePhase(part)) || !part.enabled { return }
            try? await Task.sleep(for: .milliseconds(500))
        }
    }
}

/// A part that uses another one: its port (`{port:<id>}`) or its fixed public address
/// (`{public:<id>}`), in its environment or its processes' arguments.
struct PartDependency: Hashable, Identifiable {
    enum Kind: String { case port, `public` }
    let from: String
    let to: String
    let kind: Kind
    var id: String { "\(from)>\(kind.rawValue)>\(to)" }

    /// The dependencies between the given parts, in their order; none to a site outside them.
    static func among(_ parts: [Project]) -> [PartDependency] {
        let ids = Set(parts.map(\.id))
        var found: [PartDependency] = []
        for part in parts {
            let texts = Array((part.env ?? [:]).values) + part.processes.flatMap(\.args)
            for text in texts {
                for match in text.matches(of: /\{(port|public):([a-z0-9-]+)\}/) {
                    let target = String(match.output.2)
                    guard target != part.id, ids.contains(target), let kind = Kind(rawValue: String(match.output.1)) else { continue }
                    let dependency = PartDependency(from: part.id, to: target, kind: kind)
                    if !found.contains(dependency) { found.append(dependency) }
                }
            }
        }
        return found
    }
}
