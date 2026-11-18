import AppKit
import SwiftUI

/// A saved change (`stash list`).
struct GitStash: Identifiable, Hashable {
    /// `stash@{n}`
    var name: String
    var message: String
    var date: Date?
    var id: String { name }

    static func parse(_ output: String) -> [GitStash] {
        output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 3, fields[0].hasPrefix("stash@{") else { return nil }
            // «On develop: mensaje» → «mensaje»: the branch is Git's prefix, not what the user wrote.
            let message = fields[1].replacingOccurrences(of: #"^(WIP on|On) [^:]+: "#, with: "", options: .regularExpression)
            return GitStash(name: fields[0], message: message, date: Double(fields[2]).map(Date.init(timeIntervalSince1970:)))
        }
    }
}

/// A tag (`tag --list`).
struct GitTag: Identifiable, Hashable {
    var name: String
    var commit: String
    var date: Date?
    var id: String { name }

    static func parse(_ output: String) -> [GitTag] {
        output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 3, !fields[0].isEmpty else { return nil }
            return GitTag(name: fields[0], commit: fields[1], date: Double(fields[2]).map(Date.init(timeIntervalSince1970:)))
        }
    }
}

/// A remote and its address (`remote -v`, credentials already removed by the engine).
struct GitRemote: Identifiable, Hashable {
    var name: String
    var url: String
    var id: String { name }

    static func parse(_ output: String) -> [GitRemote] {
        var seen: [GitRemote] = []
        for line in output.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0 == "\t" || $0 == " " }).map(String.init)
            guard parts.count >= 2, !seen.contains(where: { $0.name == parts[0] }) else { continue }
            seen.append(GitRemote(name: parts[0], url: parts[1]))
        }
        return seen
    }
}

/// Another working folder of the repository (`worktree list --porcelain`).
struct GitWorktree: Identifiable, Hashable {
    var path: String
    var branch: String
    /// The repository's own folder (Git lists it first): it is never taken out.
    var main = false
    var id: String { path }

    static func parse(_ output: String) -> [GitWorktree] {
        let folders: [GitWorktree] = output.components(separatedBy: "\n\n").compactMap { block in
            var path = "", branch = ""
            for line in block.split(separator: "\n") {
                if line.hasPrefix("worktree ") { path = String(line.dropFirst(9)) }
                if line.hasPrefix("branch ") { branch = String(line.dropFirst(7)).replacingOccurrences(of: "refs/heads/", with: "") }
                if line == "detached" { branch = "" }
            }
            return path.isEmpty ? nil : GitWorktree(path: path, branch: branch)
        }
        return folders.enumerated().map { index, folder in
            var folder = folder
            folder.main = index == 0
            return folder
        }
    }
}

/// Reads a list of «Más…» with a query and parses it; again after each action.
struct GitQueryList<Item: Identifiable & Hashable, Row: View, Actions: View>: View {
    let repository: GitRepository
    let arguments: [String]
    let parse: (String) -> [Item]
    let empty: (title: String, detail: String, symbol: String)
    let identifier: String
    @ViewBuilder let row: (Item) -> Row
    @ViewBuilder let actions: () -> Actions
    @State private var items: [Item]?
    /// Why the list could not be read: not the same as an empty one.
    @State private var failure: GitFailure?
    @State private var retries = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) { actions(); Spacer() }
                .padding(.horizontal, 14).padding(.vertical, 8)
            Divider()
            List(items ?? []) { item in row(item) }
                .listStyle(.inset)
                .themedScroll()
                .accessibilityIdentifier(identifier)
                .overlay {
                    if let failure {
                        ContentUnavailableView {
                            Label(failure.title, systemImage: Symbols.warning)
                        } description: {
                            Text(failure.detail)
                        } actions: {
                            Button(L("common.retry")) { retries += 1 }.accessibilityIdentifier("git.more.retry")
                        }
                    } else if items == nil {
                        ProgressView()
                    } else if items?.isEmpty == true {
                        ContentUnavailableView(empty.title, systemImage: empty.symbol, description: Text(empty.detail))
                    }
                }
        }
        .task(id: "\(repository.snapshot.headCommit?.hash ?? "")|\(repository.snapshot.remotes)|\(repository.files.count)|\(GitMoreRefresh.shared.generation)|\(retries)") {
            do {
                let output = try await repository.query(arguments)
                guard !Task.isCancelled else { return }
                items = parse(output)
                failure = nil
            } catch {
                let problem = GitFailure(error)
                if !problem.cancelled && !Task.isCancelled { failure = problem }
            }
        }
    }
}

/// Bumped after an action of «Más…», so its list reads again.
@MainActor @Observable final class GitMoreRefresh {
    static let shared = GitMoreRefresh()
    var generation = 0
    func after(_ done: Bool) { if done { generation += 1 } }
}

struct GitStashList: View {
    let repository: GitRepository
    @State private var dropping: GitStash?

    var body: some View {
        GitQueryList(repository: repository, arguments: ["stash", "list", "--format=%gd%x1f%s%x1f%ct"], parse: GitStash.parse,
                     empty: (L("git.more.stashesEmpty"), L("git.more.stashesEmptyDetail"), Symbols.gitStash), identifier: "git.more.stashList") { stash in
            LabeledContent {
                HStack(spacing: 6) {
                    Button { Task { GitMoreRefresh.shared.after(await repository.perform(.stashApply, value: stash.name)) } } label: {
                        Label(L("git.more.apply"), systemImage: Symbols.restore)
                    }
                    .buttonStyle(.bordered).disabled(repository.busy).help(L("git.more.applyHelp"))
                    .accessibilityIdentifier("git.more.apply.\(stash.name)")
                    Button(role: .destructive) { dropping = stash } label: { Label(L("common.delete"), systemImage: Symbols.delete).labelStyle(.iconOnly) }
                        .buttonStyle(.borderless).disabled(repository.busy).help(L("git.more.dropHelp"))
                        .accessibilityIdentifier("git.more.drop.\(stash.name)")
                }
            } label: {
                Text(stash.message)
                Text(stash.date.map { $0.formatted(.relative(presentation: .named)) } ?? stash.name)
            }
        } actions: {
            Button { Task { GitMoreRefresh.shared.after(await repository.perform(.stash)) } } label: {
                Label(L("git.more.stashNow"), systemImage: Symbols.gitStash)
            }
            .buttonStyle(.bordered).disabled(repository.busy || repository.files.isEmpty)
            .help(L("git.more.stashNowHelp"))
            .accessibilityIdentifier("git.more.stashNow")
        }
        .confirmationDialog(L("git.more.dropTitle"), isPresented: Binding(get: { dropping != nil }, set: { if !$0 { dropping = nil } }), presenting: dropping) { stash in
            Button(L("common.delete"), role: .destructive) { Task { GitMoreRefresh.shared.after(await repository.perform(.stashDrop, value: stash.name)) } }.accessibilityIdentifier("git.more.dropConfirm")
            Button(L("common.cancel"), role: .cancel) {}.accessibilityIdentifier("git.more.dropCancel")
        } message: { stash in
            Text(String(format: L("git.more.dropDetail"), stash.message))
        }
    }
}

struct GitTagList: View {
    let repository: GitRepository
    @State private var deleting: GitTag?
    @State private var creating = false

    var body: some View {
        GitQueryList(repository: repository,
                     arguments: ["tag", "--list", "--sort=-creatordate", "--format=%(refname:short)%09%(objectname:short)%09%(creatordate:unix)"],
                     parse: GitTag.parse, empty: (L("git.more.tagsEmpty"), L("git.more.tagsEmptyDetail"), Symbols.tags),
                     identifier: "git.more.tagList") { tag in
            LabeledContent {
                Button(role: .destructive) { deleting = tag } label: { Label(L("common.delete"), systemImage: Symbols.delete).labelStyle(.iconOnly) }
                    .buttonStyle(.borderless).disabled(repository.busy).help(L("git.more.deleteTagHelp"))
                    .accessibilityIdentifier("git.more.deleteTag.\(tag.name)")
            } label: {
                Label(tag.name, systemImage: Symbols.tags)
                Text("\(tag.commit) · \(tag.date.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "")").font(.uiCaption.monospaced())
            }
        } actions: {
            Button { creating = true } label: { Label(L("git.more.newTagEllipsis"), systemImage: Symbols.add) }
                .buttonStyle(.bordered).disabled(repository.busy || repository.snapshot.headCommit == nil)
                .accessibilityIdentifier("git.more.newTag")
        }
        .confirmationDialog(String(format: L("git.more.deleteTagTitle"), deleting?.name ?? ""),
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { tag in
            Button(L("common.delete"), role: .destructive) { Task { GitMoreRefresh.shared.after(await repository.perform(.deleteTag, value: tag.name)) } }.accessibilityIdentifier("git.more.deleteTagConfirm")
            Button(L("common.cancel"), role: .cancel) {}.accessibilityIdentifier("git.more.deleteTagCancel")
        } message: { _ in
            Text(L("git.more.deleteTagDetail"))
        }
        .sheet(isPresented: $creating) {
            if let head = repository.snapshot.headCommit {
                GitCommitNameSheet(repository: repository, request: GitNameRequest(kind: .tag, commit: head))
                    .themedSheet()
                    .onDisappear { GitMoreRefresh.shared.after(true) }
            }
        }
    }
}

struct GitRemoteList: View {
    let repository: GitRepository
    @State private var removing: GitRemote?
    @State private var adding = false

    var body: some View {
        GitQueryList(repository: repository, arguments: ["remote", "-v"], parse: GitRemote.parse,
                     empty: (L("git.more.remotesEmpty"), L("git.more.remotesEmptyDetail"), Symbols.cloud), identifier: "git.more.remoteList") { remote in
            LabeledContent {
                Button(role: .destructive) { removing = remote } label: { Label(L("git.more.removeRemote"), systemImage: Symbols.delete).labelStyle(.iconOnly) }
                    .buttonStyle(.borderless).disabled(repository.busy).help(L("git.more.removeRemoteHelp"))
                    .accessibilityIdentifier("git.more.removeRemote.\(remote.name)")
            } label: {
                Label(remote.name, systemImage: Symbols.cloud)
                Text(remote.url).lineLimit(1).truncationMode(.middle).help(remote.url)
            }
        } actions: {
            Button { adding = true } label: { Label(L("git.more.addRemoteEllipsis"), systemImage: Symbols.add) }
                .buttonStyle(.bordered).disabled(repository.busy)
                .accessibilityIdentifier("git.more.addRemote")
        }
        .confirmationDialog(String(format: L("git.more.removeRemoteTitle"), removing?.name ?? ""),
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), presenting: removing) { remote in
            Button(L("git.more.removeRemote"), role: .destructive) {
                Task { GitMoreRefresh.shared.after(await repository.perform(.removeRemote, value: remote.name)) }
            }
            .accessibilityIdentifier("git.more.removeRemoteConfirm")
            Button(L("common.cancel"), role: .cancel) {}.accessibilityIdentifier("git.more.removeRemoteCancel")
        } message: { _ in
            Text(L("git.more.removeRemoteDetail"))
        }
        .sheet(isPresented: $adding) { GitAddRemoteSheet(repository: repository).themedSheet() }
    }
}

/// «Agregar remoto…»: a name and the address of a repository on a server or a folder.
private struct GitAddRemoteSheet: View {
    let repository: GitRepository
    @State private var name = ""
    @State private var url = ""

    private var valid: Bool {
        let clean = name.trimmingCharacters(in: .whitespaces), address = url.trimmingCharacters(in: .whitespaces)
        return !clean.isEmpty && !clean.hasPrefix("-") && clean.rangeOfCharacter(from: CharacterSet(charactersIn: " /~^:?*[\\")) == nil
            && !address.isEmpty && !address.hasPrefix("-") && address.rangeOfCharacter(from: .whitespaces) == nil
            && !repository.snapshot.remotes.contains(clean)
    }

    var body: some View {
        SheetFrame(title: L("git.more.addRemoteTitle"), symbol: Symbols.cloud, detail: L("git.more.addRemoteDetail"), width: 460,
                   actionTitle: L("git.more.addRemote"), actionID: "git.more.addRemoteSave", canAct: valid && !repository.busy,
                   cancelID: "git.more.addRemoteCancel") {
            let done = await repository.perform(.addRemote, value: name.trimmingCharacters(in: .whitespaces) + "\n" + url.trimmingCharacters(in: .whitespaces))
            GitMoreRefresh.shared.after(done)
            return done
        } content: {
            Form {
                TextField(L("git.more.remoteName"), text: $name, prompt: Text(verbatim: "origin")).accessibilityIdentifier("git.more.remoteName")
                TextField(L("git.more.remoteURL"), text: $url).accessibilityIdentifier("git.more.remoteURL")
            }
            .formStyle(.grouped).scrollDisabled(true)
        }
    }
}
