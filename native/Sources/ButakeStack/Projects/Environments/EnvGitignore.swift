import SwiftUI

/// The fix for «el .env no está en .gitignore»: one line added to the project's own `.gitignore`.
/// It is a file of the user's, so the caller confirms first, and every change can be taken back.
enum GitignoreFix {
    static let line = ".env"
    static let fileName = ".gitignore"

    /// What a change did: the file as it was (nil: it did not exist) and as it is now.
    struct Change: Equatable {
        let url: URL
        let before: String?
        let after: String
    }

    enum Failure: Error, Equatable { case symlink, unreadable }

    static func url(in projectPath: String) -> URL { URL(fileURLWithPath: projectPath).appendingPathComponent(fileName) }

    /// The text with the line at the end, or nil when it already has it.
    static func adding(to text: String?) -> String? {
        let lines = (text ?? "").components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        if lines.contains(line) || lines.contains("/" + line) { return nil }
        guard let text, !text.isEmpty else { return line + "\n" }
        return text.hasSuffix("\n") ? text + line + "\n" : text + "\n" + line + "\n"
    }

    /// Adds the line to `<project>/.gitignore` (created when missing). Nil when nothing was needed.
    static func add(inProject path: String) throws -> Change? {
        let url = url(in: path)
        var before: String?
        if let kind = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType {
            // A link would send the write somewhere else: it stays the user's to edit.
            if kind == .typeSymbolicLink { throw Failure.symlink }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { throw Failure.unreadable }
            before = text
        }
        guard let after = adding(to: before) else { return nil }
        try after.write(to: url, atomically: true, encoding: .utf8)
        return Change(url: url, before: before, after: after)
    }

    /// Puts the file back as it was, unless someone changed it since: then it is left alone (false).
    @discardableResult
    static func undo(_ change: Change) -> Bool {
        guard (try? String(contentsOf: change.url, encoding: .utf8)) == change.after else { return false }
        if let before = change.before {
            return (try? before.write(to: change.url, atomically: true, encoding: .utf8)) != nil
        }
        return (try? FileManager.default.removeItem(at: change.url)) != nil
    }

    /// Does it again after an undo (⇧⌘Z), with the same guard.
    @discardableResult
    static func redo(_ change: Change) -> Bool {
        guard (try? String(contentsOf: change.url, encoding: .utf8)) == change.before else { return false }
        return (try? change.after.write(to: change.url, atomically: true, encoding: .utf8)) != nil
    }
}

/// A `.env` file dropped on Entornos: which files count, and what is read from them.
enum EnvImportFile {
    /// What Stack reads of a `.env`: the supervisor's own limit.
    static let maxBytes = 1_048_576

    /// `.env`, `.env.local`, `production.env`: by name, never by content.
    static func looksLikeEnv(_ name: String) -> Bool {
        name == ".env" || name.hasPrefix(".env.") || name.hasSuffix(".env")
    }

    /// A regular file (not a link) of a `.env` name and 1 MiB or less.
    static func accepts(_ url: URL) -> Bool {
        guard url.isFileURL, looksLikeEnv(url.lastPathComponent),
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? Int else { return false }
        return size <= maxBytes
    }
}

extension StackStore {
    /// A `.env` the user dropped becomes the project's «Local» environment, the same way «Importar»
    /// does with the project's own `.env`: secrets go to the Keychain, nothing is lost (R8).
    func importEnvFile(_ project: Project, from url: URL) async -> Bool {
        guard EnvImportFile.accepts(url), let text = try? String(contentsOf: url, encoding: .utf8) else {
            errorMessage = L("env.drop.invalid")
            return false
        }
        let pairs = DotEnv.parse(text)
        guard !pairs.isEmpty else { errorMessage = L("env.drop.empty"); return false }
        let secret = await classify(pairs.map(\.0))
        var entries: [EnvEntry] = []
        var secrets: [String: String] = [:]
        for (index, pair) in pairs.enumerated() {
            if secret[index] { secrets[pair.0] = pair.1 }
            entries.append(EnvEntry(key: pair.0, value: secret[index] ? "" : pair.1, secret: secret[index]))
        }
        guard await updateSecrets(project.id, "local", set: secrets) else { return false }
        var site = envs[project.id]?.site ?? ProjectEnvironments(active: nil, environments: [])
        site.environments.removeAll { $0.id == "local" }
        site.environments.insert(EnvEnvironment(id: "local", name: L("env.kind.local"), kind: .local, entries: entries), at: 0)
        site.active = "local"
        guard await saveEnvs(project.id, site) else { return false }
        await envAudit(project.id, env: "local", action: "importar")
        notify(L("env.imported"))
        return true
    }
}

/// The `.env` is not ignored (a warning with its fix: one line in `.gitignore`, after a yes that says
/// which line and which file) or is tracked (an error: that one takes `git rm --cached`, which Stack
/// does not run for the user).
struct EnvGuardNotice: View {
    let store: StackStore
    let project: Project
    let message: String
    let tracked: Bool
    @State private var confirming = false
    @Environment(\.undoManager) private var undoManager

    private var file: String { GitignoreFix.url(in: project.path).path.replacingOccurrences(of: NSHomeDirectory(), with: "~") }

    var body: some View {
        if tracked {
            Notice(.error, message)
        } else {
            Notice(.warning, message) {
                Button { confirming = true } label: { Label(L("env.gitignore.addButton"), systemImage: Symbols.add) }
                    .buttonStyle(.bordered).accessibilityIdentifier("env.gitignore.add")
            }
            .confirmationDialog(L("env.gitignore.confirmTitle"), isPresented: $confirming) {
                Button(L("env.gitignore.add")) { add() }.accessibilityIdentifier("env.gitignore.confirm")
                Button(L("common.cancel"), role: .cancel) {}
            } message: {
                Text(String(format: L("env.gitignore.confirmDetail"), GitignoreFix.line, file))
            }
        }
    }

    /// Adds the line after the user's yes, says so, and can be undone (⌘Z).
    private func add() {
        let id = project.id
        do {
            if let change = try GitignoreFix.add(inProject: project.path) {
                store.notify(String(format: L("env.gitignore.added"), GitignoreFix.line))
                Self.register(change, undoing: false, store: store, id: id, undoManager: undoManager)
            }
            Task { await store.loadEnvs(id) }
        } catch {
            store.errorMessage = L("env.gitignore.failed")
        }
    }

    /// ⌘Z takes the line out again (⇧⌘Z puts it back); each step registers the other.
    private static func register(_ change: GitignoreFix.Change, undoing: Bool, store: StackStore, id: String, undoManager: UndoManager?) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: store) { store in
            _ = undoing ? GitignoreFix.redo(change) : GitignoreFix.undo(change)
            Task { @MainActor in await store.loadEnvs(id) }
            register(change, undoing: !undoing, store: store, id: id, undoManager: undoManager)
        }
        undoManager.setActionName(String(format: L("env.gitignore.undo"), GitignoreFix.line))
    }
}
