import AppKit
import ButakeDesign
import Foundation
import Testing
@testable import ButakeStack

// Diff parser, commit graph, change tree, file icons and colors of the Git pieces. Every path and
// commit here is made up.

// MARK: Diff

@Test func gitDiffUsesOldAndNewLineNumbers() {
    let diff = GitUnifiedDiff("diff --git a/a b/a\n--- a/a\n+++ b/a\n@@ -5,2 +7,2 @@\n-old\n+new\n same\n")
    #expect(diff.lines[0].kind == .hunk)
    #expect(diff.lines[1].oldLine == 5 && diff.lines[1].newLine == nil)
    #expect(diff.lines[2].newLine == 7 && diff.lines[2].oldLine == nil)
    #expect(diff.lines[3].oldLine == 6 && diff.lines[3].newLine == 8)
    #expect(!diff.lines.contains { $0.text.hasPrefix("+++") })
    #expect(diff.hunkCount == 1)
}

@Test func gitDiffKeepsFileHeadersOutOfTheChanges() {
    let diff = GitUnifiedDiff("abc123 feat: x\n\ndiff --git a/one b/one\nindex 1..2 100644\n--- a/one\n+++ b/one\n@@ -1 +1 @@\n-a\n+b\ndiff --git a/two b/two\n--- a/two\n+++ b/two\n@@ -3 +3 @@\n-c\n+d\n")
    #expect(diff.lines.filter { $0.kind == .metadata }.map(\.text) == ["▸ one", "▸ two"])
    #expect(diff.lines.filter { $0.kind == .deletion }.count == 2)
    #expect(diff.lines.filter { $0.kind == .addition }.count == 2)
    #expect(!diff.lines.contains { $0.text.hasPrefix("---") || $0.text.hasPrefix("+++") })
    #expect(diff.lines.first?.text == "abc123 feat: x")
    #expect(diff.files == [GitDiffFile(path: "one", additions: 1, deletions: 1), GitDiffFile(path: "two", additions: 1, deletions: 1)])
    #expect(diff.hunkCount == 2)
}

@Test func gitDiffFilesCarryTheirKindAndSplitIntoSections() {
    let diff = GitUnifiedDiff("abc feat: x\n\ndiff --git a/new.txt b/new.txt\nnew file mode 100644\n--- /dev/null\n+++ b/new.txt\n@@ -0,0 +1,2 @@\n+a\n+b\ndiff --git a/gone.txt b/gone.txt\ndeleted file mode 100644\n--- a/gone.txt\n+++ /dev/null\n@@ -1 +0,0 @@\n-x\ndiff --git a/old.txt b/moved.txt\nsimilarity index 100%\nrename from old.txt\nrename to moved.txt\ndiff --git a/img.png b/img.png\nBinary files a/img.png and b/img.png differ\n")
    #expect(diff.files.map(\.path) == ["new.txt", "gone.txt", "moved.txt", "img.png"])
    #expect(diff.files.map(\.kind) == [.added, .deleted, .moved, .modified])
    #expect(diff.files[0].additions == 2 && diff.files[1].deletions == 1 && diff.files[3].binary)
    #expect(diff.lines.filter(\.fileHeader).compactMap(\.file) == [0, 1, 2, 3])
    #expect(diff.files[2].originalPath == "old.txt")
    let sections = GitDiffSection.split("\u{1}abc feat: x\nQA · hoy\n\ncuerpo\n\ndiff --git a/new.txt b/new.txt\nnew file mode 100644\n@@ -0,0 +1 @@\n+a\ndiff --git a/two b/two\n@@ -1 +1 @@\n-c\n+d\n")
    #expect(sections.map(\.id) == [0, 1, 2])
    #expect(sections[0].note == "abc feat: x\nQA · hoy\n\ncuerpo")
    #expect(sections[1].file?.kind == .added && sections[1].patch.hasPrefix("diff --git a/new.txt") && !sections[1].patch.contains("two"))
    #expect(sections[2].file == GitDiffFile(path: "two", additions: 1, deletions: 1))
    #expect(sections[1].expandable && !GitDiffSection(id: 0, file: GitDiffFile(path: "a", kind: .moved), patch: "diff --git a/b b/a\nrename from b").expandable)
    #expect(GitDiffSection.split("fatal: bad revision").isEmpty)
}

@Test func gitDiffCommitHeaderResetsThePreamble() {
    let diff = GitUnifiedDiff("\u{1}aaa feat: a\n\n---\n a.txt | 1 +\n\ndiff --git a/a.txt b/a.txt\n@@ -0,0 +1 @@\n+a\n\u{1}bbb feat: b\n\n---\n b.txt | 1 +\n\ndiff --git a/b.txt b/b.txt\n@@ -0,0 +1 @@\n+b\n")
    #expect(diff.lines.filter { $0.kind == .addition }.count == 2)
    #expect(diff.lines.filter { $0.kind == .deletion }.isEmpty)
    #expect(diff.lines.contains { $0.kind == .metadata && $0.text == "bbb feat: b" })
}

@Test func gitDiffShowsPlainTextAndCombinedConflicts() {
    #expect(GitUnifiedDiff("hello\nworld").lines[1].newLine == 2)
    #expect(!GitUnifiedDiff("diff --git a/a b/a\nBinary files differ\n").lines.isEmpty)
    let conflict = GitUnifiedDiff("diff --cc file.txt\nindex 1,2..0\n--- a/file.txt\n+++ b/file.txt\n@@@ -1,1 -1,1 +1,5 @@@\n++<<<<<<< HEAD\n +ours\n++=======\n+ theirs\n++>>>>>>> other\n")
    #expect(conflict.files.map(\.path) == ["file.txt"])
    #expect(conflict.lines.first?.kind == .hunk)
    #expect(conflict.lines.filter { $0.kind == .addition }.count == 5)
    #expect(conflict.lines.last?.newLine == 5)
}

@Test func gitDiffCRLFFilesKeepSectionsAndCountsAligned() {
    // "\r\n" is one Character: splitting by Character merged a CRLF file with the next one.
    let patch = "diff --git a/win.txt b/win.txt\n@@ -1,2 +1,2 @@\n-old\r\n+new\r\n same\r\ndiff --git a/unix.txt b/unix.txt\n@@ -1 +1 @@\n-c\n+d\n"
    let sections = GitDiffSection.split(patch)
    #expect(sections.count == 2)
    #expect(sections[0].file?.path == "win.txt" && !sections[0].patch.contains("unix.txt"))
    #expect(sections[1].file == GitDiffFile(path: "unix.txt", additions: 1, deletions: 1))
    let (capped, omitted) = GitDiffRenderer.cap(String(repeating: "x\r\n", count: 150), limit: 100)
    #expect(omitted == 50 && GitUnifiedDiff.lineCount(capped) == 99 + 1)
    let long = GitDiffLine(text: String(repeating: "a", count: GitDiffRenderer.maxLineLength + 500), newLine: 1, hunk: 0, kind: .addition)
    #expect(GitDiffRenderer.clipped([long])[0].text.count == GitDiffRenderer.maxLineLength + 2)
    #expect(GitUnifiedDiff.lineCount("a\nb") == 2 && GitUnifiedDiff.lineCount("a\nb\n") == 2 && GitUnifiedDiff.lineCount("") == 0)
}

@MainActor @Test func gitDiffRendererMarksChangedWordsAndSearches() {
    let lines = GitUnifiedDiff("diff --git a/a.ts b/a.ts\n@@ -1,2 +1,2 @@\n-const total = neto * 1.19;\n+const total = (neto - descuento) * 1.19;\n context\n").lines
    let rendered = GitDiffRenderer.render(lines, path: "a.ts", style: .current)
    // The +/− column is not part of the text; the changed middle of the line is marked on both sides.
    #expect(!rendered.text.string.contains("-const") && !rendered.text.string.contains("+const"))
    #expect(rendered.words.map(\.1) == [.deletion, .addition])
    let added = (rendered.text.string as NSString).substring(with: rendered.words[1].0)
    #expect(added.contains("descuento"))
    #expect(GitDiffRenderer.matches(of: "TOTAL", in: rendered.text.string as NSString).count == 2)
    #expect(GitDiffRenderer.matches(of: " ", in: "abc").isEmpty)
    #expect(GitDiffRenderer.friendly("rename from a/b.txt") == "↳ " + String(format: L("git.diff.movedFrom"), "a/b.txt"))
    let ranges = (0..<1000).map { NSRange(location: $0 * 10, length: 10) }
    #expect(gitDiffLineIndex(for: 0, in: ranges) == 0)
    #expect(gitDiffLineIndex(for: 9_995, in: ranges) == 999)
    #expect(gitDiffLineIndex(for: 4_321, in: ranges) == 432)
    #expect(gitDiffLineIndex(for: 10_000, in: ranges) == nil)
}

@MainActor @Test func gitDiffViewSendsLargePatchesBehindAButton() {
    #expect(GitDiffView.oversize(String(repeating: "+a\n", count: 20_000)) == nil)
    #expect(GitDiffView.oversize(String(repeating: "+a\n", count: GitDiffView.largeLineLimit + 1)) == GitDiffView.largeLineLimit + 1)
}

@Test func gitSyntaxHighlighterFollowsBlockComments() {
    let colors = SyntaxColors(theme: .butakeLight)
    let highlighter = SyntaxHighlighter(language: CodeLanguage.of("src/a.ts"), colors: colors)
    var inComment = false
    #expect(highlighter.spans("let a = 1; /* abre", inBlockComment: &inComment).contains { $0.1 == colors.comment })
    #expect(inComment)
    let closing = highlighter.spans("cierra */ return a", inBlockComment: &inComment)
    #expect(!inComment && closing.contains { $0.1 == colors.keyword })
    #expect(CodeLanguage.of("views/home.blade.php") == .blade)
    #expect(CodeLanguage.of(".env.local") == .dotenv)
    let env = SyntaxHighlighter(language: .dotenv, colors: colors)
    var none = false
    let line = env.spans("APP_URL=http://tienda.test:{port:tienda}", inBlockComment: &none)
    #expect(line.first?.0 == NSRange(location: 0, length: 7) && line.first?.1 == colors.tag)
    #expect(line.contains { $0.1 == colors.function } && line.last?.1 == colors.variable)
    #expect(env.spans("APP_DEBUG=true", inBlockComment: &none).last?.1 == colors.keyword)
    #expect(env.spans("DB_PORT=3306", inBlockComment: &none).last?.1 == colors.number)
    #expect(env.spans("# nota", inBlockComment: &none).first?.1 == colors.comment)
    #expect(CodeLanguage.of(nil) == .plain)
}

// MARK: Changes

@Test func gitChangeKindsFromStatusCodes() {
    #expect(GitChangeKind.status(index: "?", worktree: "?") == .added)
    #expect(GitChangeKind.status(index: "A", worktree: " ") == .added)
    #expect(GitChangeKind.status(index: " ", worktree: "D") == .deleted)
    #expect(GitChangeKind.status(index: "R", worktree: " ") == .moved)
    #expect(GitChangeKind.status(index: "M", worktree: "M") == .modified)
    #expect(GitChangeKind.status(index: "U", worktree: "U") == .conflict)
    #expect(GitChangeKind.status(index: "A", worktree: "A") == .conflict)
    #expect(GitChangeKind.nameStatus("R100") == .moved && GitChangeKind.nameStatus("A") == .added)
    let stats = GitLineStats.parseNumstat("3\t1\tsrc/a b.swift\0-\t-\timg.png\0")
    #expect(stats.count == 2 && stats[0].path == "src/a b.swift" && stats[0].stats.additions == 3 && stats[0].stats.deletions == 1)
    #expect(stats[1].stats.binary)
}

@Test func gitChangeTreeCompactsFoldersAndCounts() {
    let files = ["app/Http/Controllers/A.php", "app/Http/Controllers/B.php", "app/Models/User.php", "README.md"].map {
        GitChange(path: $0, stats: GitLineStats(additions: 2, deletions: 1))
    }
    let tree = GitChangeTree.build(files)
    #expect(tree.map(\.name) == ["app", "README.md"])
    let app = tree[0]
    #expect(app.changes.count == 3 && app.additions == 6 && app.deletions == 3)
    #expect(app.children?.map(\.name) == ["Http/Controllers", "Models"])
    #expect(app.children?.first?.children?.map(\.name) == ["A.php", "B.php"])
    #expect(GitChangeTree.flatten(tree, collapsed: []).count == 7)
    #expect(GitChangeTree.flatten(tree, collapsed: ["app/"]).map(\.id) == ["app/", "README.md"])
    #expect(GitChangeTree.folderIDs(tree) == ["app/", "app/Http/Controllers/", "app/Models/"])
}

@Test func gitChangeTreeInclusionCountsPendingClicksAndSkipsConflicts() {
    let full = GitChange(path: "a", inclusion: .full), none = GitChange(path: "b"), conflict = GitChange(path: "c", kind: .conflict)
    #expect(GitChangeTree.inclusion(of: [full, conflict]) == .full)
    #expect(GitChangeTree.inclusion(of: [full, none]) == .partial)
    #expect(GitChangeTree.inclusion(of: [none]) == .none)
    #expect(GitChangeTree.inclusion(of: [GitChange(path: "p", inclusion: .partial)]) == .partial)
    #expect(GitChangeTree.inclusion(of: [full, none], pending: ["b": true]) == .full)
    #expect(GitChangeTree.inclusion(of: [full, none], pending: ["a": false]) == .none)
    #expect(GitChangeTree.inclusion(of: [conflict]) == .none)
}

// MARK: Commit graph

@Test func gitGraphKeepsForkAndMergeLinesAndBranchLabels() {
    let graph = GitCommitGraph(commits: [GitGraphCommit(hash: "merge", parents: ["left", "right"]), GitGraphCommit(hash: "left", parents: ["base"]),
                                         GitGraphCommit(hash: "right", parents: ["base"]), GitGraphCommit(hash: "base", parents: [])])
    #expect(graph.width == 2)
    #expect(graph.rows[0].outgoing.count == 2)
    #expect(graph.rows[2].outgoing.contains { $0.startsAtNode && $0.from == 1 && $0.to == 0 })
    #expect(graph.rows[3].outgoing.isEmpty)
    let refs = GitCommitReference.parse("HEAD -> develop, origin/develop, feature/x, tag: v1.0", localBranches: ["develop", "feature/x"])
    #expect(refs.map(\.kind) == [.head, .remote, .branch, .tag])
    #expect(refs.last?.name == "v1.0")
    let labels = GitCommitGraph.branchLabels([GitGraphCommit(hash: "merge", parents: ["left", "right"], refs: "HEAD -> develop"), GitGraphCommit(hash: "left", parents: ["base"]),
                                              GitGraphCommit(hash: "right", parents: ["base"], refs: "feature"), GitGraphCommit(hash: "base", parents: [])],
                                             localBranches: ["develop", "feature"])
    #expect(labels["left"] == "develop" && labels["base"] == "develop" && labels["right"] == "feature")
    // A filtered history drops parents that are not listed instead of keeping their lanes open.
    let filtered = GitCommitGraph(commits: (0..<50).map { GitGraphCommit(hash: "c\($0)", parents: ["missing\($0)"]) }, pruneMissingParents: true)
    #expect(filtered.width == 1)
}

// MARK: Icons and colors

@MainActor @Test func gitFileIconsMapNamesAndLoadLazily() {
    let icons = FileIconCatalog.shared
    #expect(icons.iconName(for: "resources/views/welcome.blade.php", light: false) == "laravel")
    #expect(icons.iconName(for: "src/pages/index.astro", light: false) == "astro")
    #expect(icons.iconName(for: "scripts/run.py", light: false) == "python")
    #expect(icons.iconName(for: "README.md", light: false) == "readme")
    #expect(icons.iconName(for: ".env", light: false) == "tune")
    #expect(icons.iconName(for: "sin-extension-rara", light: false) == "file")
    #expect(icons.iconName(for: "", light: false) == "file")
    let before = icons.loadedCount
    #expect(icons.image(for: "app/Http/Kernel.php", light: false) != nil)
    #expect(icons.image(for: "otra/Clase.php", light: false) != nil)
    #expect(icons.loadedCount <= before + 1)
    #expect(!icons.typeName(for: "a.swift").isEmpty)
    // Every icon the map names is bundled.
    let folder = try? #require(Bundle.module.url(forResource: "map", withExtension: "json", subdirectory: "FileIcons")?.deletingLastPathComponent())
    let names = (try? FileManager.default.contentsOfDirectory(atPath: folder?.path ?? "")) ?? []
    #expect(names.filter { $0.hasSuffix(".svg") }.count > 600)
    #expect(names.contains("LICENSE-material-icon-theme.txt"))
}

@MainActor @Test func gitColorsReadWithAAContrastInEveryTheme() {
    for theme in [Theme.butakeLight, .butakeDark, .draculaLight, .draculaDark] {
        let palette = GitDiffPalette(theme: theme)
        let surface = palette.surface
        for (name, color) in [("addition", palette.addition), ("deletion", palette.deletion), ("modified", palette.modified), ("moved", palette.moved), ("warning", palette.warning)] {
            #expect(GitDiffPalette.contrast(color, surface) >= GitDiffPalette.minimumContrast, "\(theme.name) \(name) on the surface")
        }
        #expect(GitDiffPalette.contrast(palette.addition, GitDiffPalette.blend(palette.additionRow, over: surface)) >= GitDiffPalette.minimumContrast, "\(theme.name) + mark")
        #expect(GitDiffPalette.contrast(palette.deletion, GitDiffPalette.blend(palette.deletionRow, over: surface)) >= GitDiffPalette.minimumContrast, "\(theme.name) − mark")
        #expect(GitDiffPalette.contrast(palette.text, GitDiffPalette.blend(palette.addedWord, over: surface)) >= GitDiffPalette.minimumContrast, "\(theme.name) text on a changed word")
    }
    #expect(abs(GitDiffPalette.contrast(.black, .white) - 21) < 0.01)
}

/// Every text the pieces show exists, the dynamic ones (kinds of change) included.
@Test func gitPiecesHaveEveryText() throws {
    var keys = GitChangeKind.allCases.map { "git.kind.\($0.rawValue)" }
    let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Sources/ButakeStack").standardized
    // The Git pieces and the shared code pieces they use (editor, file icons).
    for folder in [sources.appendingPathComponent("Git/Pieces"), sources.appendingPathComponent("Shared/Code")] {
    for file in try FileManager.default.contentsOfDirectory(atPath: folder.path) where file.hasSuffix(".swift") {
        let source = try String(contentsOf: folder.appendingPathComponent(file), encoding: .utf8)
        let pattern = try NSRegularExpression(pattern: #""(git\.(?:kind|diff|tree|editor|icon)\.[A-Za-z]+)""#)
        for match in pattern.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
            if let range = Range(match.range(at: 1), in: source) { keys.append(String(source[range])) }
        }
    }
    }
    // Accessibility identifiers written the same way; they are not texts.
    let identifiers: Set<String> = ["git.diff.text", "git.diff.image", "git.diff.sections", "git.diff.tooLarge", "git.diff.unchanged",
                                    "git.editor.text", "git.tree.list"]
    let missing = Set(keys).subtracting(identifiers).filter { localized($0) == nil }
    #expect(missing.isEmpty, "Missing texts: \(missing.sorted().joined(separator: ", "))")
}
