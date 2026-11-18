import Foundation

/// A command line typed in «Comprobar» and «Compilar», as the words a process receives (no shell).
extension ProjectProcess {
    /// The line as it is edited: a word with a space, a quote or a backslash is written in double
    /// quotes, so that `words(of:)` gives the same program and arguments back.
    var editableLine: String { ([program] + args).map(Self.quoted).joined(separator: " ") }

    private static func quoted(_ word: String) -> String {
        guard word.isEmpty || word.contains(where: { $0.isWhitespace || $0 == "\"" || $0 == "'" || $0 == "\\" }) else { return word }
        return "\"" + word.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Splits a line at whitespace. Single quotes keep everything inside as it is; double quotes keep
    /// the spaces inside; a backslash outside single quotes escapes the next character. An unclosed
    /// quote runs to the end of the line.
    static func words(of line: String) -> [String] {
        var words: [String] = []
        var current = ""
        var started = false
        var quote: Character?
        var escaping = false
        for character in line {
            if escaping {
                current.append(character); escaping = false
            } else if quote == "'" {
                if character == "'" { quote = nil } else { current.append(character) }
            } else if character == "\\" && quote != "'" {
                escaping = true; started = true
            } else if let open = quote {
                if character == open { quote = nil } else { current.append(character) }
            } else if character == "\"" || character == "'" {
                quote = character; started = true
            } else if character.isWhitespace {
                if started { words.append(current); current = ""; started = false }
            } else {
                current.append(character); started = true
            }
        }
        if started { words.append(current) }
        return words
    }
}
