import Foundation

/// Lays out SQL for reading: keywords in capitals, each main clause on its own line, the select
/// list and the AND/OR of a condition one per line. Strings, quoted names and comments stay as
/// they are; nothing is reordered and spacing elsewhere follows the original (collapsed).
enum SQLFormatter {
    enum Token: Equatable { case word(String), quoted(String), comment(String), symbol(Character), space }

    static func tokens(_ text: String) -> [Token] {
        var out: [Token] = []
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            let next = i + 1 < chars.count ? chars[i + 1] : nil
            if c.isWhitespace {
                while i < chars.count, chars[i].isWhitespace { i += 1 }
                out.append(.space)
            } else if c == "-" && next == "-" {
                var j = i
                while j < chars.count, chars[j] != "\n" { j += 1 }
                out.append(.comment(String(chars[i..<j])))
                i = j
            } else if c == "/" && next == "*" {
                var j = i + 2
                while j + 1 < chars.count, !(chars[j] == "*" && chars[j + 1] == "/") { j += 1 }
                j = min(j + 2, chars.count)
                out.append(.comment(String(chars[i..<j])))
                i = j
            } else if c == "'" || c == "\"" || c == "`" {
                var j = i + 1
                while j < chars.count {
                    if chars[j] == "\\" && c == "'" { j += 2; continue }
                    if chars[j] == c {
                        if j + 1 < chars.count, chars[j + 1] == c { j += 2; continue }
                        break
                    }
                    j += 1
                }
                j = min(j + 1, chars.count)
                out.append(.quoted(String(chars[i..<j])))
                i = j
            } else if c.isLetter || c.isNumber || c == "_" || c == "$" || c == "@" {
                var j = i + 1
                while j < chars.count, chars[j].isLetter || chars[j].isNumber || chars[j] == "_" || chars[j] == "$" { j += 1 }
                out.append(.word(String(chars[i..<j])))
                i = j
            } else {
                out.append(.symbol(c))
                i += 1
            }
        }
        return out
    }

    /// Clauses that start a line of their own.
    static let clauses: Set<String> = ["SELECT", "FROM", "WHERE", "GROUP", "ORDER", "HAVING", "LIMIT", "OFFSET", "UNION", "EXCEPT", "INTERSECT",
                                       "VALUES", "SET", "RETURNING", "INSERT", "UPDATE", "DELETE", "WITH", "WINDOW"]
    static let joins: Set<String> = ["JOIN", "LEFT", "RIGHT", "INNER", "FULL", "CROSS", "NATURAL"]

    static func format(_ text: String) -> String {
        var out = ""
        var depth = 0
        var clause = ""
        var previous = ""
        // "BETWEEN 1 AND 2" keeps its AND on the line.
        var between = false
        var space = false
        func trimEnd() { while out.last == " " { out.removeLast() } }
        func newline(_ indent: Int) {
            trimEnd()
            if !out.isEmpty && out.last != "\n" { out.append("\n") }
            out.append(String(repeating: "    ", count: indent))
            space = false
        }
        func put(_ piece: String) {
            if space, let last = out.last, last != "\n", last != " " { out.append(" ") }
            out.append(piece)
            space = false
        }
        for token in tokens(text) {
            switch token {
            case .space:
                space = true
            case .comment(let c):
                put(c)
                if c.hasPrefix("--") { newline(depth) }
            case .quoted(let q):
                put(q)
                previous = ""
            case .word(let w):
                let upper = w.dataCapitals
                let shown = SQLHighlighter.keywords.contains(w.lowercased()) ? upper : w
                let startsJoin = joins.contains(upper) && !joins.contains(previous) && previous != "OUTER"
                let startsClause = clauses.contains(upper) && !(upper == "SET" && clause != "UPDATE") && !(previous == "DELETE" && upper == "FROM")
                    && !(previous == "INSERT") && !(previous == "UNION" && upper == "ALL")
                if startsClause {
                    newline(depth)
                    clause = upper
                } else if startsJoin {
                    newline(depth)
                } else if (upper == "AND" || upper == "OR") && ["WHERE", "HAVING", "ON"].contains(clause) && !(upper == "AND" && between) {
                    newline(depth + 1)
                }
                if upper == "ON" && depth == 0 { clause = "ON" }
                put(shown)
                if upper == "BETWEEN" { between = true } else if upper == "AND" { between = false }
                previous = upper
            case .symbol(let s):
                switch s {
                case ",":
                    trimEnd()
                    out.append(",")
                    space = true
                    if ["SELECT", "GROUP", "ORDER"].contains(clause) && depth == 0 { newline(1) }
                case ";":
                    trimEnd()
                    out.append(";\n\n")
                    space = false
                    clause = ""
                    depth = 0
                case "(":
                    put("(")
                    depth += 1
                case ")":
                    trimEnd()
                    out.append(")")
                    depth = max(0, depth - 1)
                default:
                    put(String(s))
                }
                previous = ""
            }
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Completion of the SQL editor: keywords, the tables of the current database and their columns.
enum SQLCompletion {
    static func suggestions(prefix: String, qualifier: String?, schema: DBSchema?) -> [String] {
        let lower = prefix.lowercased()
        let tables = schema?.tables ?? []
        func matching(_ list: [String]) -> [String] {
            var seen = Set<String>()
            return list.filter { $0.lowercased().hasPrefix(lower) && $0.lowercased() != lower && seen.insert($0.lowercased()).inserted }
        }
        if let qualifier {
            // "users." → its columns; "public." → the schema's tables.
            let q = qualifier.lowercased()
            if let table = tables.first(where: { ($0.name ?? "").lowercased() == q }) {
                return matching(table.columns.compactMap(\.name))
            }
            return matching(tables.filter { ($0.schema ?? "").lowercased() == q }.compactMap(\.name)).sorted()
        }
        let names = tables.compactMap(\.name).sorted()
        let columns = Array(Set(tables.flatMap { $0.columns.compactMap(\.name) })).sorted()
        let keywords = SQLHighlighter.keywords.map(\.dataCapitals).sorted()
        return Array(matching(names + columns + keywords).prefix(60))
    }
}
