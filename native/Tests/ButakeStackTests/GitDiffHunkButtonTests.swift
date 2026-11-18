import AppKit
import Foundation
import Testing
@testable import ButakeStack

// «Preparar bloque» on a block header of a diff with long lines. The button used to follow the
// visible edge: scrolling sideways, AppKit moved what was already drawn and only drew the new strip,
// so copies of the button piled up along the header. It now stays with the text.

@MainActor @Test func theBlockButtonStaysWithTheTextWhenTheDiffScrollsSideways() throws {
    let long = String(repeating: "una línea larga de una tabla en markdown | ", count: 30)
    let patch = """
    diff --git a/plan.md b/plan.md
    --- a/plan.md
    +++ b/plan.md
    @@ -1,3 +1,3 @@ ## Plan
     contexto
    -\(long)antes
    +\(long)después
    """ + "\n"
    let scroll = GitDiffText.makeScrollView(embedded: false)
    scroll.frame = NSRect(x: 0, y: 0, width: 700, height: 300)
    let editor = try #require(scroll.documentView as? GitDiffTextView)
    var staged: [Int] = []
    editor.onHunk = { staged.append($0) }
    GitDiffText.apply(GitDiffRenderer.prepare(patch, path: "plan.md", style: .current), to: editor, in: scroll, embedded: false, onHeight: nil, large: false)
    scroll.tile()
    #expect(editor.frame.width > scroll.contentSize.width * 2)

    let atStart = editor.hunkButtonFrames(in: editor.bounds)
    let button = try #require(atStart.first)
    #expect(atStart.count == 1 && button.hunk == 0)
    // At the trailing edge of what the window shows, as before.
    #expect(button.rect.maxX <= scroll.contentSize.width && button.rect.maxX > scroll.contentSize.width - 40)

    // Scrolled sideways: the same place in the text, whatever is visible.
    scroll.contentView.scroll(to: NSPoint(x: 900, y: 0))
    scroll.reflectScrolledClipView(scroll.contentView)
    #expect(editor.visibleRect.minX > 800)
    #expect(editor.hunkButtonFrames(in: editor.visibleRect).map(\.rect) == [button.rect])
    #expect(!editor.visibleRect.intersects(button.rect))

    // What it looks like, at the start and scrolled (for the visual check of the change).
    if let folder = ProcessInfo.processInfo.environment["BUTAKE_QA_CAPTURES"] {
        for (name, x) in [("diff-inicio", 0.0), ("diff-desplazado", 900.0)] {
            GitDiffText.apply(GitDiffRenderer.prepare(patch, path: "plan.md", style: .current), to: editor, in: scroll, embedded: false, onHeight: nil, large: false)
            scroll.contentView.scroll(to: NSPoint(x: x, y: 0))
            scroll.reflectScrolledClipView(scroll.contentView)
            let rep = try #require(scroll.bitmapImageRepForCachingDisplay(in: scroll.bounds))
            scroll.cacheDisplay(in: scroll.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
        }
    }
    #expect(staged.isEmpty)
}
