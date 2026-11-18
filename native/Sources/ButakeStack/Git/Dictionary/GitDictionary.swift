import Foundation

/// The dictionary of Git (`Resources/GitDictionary.json`): every command of Git's own catalog (the
/// 152 the engine knows, `engine/src/git/commands.json`) with a line in Spanish, and the words of
/// Git explained. Help to look up; the tool's buttons never need it.
struct GitDictionary: Decodable, Sendable {
    struct Command: Decodable, Identifiable, Hashable, Sendable {
        var name: String
        var category: String
        var description: String
        var documentation: String
        var experimental: Bool
        var id: String { name }
        var documentationURL: URL? { URL(string: documentation).flatMap { $0.scheme == "https" ? $0 : nil } }
    }
    struct Concept: Decodable, Identifiable, Hashable, Sendable {
        var id: String
        var term: String
        var definition: String
    }

    var commands: [Command]
    var concepts: [Concept]

    /// The categories of Git's catalog, from everyday use to its internals.
    static let categories = ["everyday", "inspection", "administration", "interop", "transport", "helpers", "plumbing-read", "plumbing-write"]

    static let shared: GitDictionary = load()

    static func load(bundle: Bundle = .module) -> GitDictionary {
        guard let url = bundle.url(forResource: "GitDictionary", withExtension: "json"), let data = try? Data(contentsOf: url),
              let dictionary = try? JSONDecoder().decode(GitDictionary.self, from: data) else { return GitDictionary(commands: [], concepts: []) }
        return dictionary
    }

    /// Commands of `category` (all when nil) whose name or line has `text`.
    func commands(matching text: String, category: String?) -> [Command] {
        commands.filter { command in
            (category == nil || command.category == category)
                && (text.isEmpty || command.name.localizedCaseInsensitiveContains(text) || command.description.localizedCaseInsensitiveContains(text))
        }
    }

    /// Words whose term or explanation has `text`.
    func concepts(matching text: String) -> [Concept] {
        concepts.filter { text.isEmpty || $0.term.localizedCaseInsensitiveContains(text) || $0.definition.localizedCaseInsensitiveContains(text) }
    }
}

/// `gitCapabilities`, as the dictionary reads it: which commands this Mac's Git has.
struct GitCommandCapabilities: Decodable, Sendable {
    struct Command: Decodable, Sendable { var name: String; var available: Bool; var library: Bool }
    var version: String
    var commands: [Command]
}
