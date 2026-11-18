import Foundation

/// One line of a diff as it is shown: its text, its numbers in the old and the new file and its kind.
struct GitDiffLine: Sendable, Equatable {
    enum Kind: Sendable { case metadata, hunk, addition, deletion, context, annotation }
    var text: String
    var oldLine: Int?
    var newLine: Int?
    /// Index of the block (`@@ … @@`) the line belongs to.
    var hunk: Int?
    var kind: Kind
    /// Index into `GitUnifiedDiff.files` of the file this line belongs to (multi-file output only).
    var file: Int?
    /// The "▸ path" line that opens a file's section of a multi-file output.
    var fileHeader = false

    init(text: String, oldLine: Int? = nil, newLine: Int? = nil, hunk: Int? = nil, kind: Kind, file: Int? = nil, fileHeader: Bool = false) {
        self.text = text; self.oldLine = oldLine; self.newLine = newLine; self.hunk = hunk; self.kind = kind; self.file = file; self.fileHeader = fileHeader
    }
}

/// One file of a multi-file patch: what happened to it and how many lines changed.
struct GitDiffFile: Equatable, Sendable {
    var path: String
    /// Previous path of a moved file.
    var originalPath: String?
    var kind: GitChangeKind = .modified
    var additions = 0
    var deletions = 0
    var binary = false

    init(path: String, originalPath: String? = nil, kind: GitChangeKind = .modified, additions: Int = 0, deletions: Int = 0, binary: Bool = false) {
        self.path = path; self.originalPath = originalPath; self.kind = kind; self.additions = additions; self.deletions = deletions; self.binary = binary
    }
}

/// A unified diff (`git diff`, `git show`, `git log -p`, a combined diff of a conflict) parsed into
/// display lines. Text that is not a patch (an untracked file) becomes numbered context lines.
struct GitUnifiedDiff: Sendable {
    var lines: [GitDiffLine] = []
    /// Files of the patch, in order (empty when the text is not a patch).
    var files: [GitDiffFile] = []
    /// Number of blocks (`@@ … @@`).
    var hunkCount = 0

    // Constant patterns (they always compile), shared by every parse.
    private static let hunkHeader = try! NSRegularExpression(pattern: #"^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@"#)
    private static let combinedHeader = try! NSRegularExpression(pattern: #"^@@@ -\d+(?:,\d+)? -\d+(?:,\d+)? \+(\d+)(?:,\d+)? @@@"#)

    init(_ text: String) {
        let raw = text.components(separatedBy: "\n")
        // A conflicted file comes as a combined diff (`diff --cc`, `@@@` blocks, two marker columns).
        let patch = text.hasPrefix("diff --git ") || text.hasPrefix("diff --cc ") || text.hasPrefix("diff --combined ") || raw.contains { $0.hasPrefix("@@ ") || $0.hasPrefix("@@@ ") }
        var old = 0, new = 0, hunk = -1
        var combined = false
        // `git show`/`log -p` output carries a preamble and several files; a single-file diff keeps its compact form.
        let preamble = patch && !text.hasPrefix("diff --git ")
        let fileHeaders = preamble || raw.lazy.filter { $0.hasPrefix("diff --git ") }.prefix(2).count > 1
        var inHeader = false
        var current: Int?
        lines.reserveCapacity(raw.count)
        for (index, line) in raw.enumerated() {
            // Every line appended in this iteration belongs to the file being read.
            let start = lines.count
            defer { if let current { for position in start..<lines.count where lines[position].file == nil { lines[position].file = current } } }
            // \u{1} marks a commit header (format "%x01…"): shown, and back to preamble mode so the next
            // commit's message and --stat lines are not read as diff content.
            if line.hasPrefix("\u{1}") {
                lines.append(GitDiffLine(text: String(line.dropFirst()), kind: .metadata))
                hunk = -1; inHeader = false; current = nil; continue
            }
            if patch && (line.hasPrefix("diff --cc ") || line.hasPrefix("diff --combined ")) {
                inHeader = true; combined = true
                files.append(GitDiffFile(path: String(line.dropFirst(line.hasPrefix("diff --cc ") ? 10 : 16)))); current = files.count - 1
                continue
            }
            if patch && line.hasPrefix("diff --git ") {
                inHeader = true; combined = false
                let path = line.range(of: " b/", options: .backwards).map { String(line[$0.upperBound...]) } ?? line
                let previous = current
                files.append(GitDiffFile(path: path)); current = files.count - 1
                if fileHeaders {
                    // A blank line closes the previous file so consecutive files do not run together.
                    if let previous, lines.last?.text.isEmpty == false { lines.append(GitDiffLine(text: "", kind: .annotation, file: previous)) }
                    lines.append(GitDiffLine(text: "▸ " + path, kind: .metadata, file: current, fileHeader: true))
                }
                continue
            }
            if line.hasPrefix("@@ "), let match = Self.hunkHeader.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
               let left = Range(match.range(at: 1), in: line), let right = Range(match.range(at: 2), in: line) {
                old = Int(line[left]) ?? 0; new = Int(line[right]) ?? 0; hunk += 1; hunkCount += 1; inHeader = false
                lines.append(GitDiffLine(text: line, hunk: hunk, kind: .hunk)); continue
            }
            if line.hasPrefix("@@@ "), let match = Self.combinedHeader.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
               let right = Range(match.range(at: 1), in: line) {
                new = Int(line[right]) ?? 0; hunk += 1; hunkCount += 1; inHeader = false; combined = true
                lines.append(GitDiffLine(text: line, hunk: hunk, kind: .hunk)); continue
            }
            if !patch { lines.append(GitDiffLine(text: line, newLine: index + 1, kind: .context)); continue }
            if inHeader {
                if let current {
                    if line.hasPrefix("new file") { files[current].kind = .added }
                    else if line.hasPrefix("deleted file") { files[current].kind = .deleted }
                    else if line.hasPrefix("rename from ") { files[current].kind = .moved; files[current].originalPath = String(line.dropFirst(12)) }
                    else if line.hasPrefix("rename ") { files[current].kind = .moved }
                    else if line.hasPrefix("Binary files") { files[current].binary = true }
                }
                if ["Binary files", "new file", "deleted file", "rename ", "similarity"].contains(where: line.hasPrefix) { lines.append(GitDiffLine(text: line, kind: .annotation)) }
                continue
            }
            if hunk < 0 { if preamble { lines.append(GitDiffLine(text: line, kind: .annotation)) }; continue }
            if line.hasPrefix("\\ ") { lines.append(GitDiffLine(text: line, hunk: hunk, kind: .annotation)); continue }
            if combined {
                // Two marker columns (one per parent): added in the result if any is "+", removed if any is "-".
                let markers = line.prefix(2)
                if markers.contains("+") { lines.append(GitDiffLine(text: line, newLine: new, hunk: hunk, kind: .addition)); new += 1; if let current { files[current].additions += 1 } }
                else if markers.contains("-") { lines.append(GitDiffLine(text: line, hunk: hunk, kind: .deletion)); if let current { files[current].deletions += 1 } }
                else if !line.isEmpty { lines.append(GitDiffLine(text: line, newLine: new, hunk: hunk, kind: .context)); new += 1 }
                continue
            }
            if line.hasPrefix("+") { lines.append(GitDiffLine(text: line, newLine: new, hunk: hunk, kind: .addition)); new += 1; if let current { files[current].additions += 1 } }
            else if line.hasPrefix("-") { lines.append(GitDiffLine(text: line, oldLine: old, hunk: hunk, kind: .deletion)); old += 1; if let current { files[current].deletions += 1 } }
            else if line.hasPrefix(" ") { lines.append(GitDiffLine(text: line, oldLine: old, newLine: new, hunk: hunk, kind: .context)); old += 1; new += 1 }
            else { lines.append(GitDiffLine(text: line, hunk: hunk, kind: .annotation)) }
        }
        if lines.isEmpty && !text.isEmpty { lines = [GitDiffLine(text: text, kind: .annotation)] }
    }

    /// Lines of a text counted on the line feed (CRLF files included: "\r\n" is one Character).
    static func lineCount(_ text: String) -> Int {
        text.utf8.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 } + (text.utf8.last == 0x0A || text.isEmpty ? 0 : 1)
    }
}

/// One block of a multi-file output: a note (commit header and message) or one file with its own patch.
struct GitDiffSection: Identifiable, Equatable, Sendable {
    var id: Int
    var note: String?
    var file: GitDiffFile?
    /// The file's patch, starting at its `diff --git` line.
    var patch = ""

    /// Whether the card has something to open: a file that was only moved shows just its header.
    var expandable: Bool { (file?.binary ?? false) || patch.range(of: "\n@@", options: .literal) != nil }

    /// Splits `git show` / `git diff` output at each file so every file can be shown, collapsed and
    /// scrolled to on its own. Empty when the text is not a patch.
    static func split(_ text: String) -> [GitDiffSection] {
        let files = GitUnifiedDiff(text).files
        guard !files.isEmpty else { return [] }
        var sections: [GitDiffSection] = []
        var buffer: [String] = []
        var next = 0
        var inFile = false
        func flush() {
            defer { buffer.removeAll(keepingCapacity: true) }
            if inFile, next < files.count {
                while buffer.last?.isEmpty == true { buffer.removeLast() }
                sections.append(GitDiffSection(id: sections.count, file: files[next], patch: buffer.joined(separator: "\n"))); next += 1
            } else if !inFile {
                let note = buffer.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !note.isEmpty { sections.append(GitDiffSection(id: sections.count, note: note)) }
            }
        }
        // `components(separatedBy:)`, not `split`: "\r\n" is one Character, so `split` kept a CRLF file
        // and the next file's `diff --git` line together.
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("\u{1}") { flush(); inFile = false; buffer.append(String(line.dropFirst())); continue }
            if line.hasPrefix("diff --git ") || line.hasPrefix("diff --cc ") || line.hasPrefix("diff --combined ") { flush(); inFile = true }
            buffer.append(line)
        }
        flush()
        return sections
    }
}
