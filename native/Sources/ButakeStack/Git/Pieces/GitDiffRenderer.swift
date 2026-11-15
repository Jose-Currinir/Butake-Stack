import AppKit

/// Everything derived from a patch text, ready for the text view. Pure: it is computed off the main
/// thread for large patches (fonts and colors are captured on it first, in `Style`).
struct GitDiffPrepared: @unchecked Sendable {
    let lines: [GitDiffLine]
    let text: NSAttributedString
    /// Character range of each display line (contiguous and sorted).
    let ranges: [NSRange]
    /// Changed words inside modified lines, drawn with a stronger tint.
    let words: [(NSRange, GitDiffLine.Kind)]
    /// Length in UTF-16 units of the longest line.
    let longest: Int
    let hunkCount: Int
    /// Lines of the patch left out after `GitDiffRenderer.maxLines` (0 when it is whole).
    let omitted: Int
}

/// Builds the attributed diff: code without the +/− column (it lives in the gutter), syntax colors,
/// Git's header lines in plain Spanish and the changed part of each modified line.
enum GitDiffRenderer {
    /// Lines rendered at most; the rest is counted and named in a last line.
    static let maxLines = 200_000
    /// Longer lines (minified files) are cut for display: laying out megabyte-long lines blocks the
    /// main thread.
    static let maxLineLength = 4_000
    /// Above this size (UTF-8 bytes) a patch is prepared off the main thread.
    static let backgroundThreshold = 150_000

    /// Fonts and colors resolved on the main thread (theme and text size live there).
    struct Style: @unchecked Sendable {
        let font, hunkFont, annotationFont, metadataFont: NSFont
        let palette: GitDiffPalette
        let syntax: SyntaxColors

        @MainActor static var current: Style {
            Style(font: GitDiffRenderer.codeFont, hunkFont: .monospacedSystemFont(ofSize: TextScale.points(11), weight: .medium),
                  annotationFont: .systemFont(ofSize: TextScale.points(11.5), weight: .medium),
                  metadataFont: .systemFont(ofSize: TextScale.points(12.5), weight: .semibold), palette: .current, syntax: .current)
        }
    }

    static var codeFont: NSFont { .monospacedSystemFont(ofSize: TextScale.points(12), weight: .regular) }

    static func prepare(_ text: String, path: String?, style: Style) -> GitDiffPrepared {
        let (capped, omitted) = cap(text)
        let diff = GitUnifiedDiff(capped)
        let lines = clipped(diff.lines)
        let rendered = render(lines, path: path ?? firstPath(in: text), style: style, omitted: omitted)
        return GitDiffPrepared(lines: rendered.lines, text: rendered.text, ranges: rendered.ranges, words: rendered.words,
                               longest: rendered.lines.reduce(0) { max($0, $1.text.utf16.count) }, hunkCount: diff.hunkCount, omitted: omitted)
    }

    /// The first `maxLines` lines and how many were left out. Counted in UTF-8 bytes: "\r\n" is one
    /// Character, so counting Characters never counted CRLF lines.
    static func cap(_ text: String, limit: Int = maxLines) -> (String, Int) {
        var count = 0
        var cut: String.Index?
        let bytes = text.utf8
        var index = bytes.startIndex
        while index != bytes.endIndex {
            if bytes[index] == 0x0A { count += 1; if count == limit { cut = index; break } }
            index = bytes.index(after: index)
        }
        guard let cut else { return (text, 0) }
        let remaining = bytes[bytes.index(after: cut)...].reduce(0) { $1 == 0x0A ? $0 + 1 : $0 }
        return (String(text[..<cut]), remaining)
    }

    static func clipped(_ lines: [GitDiffLine]) -> [GitDiffLine] {
        lines.map { line in
            guard line.text.utf16.count > maxLineLength else { return line }
            var copy = line
            copy.text = String(line.text.prefix(maxLineLength)) + " …"
            return copy
        }
    }

    static func firstPath(in text: String) -> String? {
        for line in text.split(separator: "\n", maxSplits: 40, omittingEmptySubsequences: true).prefix(40) {
            if line.hasPrefix("+++ b/") { return String(line.dropFirst(6)) }
            if line.hasPrefix("diff --git "), let range = line.range(of: " b/", options: .backwards) { return String(line[range.upperBound...]) }
        }
        return nil
    }

    static func render(_ lines: [GitDiffLine], path: String?, style: Style, omitted: Int = 0)
        -> (lines: [GitDiffLine], text: NSAttributedString, ranges: [NSRange], words: [(NSRange, GitDiffLine.Kind)]) {
        var lines = lines
        if omitted > 0 { lines.append(GitDiffLine(text: "\\ " + String(format: L("git.diff.truncated"), omitted), kind: .annotation)) }
        let result = NSMutableAttributedString()
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3.5
        paragraph.lineBreakMode = .byClipping
        let base: [NSAttributedString.Key: Any] = [.font: style.font, .foregroundColor: style.palette.text, .paragraphStyle: paragraph]
        let secondary = style.palette.text.withAlphaComponent(0.62)
        var highlighter = SyntaxHighlighter(language: CodeLanguage.of(path), colors: style.syntax)
        var blockOld = false, blockNew = false
        var ranges: [NSRange] = []
        ranges.reserveCapacity(lines.count)
        var bodies: [String] = []
        bodies.reserveCapacity(lines.count)
        result.beginEditing()
        for line in lines {
            var body = line.text
            var attributes = base
            switch line.kind {
            case .addition, .deletion, .context:
                // Plain file content (an untracked file) has no marker column: context without an old number.
                if !body.isEmpty && (line.kind != .context || line.oldLine != nil) { body.removeFirst() }
            case .hunk:
                attributes[.foregroundColor] = secondary
                attributes[.font] = style.hunkFont
            case .annotation:
                body = friendly(body)
                attributes[.foregroundColor] = secondary
                attributes[.font] = style.annotationFont
            case .metadata:
                attributes[.font] = style.metadataFont
                // Multi-file output ("▸ path"): the language changes with each file.
                if line.fileHeader {
                    highlighter = SyntaxHighlighter(language: CodeLanguage.of(String(body.dropFirst(2))), colors: style.syntax)
                    blockOld = false; blockNew = false
                }
            }
            let start = result.length
            result.append(NSAttributedString(string: body + "\n", attributes: attributes))
            ranges.append(NSRange(location: start, length: (body as NSString).length + 1))
            bodies.append(body)
            if line.kind == .addition || line.kind == .deletion || line.kind == .context {
                // Old and new sides keep their own comment state: a removed "/*" does not tint added lines.
                var state = line.kind == .deletion ? blockOld : blockNew
                for (range, color) in highlighter.spans(body, inBlockComment: &state) {
                    result.addAttribute(.foregroundColor, value: color, range: NSRange(location: start + range.location, length: range.length))
                }
                if line.kind != .addition { blockOld = state }
                if line.kind != .deletion { blockNew = state }
            }
        }
        result.endEditing()
        return (lines, result, ranges, changedWords(lines, bodies: bodies, ranges: ranges))
    }

    /// Pairs each run of removed lines with the added lines after it and marks what differs between them.
    static func changedWords(_ lines: [GitDiffLine], bodies: [String], ranges: [NSRange]) -> [(NSRange, GitDiffLine.Kind)] {
        var words: [(NSRange, GitDiffLine.Kind)] = []
        var index = 0
        while index < lines.count {
            guard lines[index].kind == .deletion else { index += 1; continue }
            var removedEnd = index
            while removedEnd < lines.count, lines[removedEnd].kind == .deletion { removedEnd += 1 }
            var addedEnd = removedEnd
            while addedEnd < lines.count, lines[addedEnd].kind == .addition { addedEnd += 1 }
            let pairs = min(removedEnd - index, addedEnd - removedEnd)
            if pairs > 0 && pairs <= 40 {
                for offset in 0..<pairs {
                    let old = bodies[index + offset] as NSString, new = bodies[removedEnd + offset] as NSString
                    var prefix = 0
                    while prefix < old.length, prefix < new.length, old.character(at: prefix) == new.character(at: prefix) { prefix += 1 }
                    var suffix = 0
                    while suffix < old.length - prefix, suffix < new.length - prefix,
                          old.character(at: old.length - 1 - suffix) == new.character(at: new.length - 1 - suffix) { suffix += 1 }
                    let oldLength = old.length - prefix - suffix, newLength = new.length - prefix - suffix
                    // Only when the lines are mostly alike; otherwise the whole line already reads as changed.
                    guard prefix + suffix >= 3, Double(prefix + suffix) / Double(max(old.length, new.length, 1)) > 0.3 else { continue }
                    if oldLength > 0 { words.append((NSRange(location: ranges[index + offset].location + prefix, length: oldLength), .deletion)) }
                    if newLength > 0 { words.append((NSRange(location: ranges[removedEnd + offset].location + prefix, length: newLength), .addition)) }
                }
            }
            index = addedEnd
        }
        return words
    }

    /// Git's technical header lines in plain Spanish.
    static func friendly(_ line: String) -> String {
        if line.hasPrefix("new file mode") { return "＋ " + L("git.diff.newFile") }
        if line.hasPrefix("deleted file mode") { return "－ " + L("git.diff.deletedFile") }
        if line.hasPrefix("rename from ") { return "↳ " + String(format: L("git.diff.movedFrom"), String(line.dropFirst(12))) }
        if line.hasPrefix("rename to ") { return "↳ " + String(format: L("git.diff.movedTo"), String(line.dropFirst(10))) }
        if line.hasPrefix("similarity index ") { return String(format: L("git.diff.similarity"), String(line.dropFirst(17))) }
        if line.hasPrefix("Binary files") { return L("git.diff.binary") }
        if line.hasPrefix("\\ No newline") { return L("git.diff.noNewline") }
        if line.hasPrefix("\\ ") { return String(line.dropFirst(2)) }
        return line
    }

    /// Ranges of every occurrence of `query` in the rendered text (case and diacritics ignored).
    static func matches(of query: String, in text: NSString) -> [NSRange] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return [] }
        var found: [NSRange] = []
        var search = NSRange(location: 0, length: text.length)
        while search.length > 0 {
            let range = text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive], range: search)
            guard range.location != NSNotFound else { break }
            found.append(range)
            let next = range.location + max(range.length, 1)
            search = NSRange(location: next, length: text.length - next)
        }
        return found
    }
}

/// The display line of a character: `ranges` are contiguous and sorted, so it is a binary search.
func gitDiffLineIndex(for character: Int, in ranges: [NSRange]) -> Int? {
    var low = 0, high = ranges.count - 1
    while low <= high {
        let mid = (low + high) / 2, range = ranges[mid]
        if character < range.location { high = mid - 1 } else if character >= range.location + range.length { low = mid + 1 } else { return mid }
    }
    return nil
}
