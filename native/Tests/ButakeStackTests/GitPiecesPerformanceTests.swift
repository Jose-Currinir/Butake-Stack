import AppKit
import Foundation
import SwiftUI
import Testing
@testable import ButakeStack

// Simple performance checks of the Git pieces with made-up data: a diff of 20 000 lines and a tree of
// 2 000 paths. The limits are generous (debug build, a busy machine); the times are printed so they
// can be compared between versions.

/// Seconds a block takes.
@MainActor private func seconds(_ block: () -> Void) -> Double {
    let start = CFAbsoluteTimeGetCurrent()
    block()
    return CFAbsoluteTimeGetCurrent() - start
}

/// A made-up TypeScript patch of `lines` lines: blocks of context, removed and added lines.
private func largePatch(lines: Int) -> String {
    var text = "diff --git a/src/generado.ts b/src/generado.ts\n--- a/src/generado.ts\n+++ b/src/generado.ts\n"
    var written = 3
    var block = 0
    while written < lines {
        text += "@@ -\(block * 10 + 1),8 +\(block * 10 + 1),8 @@ export function bloque\(block)() {\n"
        text += " const valor\(block) = calcular(\(block));\n"
        text += "-  return valor\(block) * 2; // anterior\n"
        text += "+  return valor\(block) * 3; // nuevo\n"
        text += " /* comentario del bloque \(block) */\n"
        text += "-const nombre = \"producto \(block)\";\n"
        text += "+const nombre = \"producto \(block) actualizado\";\n"
        text += " export default valor\(block);\n"
        text += " \n"
        written += 9
        block += 1
    }
    return text
}

@MainActor @Test func gitDiffOf20000LinesStaysFluid() {
    let patch = largePatch(lines: 20_000)
    #expect(GitUnifiedDiff.lineCount(patch) >= 20_000)
    #expect(GitDiffView.oversize(patch) == nil)
    let style = GitDiffRenderer.Style.current
    var prepared: GitDiffPrepared?
    // Parsing and coloring: off the main thread in the app (the patch is over `backgroundThreshold`).
    #expect(patch.utf8.count > GitDiffRenderer.backgroundThreshold)
    let prepare = seconds { prepared = GitDiffRenderer.prepare(patch, path: nil, style: style) }
    guard let prepared else { Issue.record("not prepared"); return }
    // Every line but the three of the file header (diff --git, ---, +++).
    #expect(prepared.lines.count >= 19_990 && prepared.omitted == 0)
    #expect(prepared.hunkCount > 2_000)
    // Showing it: the text view takes the text and lays out only what is on screen.
    let scroll = GitDiffText.makeScrollView(embedded: false)
    scroll.frame = NSRect(x: 0, y: 0, width: 1_000, height: 700)
    let editor = try! #require(scroll.documentView as? GitDiffTextView)
    editor.onHunk = { _ in }
    let apply = seconds { GitDiffText.apply(prepared, to: editor, in: scroll, embedded: false, onHeight: nil, large: true) }
    // Drawing a screen at the top, after a jump to the middle and to the end (the text system lays out
    // up to there the first time), and then scrolling a screen at a time as the wheel does.
    let rep = try! #require(scroll.bitmapImageRepForCachingDisplay(in: scroll.bounds))
    func frame(at y: CGFloat) -> Double {
        seconds {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
            scroll.cacheDisplay(in: scroll.bounds, to: rep)
        }
    }
    let jumps = [0.0, 0.5, 0.98].map { frame(at: editor.frame.height * $0) }
    let middle = editor.frame.height * 0.5
    let steps = (1...20).map { frame(at: middle + CGFloat($0) * 40) }
    let frames = jumps + [steps.max() ?? 0]
    let search = seconds { editor.search("actualizado") }
    print(String(format: "Rendimiento diff 20 000 líneas: preparar %.0f ms · mostrar %.0f ms · saltos arriba/medio/final %@ ms · desplazar 40 pt (peor de 20) %.1f ms · buscar %.0f ms",
                 prepare * 1_000, apply * 1_000, jumps.map { String(format: "%.0f", $0 * 1_000) }.joined(separator: "/"), (steps.max() ?? 0) * 1_000, search * 1_000))
    #expect((steps.max() ?? 1) < 0.1)
    #expect(prepare < 8)
    #expect(apply < 3)
    #expect(frames.allSatisfy { $0 < 1.5 })
    #expect(search < 3)
}

@MainActor @Test func gitTreeOf2000PathsStaysFluid() {
    let folders = ["app/Http/Controllers", "app/Models", "app/Services/Pagos", "resources/views/carrito", "resources/js/componentes",
                   "src/carrito", "src/pago", "tests/Feature", "tests/Unit", "database/migrations"]
    let extensions = ["php", "ts", "vue", "blade.php", "json", "md", "swift", "py"]
    let kinds: [GitChangeKind] = [.modified, .added, .deleted, .moved, .modified]
    let changes = (0..<2_000).map { index in
        GitChange(path: "\(folders[index % folders.count])/sub\(index % 7)/archivo\(index).\(extensions[index % extensions.count])",
                  kind: kinds[index % kinds.count], stats: GitLineStats(additions: index % 13, deletions: index % 5),
                  inclusion: index % 3 == 0 ? .full : .none)
    }
    var nodes: [GitChangeNode] = []
    let build = seconds { nodes = GitChangeTree.build(changes) }
    var rows: [GitChangeTree.Row] = []
    let flatten = seconds { rows = GitChangeTree.flatten(nodes, collapsed: []) }
    #expect(rows.filter { !$0.node.isFolder }.count == 2_000)
    // What a full screen of rows computes for its checkboxes, and the header for all the files.
    let states = seconds {
        for row in rows.prefix(60) { _ = GitChangeTree.inclusion(of: row.node.changes) }
        _ = GitChangeTree.inclusion(of: changes)
    }
    // The icons of a screen of rows, loaded once and then taken from the cache.
    let icons = seconds { for row in rows.prefix(60) { _ = FileIconCatalog.shared.image(for: row.node.id, light: true) } }
    let iconsAgain = seconds { for row in rows.prefix(60) { _ = FileIconCatalog.shared.image(for: row.node.id, light: true) } }
    // The view itself in a window off screen: the list builds only the rows it shows.
    let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 420, height: 800), styleMask: [.titled], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    let host = NSHostingView(rootView: GitChangeTreeView(changes: changes, selection: .constant(changes[10].path), onInclude: { _, _ in }))
    window.contentView = host
    let render = seconds {
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        host.layoutSubtreeIfNeeded()
    }
    window.close()
    print(String(format: "Rendimiento árbol 2 000 rutas: construir %.1f ms · aplanar %.1f ms · casillas %.1f ms · íconos %.1f ms (caché %.2f ms) · vista %.0f ms",
                 build * 1_000, flatten * 1_000, states * 1_000, icons * 1_000, iconsAgain * 1_000, render * 1_000))
    #expect(build < 0.5)
    #expect(flatten < 0.1)
    #expect(states < 0.1)
    #expect(iconsAgain < icons + 0.001)
    #expect(render < 3)
}
