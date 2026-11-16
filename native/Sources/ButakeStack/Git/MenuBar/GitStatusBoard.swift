import Foundation
import SwiftUI

/// What the menu bar says of the repositories without opening the window: the ones with changes,
/// commits to bring or to send, or something to fix, with «Bajar», «Subir» and «Abrir». Optionally
/// it looks for new commits every 5 minutes (off unless the user turns it on).
@MainActor @Observable final class GitStatusBoard {
    static let shared = GitStatusBoard()

    /// «Buscar cambios cada 5 minutos»: off by default; a preference of this Mac.
    var autoFetch: Bool = UserDefaults.standard.bool(forKey: GitStatusBoard.autoFetchKey) {
        didSet { if !StackStore.qaWindow { UserDefaults.standard.set(autoFetch, forKey: Self.autoFetchKey) } }
    }
    static let autoFetchKey = "git.autoFetch"
    static let interval: Duration = .seconds(300)

    /// The repository being brought down or sent, for its row's progress.
    private(set) var working: String?
    /// The last failure of a row, in plain words, until the next try.
    private(set) var failures: [String: GitFailure] = [:]
    private(set) var refreshing = false
    private(set) var lastFetch: Date?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var store: StackStore { .shared }
    @ObservationIgnored private var tool: GitTool { .shared }

    /// Rows that need something, in the order of the repository picker.
    var rows: [GitStatusRow] {
        // A folder listed twice (a project and the same repository added by hand) shows once.
        var seen = Set<String>()
        return tool.entries.filter { !$0.missing && seen.insert($0.path).inserted }.compactMap { entry in
            guard let summary = tool.summary(of: entry) else { return nil }
            let row = GitStatusRow(entry: entry, summary: summary)
            return row.needsAttention || failures[entry.path] != nil ? row : nil
        }
    }

    /// The rows of each project of several parts under its name (in the order of the projects),
    /// then the others without a title.
    func grouped(_ rows: [GitStatusRow]) -> [(id: String, title: String?, rows: [GitStatusRow])] {
        var left = rows
        var out: [(id: String, title: String?, rows: [GitStatusRow])] = []
        for group in store.composites {
            let mine = left.filter { tool.composite(of: $0.entry)?.id == group.id }
            guard !mine.isEmpty else { continue }
            left.removeAll { row in mine.contains { $0.id == row.id } }
            out.append((group.id, group.name, mine))
        }
        if !left.isEmpty { out.append((":rest", out.isEmpty ? nil : L("git.repo.other"), left)) }
        return out
    }

    /// Reads the list and every repository's state again (no network).
    func refresh() async {
        guard store.pluginEnabled("git"), !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        await tool.loadList()
        await tool.loadSummaries()
        await store.refreshGit()
    }

    /// The 5-minute loop, started once with the app; each turn does nothing unless the tool is on
    /// and the user asked for it.
    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.interval)
                guard let self, !Task.isCancelled else { return }
                if self.autoFetch && self.store.pluginEnabled("git") { await self.fetchAll() }
            }
        }
    }

    /// Asks each repository's remote for new commits; changes nothing in the folders.
    func fetchAll() async {
        await tool.loadList()
        for entry in tool.entries where !entry.missing && working == nil {
            let request = await GitHosting.shared.transfer(["method": "gitAction", "path": entry.path, "action": GitAction.fetch.rawValue, "value": ""],
                                                           path: entry.path, store: store)
            let _: String? = try? await store.call(request)
        }
        lastFetch = Date()
        await refresh()
    }

    /// «Bajar» or «Subir» of a row: on the open repository when it is that one (its progress and
    /// assistant), else on its own; a failure stays on the row, and «Abrir» leads to the tool.
    func transfer(_ action: GitAction, _ entry: GitRepositoryEntry) async {
        guard working == nil, action == .pull || action == .push else { return }
        working = entry.path
        failures[entry.path] = nil
        defer { working = nil }
        if let open = tool.repository, open.root == entry.path {
            _ = await open.perform(action)
            if let failure = open.pullProblem ?? open.failure { failures[entry.path] = failure }
        } else {
            do {
                let snapshot: GitSnapshot = try await store.call(["method": "gitSnapshot", "path": entry.path, "limit": 1])
                let repository = GitRepository(snapshot: snapshot, store: store)
                if !(await repository.perform(action)), let failure = repository.pullProblem ?? repository.failure {
                    failures[entry.path] = failure
                }
            } catch {
                failures[entry.path] = GitFailure(error)
            }
        }
        await refresh()
    }
}

/// A repository as the menu bar lists it.
struct GitStatusRow: Identifiable, Hashable {
    let entry: GitRepositoryEntry
    let summary: GitRepositorySummary
    var id: String { entry.id }

    var needsAttention: Bool {
        summary.changes > 0 || summary.ahead > 0 || summary.behind > 0 || summary.problems > 0 || summary.unfinished
    }
    /// «Subir» is not offered on the main branch from here: the tool asks first there.
    var canPush: Bool { summary.ahead > 0 && summary.behind == 0 && !summary.unfinished && !["main", "master", ""].contains(summary.branch) }
    var canPull: Bool { summary.behind > 0 && !summary.unfinished }

    /// The tooltip: the same in words («por bajar: 2 · por subir: 1»).
    var spokenDetail: String {
        var parts = [summary.branch.isEmpty ? L("git.detached") : summary.branch]
        if summary.changes > 0 { parts.append(String(format: L("git.changesCount"), summary.changes)) }
        if summary.behind > 0 { parts.append(String(format: L("git.statusBoard.behind"), summary.behind)) }
        if summary.ahead > 0 { parts.append(String(format: L("git.statusBoard.ahead"), summary.ahead)) }
        if summary.problems > 0 { parts.append(String(format: L("git.problems.count"), summary.problems)) }
        return parts.joined(separator: " · ")
    }

    /// «develop · 3 archivos con cambios · ↓2 ↑1».
    var detail: String {
        var parts = [summary.branch.isEmpty ? L("git.detached") : summary.branch]
        if summary.changes > 0 { parts.append(String(format: L("git.changesCount"), summary.changes)) }
        // ↓ and ↑ as in the repository picker: the panel is narrow (its tooltip says it in words).
        let arrows = [summary.behind > 0 ? String(format: L("git.repo.behind"), summary.behind) : nil,
                      summary.ahead > 0 ? String(format: L("git.repo.ahead"), summary.ahead) : nil].compactMap { $0 }
        if !arrows.isEmpty { parts.append(arrows.joined(separator: " ")) }
        if summary.problems > 0 { parts.append(String(format: L("git.problems.count"), summary.problems)) }
        else if summary.unfinished { parts.append(L("git.repo.unfinished")) }
        return parts.joined(separator: " · ")
    }
}
