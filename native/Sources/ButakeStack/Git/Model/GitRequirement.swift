import Foundation

/// Whether this Mac has a Git the tool can use. The engine runs the installed `git`; without Apple's
/// command line tools `/usr/bin/git` is only a stub, so nothing is asked of it then (it would open
/// Apple's installer by surprise). Git and the way to install it live in Utilidades › Repositorios.
enum GitRequirement: Equatable, Sendable {
    case checking
    case ready(version: String)
    case missing
    /// Installed but older than `minimum` (the engine uses `switch`, `restore` and
    /// `--pathspec-from-file`).
    case outdated(version: String)

    static let minimum = [2, 25]

    var ready: Bool { if case .ready = self { true } else { false } }

    /// "git version 2.39.5 (Apple Git-154)" → [2, 39, 5].
    static func numbers(_ text: String) -> [Int]? {
        guard let word = text.split(separator: " ").first(where: { $0.first?.isNumber == true }) else { return nil }
        let parts = word.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        return parts.isEmpty ? nil : parts
    }

    /// The state for the version Git reports.
    static func of(version text: String) -> GitRequirement {
        let short = text.replacingOccurrences(of: "git version ", with: "")
        guard let numbers = numbers(text) else { return .outdated(version: short) }
        let padded = numbers + [0, 0]
        let recent = zip(padded, minimum).first { $0 != $1 }.map { $0 > $1 } ?? true
        return recent ? .ready(version: short) : .outdated(version: short)
    }
}
