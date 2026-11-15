import Foundation

/// What Historial's search looks in (DISENO.md, «Búsquedas»): the commits by message, author,
/// file, date or identifier, or the text inside the repository's files («Contenido»).
enum GitHistorySearchScope: String, CaseIterable, Identifiable, Sendable {
    case message, author, file, date, identifier, content
    var id: String { rawValue }
    var title: String { L("git.history.scope.\(rawValue)") }
    var prompt: String { L("git.history.prompt.\(rawValue)") }
}

/// A line of a file that contains the searched text («Contenido»).
struct GitContentMatch: Identifiable, Hashable, Sendable {
    var path: String
    var line: Int
    var text: String
    var id: String { "\(path):\(line)" }
}

/// The Git queries of the search, as pure rules: each scope becomes the arguments of `gitQuery`.
enum GitHistorySearch {
    /// The fields of a commit row, as the snapshot reads them.
    static let format = "--format=%H%x1f%P%x1f%an%x1f%at%x1f%s%x1f%D"
    /// Most commits a search brings.
    static let limit = 300
    /// Most lines «Contenido» shows.
    static let contentLimit = 500

    /// The revisions of the list: the current branch, or every branch, remote branch and tag.
    static func revisions(onlyBranch: Bool) -> [String] {
        onlyBranch ? ["HEAD"] : ["--branches", "--remotes", "--tags", "HEAD"]
    }

    /// The query of a search, or nil when there is nothing to ask (an empty text, a date that is not
    /// one, an identifier that is not hexadecimal, a file that matches no path).
    static func arguments(_ scope: GitHistorySearchScope, text raw: String, onlyBranch: Bool, paths: [String] = [],
                          now: Date = Date(), calendar: Calendar = .current) -> [String]? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let revisions = revisions(onlyBranch: onlyBranch)
        let log = ["log", "-\(limit)", "--no-show-signature", format]
        switch scope {
        case .message:
            return log + ["--regexp-ignore-case", "--fixed-strings", "--grep=\(text)"] + revisions
        case .author:
            return log + ["--regexp-ignore-case", "--fixed-strings", "--author=\(text)"] + revisions
        case .file:
            let matching = matchingPaths(text, in: paths)
            guard !matching.isEmpty else { return nil }
            return log + revisions + ["--"] + matching
        case .date:
            guard let range = GitHistoryDate.range(text, now: now, calendar: calendar) else { return nil }
            return log + ["--since=\(range.since)", "--until=\(range.until)"] + revisions
        case .identifier:
            guard isIdentifier(text) else { return nil }
            return ["log", "-1", "--no-show-signature", format, text.lowercased(), "--"]
        case .content:
            return ["grep", "-n", "-I", "-z", "--fixed-strings", "--ignore-case", "-e", text]
        }
    }

    /// 4 to 40 hexadecimal characters: the start of a commit's identifier.
    static func isIdentifier(_ text: String) -> Bool {
        (4...40).contains(text.count) && text.allSatisfy(\.isHexDigit)
    }

    /// The repository's paths that contain the text (name or folder), at most 200: Git runs with
    /// literal paths, so the matching happens here.
    static func matchingPaths(_ text: String, in paths: [String]) -> [String] {
        let exact = paths.filter { $0 == text }
        if !exact.isEmpty { return exact }
        return Array(paths.lazy.filter { $0.localizedCaseInsensitiveContains(text) }.prefix(200))
    }

    /// Commit rows of `log` with `format`.
    static func commits(_ output: String) -> [GitCommitSummary] {
        output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 6, fields[0].count >= 7 else { return nil }
            return GitCommitSummary(hash: fields[0], parents: fields[1].split(separator: " ").map(String.init), author: fields[2],
                                    timestamp: fields[3], subject: fields[4], refs: fields[5])
        }
    }

    /// Lines of `grep -n -z`: path, line number and text separated by NUL.
    static func matches(_ output: String) -> [GitContentMatch] {
        var result: [GitContentMatch] = []
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: "\0", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3, let number = Int(parts[1]) else { continue }
            result.append(GitContentMatch(path: String(parts[0]), line: number, text: String(parts[2]).trimmingCharacters(in: .whitespaces)))
            if result.count == contentLimit { break }
        }
        return result
    }

    /// What to suggest while typing, for the scope.
    static func suggestions(_ scope: GitHistorySearchScope, text: String, commits: [GitCommitSummary], paths: [String]) -> [String] {
        let typed = text.trimmingCharacters(in: .whitespaces)
        func filtered(_ values: [String]) -> [String] {
            let unique = values.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            let shown = typed.isEmpty ? unique : unique.filter { $0.localizedCaseInsensitiveContains(typed) && $0 != typed }
            return Array(shown.prefix(8))
        }
        switch scope {
        case .message: return filtered(commits.prefix(400).map(\.subject))
        case .author: return filtered(commits.map(\.author))
        case .file, .content: return filtered(paths)
        case .date: return filtered(GitHistoryDate.words.map { L("git.history.date.\($0)") })
        case .identifier: return filtered(commits.prefix(400).map { String($0.hash.prefix(10)) })
        }
    }
}

/// The dates the search understands: a day (`2026-11-14`, `14/11/2026`), a month (`2026-11`), a
/// year (`2026`) or a word («hoy», «ayer», «esta semana», «este mes»).
enum GitHistoryDate {
    static let words = ["today", "yesterday", "week", "month"]

    /// The start and the end (exclusive) of the period, as Git reads them.
    static func range(_ raw: String, now: Date, calendar: Calendar) -> (since: String, until: String)? {
        let text = raw.trimmingCharacters(in: .whitespaces).lowercased()
        let today = calendar.startOfDay(for: now)
        let period: (start: Date, end: Date)?
        if let word = words.first(where: { text == L("git.history.date.\($0)").lowercased() || text == $0 }) {
            switch word {
            case "today": period = (today, calendar.date(byAdding: .day, value: 1, to: today) ?? today)
            case "yesterday": period = (calendar.date(byAdding: .day, value: -1, to: today) ?? today, today)
            case "week": period = calendar.dateInterval(of: .weekOfYear, for: now).map { ($0.start, $0.end) }
            default: period = calendar.dateInterval(of: .month, for: now).map { ($0.start, $0.end) }
            }
        } else {
            period = parse(text, calendar: calendar)
        }
        guard let period else { return nil }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return (formatter.string(from: period.start), formatter.string(from: period.end))
    }

    private static func parse(_ text: String, calendar: Calendar) -> (start: Date, end: Date)? {
        let numbers = text.split(whereSeparator: { $0 == "-" || $0 == "/" || $0 == "." }).map { Int($0) }
        guard !numbers.isEmpty, numbers.allSatisfy({ $0 != nil }) else { return nil }
        let values = numbers.compactMap { $0 }
        var parts = DateComponents()
        let unit: Calendar.Component
        switch values.count {
        case 1 where values[0] >= 1970 && values[0] <= 9999:
            parts.year = values[0]; parts.month = 1; parts.day = 1; unit = .year
        case 2 where values[0] >= 1970 && (1...12).contains(values[1]):
            parts.year = values[0]; parts.month = values[1]; parts.day = 1; unit = .month
        case 3 where values[0] >= 1970:
            parts.year = values[0]; parts.month = values[1]; parts.day = values[2]; unit = .day
        case 3 where values[2] >= 1970:
            parts.year = values[2]; parts.month = values[1]; parts.day = values[0]; unit = .day
        default: return nil
        }
        guard (1...12).contains(parts.month ?? 0), (1...31).contains(parts.day ?? 0),
              let start = calendar.date(from: parts), calendar.component(.day, from: start) == parts.day,
              let end = calendar.date(byAdding: unit, value: 1, to: start) else { return nil }
        return (start, end)
    }
}
