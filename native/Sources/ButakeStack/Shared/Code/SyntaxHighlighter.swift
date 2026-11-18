import AppKit

/// Language of a file for its syntax colors, from its name.
enum CodeLanguage: Hashable, Sendable {
    case php, blade, javascript, typescript, python, swift, rust, go, java, kotlin, ruby, csharp, c, css, html, markdown, json, yaml, toml, shell, sql, dotenv, plain

    static func of(_ path: String?) -> CodeLanguage {
        guard let path else { return .plain }
        let name = (path as NSString).lastPathComponent.lowercased()
        if name.hasSuffix(".blade.php") { return .blade }
        if name.hasPrefix(".env") { return .dotenv }
        if name == "dockerfile" || name == "makefile" { return .shell }
        switch (name as NSString).pathExtension {
        case "php": return .php
        case "js", "mjs", "cjs", "jsx", "vue", "svelte", "astro": return .javascript
        case "ts", "tsx", "mts", "cts": return .typescript
        case "py", "pyi": return .python
        case "swift": return .swift
        case "rs": return .rust
        case "go": return .go
        case "java": return .java
        case "kt", "kts": return .kotlin
        case "rb", "erb": return .ruby
        case "cs": return .csharp
        case "c", "h", "cpp", "cc", "hpp", "m", "mm": return .c
        case "css", "scss", "sass", "less": return .css
        case "html", "htm", "xml", "plist", "svg": return .html
        case "md", "markdown", "mdx": return .markdown
        case "json", "jsonc", "lock": return .json
        case "yml", "yaml": return .yaml
        case "toml", "ini", "cfg", "conf": return .toml
        case "sh", "bash", "zsh", "fish": return .shell
        case "sql": return .sql
        default: return .plain
        }
    }

    fileprivate var keywords: Set<String> {
        switch self {
        case .php, .blade: ["abstract", "and", "array", "as", "break", "case", "catch", "class", "clone", "const", "continue", "declare", "default", "do", "echo", "else", "elseif", "enum", "extends", "final", "finally", "fn", "for", "foreach", "function", "global", "if", "implements", "include", "instanceof", "interface", "match", "namespace", "new", "null", "or", "private", "protected", "public", "readonly", "require", "require_once", "return", "static", "switch", "throw", "trait", "try", "use", "var", "while", "yield", "true", "false", "self", "parent", "mixed", "void", "int", "string", "bool", "float"]
        case .javascript, .typescript: ["as", "async", "await", "break", "case", "catch", "class", "const", "continue", "default", "delete", "do", "else", "enum", "export", "extends", "false", "finally", "for", "from", "function", "if", "implements", "import", "in", "instanceof", "interface", "let", "new", "null", "of", "private", "protected", "public", "readonly", "return", "static", "super", "switch", "this", "throw", "true", "try", "type", "typeof", "undefined", "var", "void", "while", "yield", "keyof", "namespace", "declare", "abstract"]
        case .python: ["and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del", "elif", "else", "except", "False", "finally", "for", "from", "global", "if", "import", "in", "is", "lambda", "None", "nonlocal", "not", "or", "pass", "raise", "return", "self", "True", "try", "while", "with", "yield"]
        case .swift: ["actor", "as", "async", "await", "break", "case", "catch", "class", "continue", "default", "defer", "do", "else", "enum", "extension", "fallthrough", "false", "fileprivate", "final", "for", "func", "guard", "if", "import", "in", "init", "inout", "internal", "is", "let", "nil", "override", "private", "protocol", "public", "repeat", "return", "self", "Self", "some", "static", "struct", "super", "switch", "throw", "throws", "true", "try", "var", "where", "while", "any", "lazy", "weak", "mutating"]
        case .rust: ["as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum", "extern", "false", "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod", "move", "mut", "pub", "ref", "return", "self", "Self", "static", "struct", "super", "trait", "true", "type", "unsafe", "use", "where", "while", "Some", "None", "Ok", "Err"]
        case .go: ["break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough", "for", "func", "go", "goto", "if", "import", "interface", "map", "package", "range", "return", "select", "struct", "switch", "type", "var", "nil", "true", "false"]
        case .java, .kotlin, .csharp, .c: ["abstract", "break", "case", "catch", "class", "const", "continue", "default", "do", "else", "enum", "extends", "false", "final", "finally", "for", "fun", "if", "implements", "import", "interface", "internal", "is", "new", "null", "object", "override", "package", "private", "protected", "public", "return", "static", "struct", "super", "switch", "this", "throw", "true", "try", "using", "val", "var", "void", "when", "while", "namespace", "int", "char", "bool", "string", "include", "define", "typedef", "sizeof"]
        case .ruby: ["alias", "and", "begin", "break", "case", "class", "def", "do", "else", "elsif", "end", "ensure", "false", "for", "if", "in", "module", "next", "nil", "not", "or", "redo", "rescue", "retry", "return", "self", "super", "then", "true", "unless", "until", "when", "while", "yield", "require", "attr_accessor"]
        case .shell: ["if", "then", "else", "elif", "fi", "for", "in", "do", "done", "while", "case", "esac", "function", "return", "export", "local", "echo", "set", "unset", "source", "exit", "FROM", "RUN", "COPY", "CMD", "ENV", "WORKDIR", "EXPOSE", "ENTRYPOINT", "ARG"]
        case .sql: ["select", "from", "where", "insert", "into", "values", "update", "set", "delete", "create", "table", "alter", "drop", "index", "join", "left", "right", "inner", "outer", "on", "and", "or", "not", "null", "primary", "key", "foreign", "references", "group", "by", "order", "limit", "as", "distinct", "having", "union", "default", "unique"]
        case .yaml, .toml, .json: ["true", "false", "null", "yes", "no", "on", "off"]
        default: []
        }
    }

    fileprivate var lineComment: String? {
        switch self {
        case .python, .ruby, .shell, .yaml, .toml: "#"
        case .sql: "--"
        case .php, .blade, .javascript, .typescript, .swift, .rust, .go, .java, .kotlin, .csharp, .c: "//"
        default: nil
        }
    }

    fileprivate var markup: Bool { self == .html || self == .blade }
}

/// The syntax palette resolved once on the main thread (where the theme lives), so a highlighter built
/// with it colors text on any thread without looking the theme up for every span.
struct SyntaxColors: @unchecked Sendable {
    let keyword, string, comment, number, type, variable, attribute, tag, function: NSColor

    @MainActor static var current: SyntaxColors { SyntaxColors(theme: Brand.theme) }

    init(theme: Theme) {
        keyword = theme.keyword.ns; string = theme.string.ns; comment = theme.comment.ns; number = theme.number.ns; type = theme.type.ns
        variable = theme.variable.ns; attribute = theme.attribute.ns; tag = theme.tag.ns; function = theme.function.ns
    }
}

/// Line-oriented syntax colors for the diff and the editor. Regular expressions, no parser: fast enough
/// for 20 000 lines and good enough to read code at a glance. Block comments that span lines are
/// followed with `inBlockComment`.
struct SyntaxHighlighter: Sendable {
    let language: CodeLanguage
    let colors: SyntaxColors
    private let keywords: Set<String>

    init(language: CodeLanguage, colors: SyntaxColors) {
        self.language = language; self.colors = colors; keywords = language.keywords
    }

    // Constant patterns (they always compile).
    private static let string = try! NSRegularExpression(pattern: #""(?:[^"\\]|\\.)*"?|'(?:[^'\\]|\\.)*'?|`(?:[^`\\]|\\.)*`?"#)
    private static let number = try! NSRegularExpression(pattern: #"\b(?:0x[0-9a-fA-F]+|\d+(?:\.\d+)?)\b"#)
    private static let word = try! NSRegularExpression(pattern: #"[A-Za-z_][A-Za-z0-9_]*"#)
    private static let variable = try! NSRegularExpression(pattern: #"\$[A-Za-z_][A-Za-z0-9_]*"#)
    private static let attribute = try! NSRegularExpression(pattern: #"(?:^|\s)@[A-Za-z_][A-Za-z0-9_.]*|#\[[^\]]*\]"#)
    private static let tag = try! NSRegularExpression(pattern: #"</?[A-Za-z][A-Za-z0-9:\-.]*|/?>"#)
    private static let bladeDirective = try! NSRegularExpression(pattern: #"@[a-zA-Z]+|\{\{|\}\}|\{!!|!!\}"#)
    private static let cssProperty = try! NSRegularExpression(pattern: #"[a-z\-]+(?=\s*:)"#)
    private static let yamlKey = try! NSRegularExpression(pattern: #"^\s*-?\s*[A-Za-z0-9_."'\-]+(?=\s*[:=])"#)
    private static let markdownHeading = try! NSRegularExpression(pattern: #"^\s*#{1,6}\s.*$|\*\*[^*]+\*\*|`[^`]+`"#)
    private static let call = try! NSRegularExpression(pattern: #"[A-Za-z_][A-Za-z0-9_]*(?=\s*\()"#)

    /// Colored spans of `line`, relative to the line.
    func spans(_ line: String, inBlockComment: inout Bool) -> [(NSRange, NSColor)] {
        let text = line as NSString
        let full = NSRange(location: 0, length: text.length)
        guard full.length > 0, full.length < 2_000 else { return [] }
        var spans: [(NSRange, NSColor)] = []
        var protected: [NSRange] = []
        func free(_ range: NSRange) -> Bool { !protected.contains { NSIntersectionRange($0, range).length > 0 } }
        func add(_ range: NSRange, _ color: NSColor, protect: Bool = false) {
            guard range.length > 0, free(range) else { return }
            spans.append((range, color)); if protect { protected.append(range) }
        }
        // Block comments (/* … */, <!-- … -->, Blade {{-- … --}}) spanning lines.
        let opener = language.markup ? (language == .blade ? "{{--" : "<!--") : "/*"
        let closer = language.markup ? (language == .blade ? "--}}" : "-->") : "*/"
        if language != .plain, language != .python, language != .yaml, language != .markdown, language != .dotenv {
            var cursor = 0
            while cursor < full.length {
                if inBlockComment {
                    let end = text.range(of: closer, range: NSRange(location: cursor, length: full.length - cursor))
                    let stop = end.location == NSNotFound ? full.length : end.location + end.length
                    add(NSRange(location: cursor, length: stop - cursor), colors.comment, protect: true)
                    if end.location == NSNotFound { return spans }
                    inBlockComment = false; cursor = stop
                } else {
                    let start = text.range(of: opener, range: NSRange(location: cursor, length: full.length - cursor))
                    if start.location == NSNotFound { break }
                    // Openers inside strings of this line do not count.
                    if Self.string.matches(in: line, range: full).contains(where: { NSLocationInRange(start.location, $0.range) }) { cursor = start.location + start.length; continue }
                    inBlockComment = true; cursor = start.location
                }
            }
        }
        if language == .markdown {
            for match in Self.markdownHeading.matches(in: line, range: full) {
                let first = text.character(at: match.range.location)
                let color = first == 42 ? colors.type : first == 96 ? colors.string : colors.keyword // **bold**, `code`, # heading
                add(match.range, color, protect: true)
            }
            return spans
        }
        if language == .plain { return spans }
        if language == .dotenv { return dotenv(text) }
        // Strings first (comment markers inside them are ignored), then line comments.
        let strings = Self.string.matches(in: line, range: full).map(\.range)
        if let marker = language.lineComment {
            var search = NSRange(location: 0, length: full.length)
            while true {
                let found = text.range(of: marker, range: search)
                guard found.location != NSNotFound else { break }
                let insideString = strings.contains { NSLocationInRange(found.location, $0) }
                // "#" in CSS colors or PHP attributes is not a comment.
                let falsePositive = marker == "#" && found.location > 0 && text.character(at: found.location - 1) != 32 && text.character(at: found.location - 1) != 9
                if !insideString && !falsePositive && free(found) { add(NSRange(location: found.location, length: full.length - found.location), colors.comment, protect: true); break }
                search = NSRange(location: found.location + found.length, length: full.length - found.location - found.length)
            }
        }
        if language == .php && text.hasPrefix("#") && !text.hasPrefix("#[") { add(full, colors.comment, protect: true) }
        for range in strings { add(range, colors.string, protect: true) }
        if language == .blade { for match in Self.bladeDirective.matches(in: line, range: full) { add(match.range, colors.attribute, protect: true) } }
        if language.markup { for match in Self.tag.matches(in: line, range: full) { add(match.range, colors.tag, protect: true) } }
        if language == .css { for match in Self.cssProperty.matches(in: line, range: full) { add(match.range, colors.type, protect: true) } }
        if [.yaml, .toml, .json].contains(language) { for match in Self.yamlKey.matches(in: line, range: full) { add(match.range, colors.tag, protect: true) } }
        if [.php, .blade, .shell].contains(language) { for match in Self.variable.matches(in: line, range: full) { add(match.range, colors.variable, protect: true) } }
        for match in Self.attribute.matches(in: line, range: full) { add(match.range, colors.attribute, protect: true) }
        for match in Self.number.matches(in: line, range: full) { add(match.range, colors.number) }
        let caseInsensitive = language == .sql
        let typed = ![.json, .yaml, .toml, .sql, .shell].contains(language)
        for match in Self.word.matches(in: line, range: full) where free(match.range) {
            let word = text.substring(with: match.range)
            if keywords.contains(caseInsensitive ? word.lowercased() : word) { add(match.range, colors.keyword, protect: true) }
            else if typed, let first = word.unicodeScalars.first, CharacterSet.uppercaseLetters.contains(first), word.count > 1 { add(match.range, colors.type, protect: true) }
        }
        for match in Self.call.matches(in: line, range: full) { add(match.range, colors.function) }
        return spans
    }

    // MARK: .env

    private static let envReference = try! NSRegularExpression(pattern: #"\$\{[^}]*\}|\$[A-Za-z_][A-Za-z0-9_]*|\{(?:port|public):[^}]*\}"#)
    private static let envNumber = try! NSRegularExpression(pattern: #"^-?\d+(?:\.\d+)?$"#)
    private static let envConstants: Set<String> = ["true", "false", "null", "yes", "no", "on", "off", "(true)", "(false)", "(null)", "(empty)"]

    /// A `.env` line: the name, a dim `=`, and the value by what it is (quoted text, a number, a
    /// switch, an address, a hidden secret), with `${NAME}` and `{port:…}` references on top.
    private func dotenv(_ text: NSString) -> [(NSRange, NSColor)] {
        let length = text.length
        var start = 0
        while start < length, text.character(at: start) == 32 || text.character(at: start) == 9 { start += 1 }
        guard start < length else { return [] }
        if text.character(at: start) == 35 { return [(NSRange(location: start, length: length - start), colors.comment)] } // "#"
        let equals = text.range(of: "=")
        guard equals.location != NSNotFound, equals.location > start else { return [] }
        var spans: [(NSRange, NSColor)] = []
        var key = NSRange(location: start, length: equals.location - start)
        if text.substring(with: key).hasPrefix("export ") {
            spans.append((NSRange(location: start, length: 6), colors.keyword))
            key = NSRange(location: start + 7, length: key.length - 7)
        }
        spans.append((key, colors.tag))
        spans.append((equals, colors.comment))
        var value = NSRange(location: equals.location + 1, length: length - equals.location - 1)
        guard value.length > 0 else { return spans }
        let first = text.character(at: value.location)
        let quoted = first == 34 || first == 39 // " '
        if !quoted {
            // A trailing comment starts at " #".
            let hash = text.range(of: " #", range: value)
            if hash.location != NSNotFound {
                spans.append((NSRange(location: hash.location, length: length - hash.location), colors.comment))
                value.length = hash.location - value.location
            }
        }
        let content = text.substring(with: value).trimmingCharacters(in: .whitespaces)
        let color: NSColor? =
            quoted ? colors.string
            : content.allSatisfy({ $0 == "•" }) && !content.isEmpty ? colors.comment
            : Self.envConstants.contains(content.lowercased()) ? colors.keyword
            : Self.envNumber.firstMatch(in: content, range: NSRange(location: 0, length: (content as NSString).length)) != nil ? colors.number
            : content.contains("://") ? colors.function
            : colors.string
        if let color { spans.append((value, color)) }
        // Later spans win: a reference keeps its own color inside any value.
        for match in Self.envReference.matches(in: text as String, range: value) { spans.append((match.range, colors.variable)) }
        return spans
    }
}
