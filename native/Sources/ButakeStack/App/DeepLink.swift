import Foundation

/// A `butakestack://` link read as untrusted input: a closed list of destinations, each with the
/// keys it accepts. A link that does not fit is turned down whole, with the reason, and the app does
/// not move. A link only shows something; it never starts, connects or installs by itself.
enum DeepLink {
    /// The longest link read at all (characters of its text).
    static let maximumLength = 2000
    /// The longest value of a path segment or a key.
    static let maximumValue = 400

    enum Target: Equatable {
        case home
        case setup
        case site(String)
        case renameProject(id: String, newId: String?)
        /// An absolute folder (its existence is checked when it is used).
        case openFolder(String)
        case tool(String, items: [URLQueryItem])
        /// `paths`: the `path` items of `vault/import`; nil when the link only opens the tool.
        case vault(paths: [URLQueryItem]?)
        case git(path: String?)
        case service(String)
        case settingsGeneral
        case settingsTools
        case ssh(String)
        case database(String)
    }

    enum Failure: Error, Equatable {
        case tooLong
        case notStack
        case unknownDestination(String)
        case unknownPath(String)
        case unknownKey(String)
        case duplicateKey(String)
        case missingKey(String)
        case badValue(String)

        /// What the user reads, in Spanish.
        var message: String {
            switch self {
            case .tooLong: String(format: L("error.link"), L("error.link.tooLong"))
            case .notStack: String(format: L("error.link"), L("error.link.notStack"))
            case .unknownDestination(let name): String(format: L("error.link"), String(format: L("error.link.unknownDestination"), name))
            case .unknownPath(let path): String(format: L("error.link"), String(format: L("error.link.unknownPath"), path))
            case .unknownKey(let key): String(format: L("error.link"), String(format: L("error.link.unknownKey"), key))
            case .duplicateKey(let key): String(format: L("error.link"), String(format: L("error.link.duplicateKey"), key))
            case .missingKey(let key): String(format: L("error.link"), String(format: L("error.link.missingKey"), key))
            case .badValue(let key): String(format: L("error.link"), String(format: L("error.link.badValue"), key))
            }
        }
    }

    static func parse(_ url: URL) -> Result<Target, Failure> {
        guard url.absoluteString.count <= maximumLength else { return .failure(.tooLong) }
        guard url.scheme?.lowercased() == "butakestack" else { return .failure(.notStack) }
        let host = (url.host ?? "").lowercased()
        let segments = url.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        do {
            return .success(try target(host: host, segments: segments, items: items))
        } catch let failure as Failure {
            return .failure(failure)
        } catch {
            return .failure(.unknownDestination(host))
        }
    }

    private static func target(host: String, segments: [String], items: [URLQueryItem]) throws -> Target {
        switch host {
        case "home":
            try expect(segments, none: true, items: items, keys: [])
            return .home
        // butakestack://welcome is an older alias of the same assistant.
        case "setup", "welcome":
            try expect(segments, none: true, items: items, keys: [])
            return .setup
        case "site":
            try expect(segments, none: false, items: items, keys: [])
            return .site(try segment(segments, 0))
        case "project":
            guard segments == ["rename"] else { throw Failure.unknownPath("/" + segments.joined(separator: "/")) }
            try keys(items, allowed: ["id", "newId"], repeatable: [])
            guard let id = value(items, "id"), !id.isEmpty else { throw Failure.missingKey("id") }
            try check(id, key: "id")
            let newId = value(items, "newId")
            if let newId { try check(newId, key: "newId") }
            return .renameProject(id: id, newId: newId)
        case "open":
            try expect(segments, none: true, items: items, keys: ["path"])
            return .openFolder(try folder(items))
        case "tool":
            let id = try segment(segments, 0)
            guard segments.count == 1 else { throw Failure.unknownPath("/" + segments.joined(separator: "/")) }
            // Registros takes a filter: a process (`source`) or an origin of its list (`origin`).
            try keys(items, allowed: id == "logs" ? ["source", "origin"] : [], repeatable: [])
            if let origin = value(items, "origin"), LogOrigin(rawValue: origin) == nil { throw Failure.badValue("origin") }
            if let source = value(items, "source") { try check(source, key: "source") }
            return .tool(id, items: items)
        case "vault":
            switch segments {
            case []:
                try keys(items, allowed: [], repeatable: [])
                return .vault(paths: nil)
            case ["import"]:
                // One `path` per folder; the folders are checked by `VaultImportLink`.
                try keys(items, allowed: ["path"], repeatable: ["path"])
                return .vault(paths: items)
            default:
                throw Failure.unknownPath("/" + segments.joined(separator: "/"))
            }
        case "git":
            guard segments.isEmpty || segments == ["open"] else { throw Failure.unknownPath("/" + segments.joined(separator: "/")) }
            try keys(items, allowed: ["path"], repeatable: [])
            return .git(path: items.isEmpty ? nil : try folder(items))
        case "service":
            try expect(segments, none: false, items: items, keys: [])
            return .service(try segment(segments, 0))
        case "general":
            try expect(segments, none: true, items: items, keys: [])
            return .settingsGeneral
        case "plugins":
            try expect(segments, none: true, items: items, keys: [])
            return .settingsTools
        case "ssh":
            try expect(segments, none: false, items: items, keys: [])
            return .ssh(try segment(segments, 0))
        case "db":
            try expect(segments, none: false, items: items, keys: [])
            return .database(try segment(segments, 0))
        default:
            throw Failure.unknownDestination(host.isEmpty ? "" : String(host.prefix(40)))
        }
    }

    /// The path has the expected shape (no segments, or exactly one) and the keys are the allowed ones.
    private static func expect(_ segments: [String], none: Bool, items: [URLQueryItem], keys allowed: Set<String>) throws {
        if none, !segments.isEmpty { throw Failure.unknownPath("/" + segments.joined(separator: "/")) }
        if !none, segments.count != 1 { throw Failure.unknownPath("/" + segments.joined(separator: "/")) }
        try keys(items, allowed: allowed, repeatable: [])
    }

    /// An unknown key turns the whole link down; a repeated one too, unless that key is repeatable.
    private static func keys(_ items: [URLQueryItem], allowed: Set<String>, repeatable: Set<String>) throws {
        var seen: Set<String> = []
        for item in items {
            guard allowed.contains(item.name) else { throw Failure.unknownKey(String(item.name.prefix(40))) }
            if !seen.insert(item.name).inserted, !repeatable.contains(item.name) { throw Failure.duplicateKey(item.name) }
        }
    }

    private static func value(_ items: [URLQueryItem], _ name: String) -> String? {
        items.first { $0.name == name }?.value
    }

    private static func segment(_ segments: [String], _ index: Int) throws -> String {
        guard segments.indices.contains(index) else { throw Failure.missingKey("path") }
        try check(segments[index], key: "path")
        return segments[index]
    }

    /// A value of ordinary text: not empty, not long, without control characters or `..`.
    private static func check(_ text: String, key: String) throws {
        guard !text.isEmpty, text.count <= maximumValue, text != "..", text != ".",
              !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw Failure.badValue(key)
        }
    }

    /// The `path` of a link that names a folder: absolute, without `..` and without NUL.
    private static func folder(_ items: [URLQueryItem]) throws -> String {
        guard let path = value(items, "path"), !path.isEmpty else { throw Failure.missingKey("path") }
        guard path.hasPrefix("/"), path.count <= maximumValue, !path.contains("\0"),
              !path.split(separator: "/").contains("..") else { throw Failure.badValue("path") }
        return path
    }
}
