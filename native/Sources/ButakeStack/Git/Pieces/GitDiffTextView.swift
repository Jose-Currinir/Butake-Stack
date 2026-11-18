import AppKit
import SwiftUI

/// Scroll view of a diff. Embedded in an outer scroll view (one file of a multi-file diff) it only
/// scrolls sideways and hands vertical wheel events to the enclosing view, so the page scrolls wherever
/// the pointer is.
final class GitDiffScrollView: NSScrollView {
    var embedded = false
    override func scrollWheel(with event: NSEvent) {
        if embedded && abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX) { nextResponder?.scrollWheel(with: event) } else { super.scrollWheel(with: event) }
    }
    private var tiledWidth: CGFloat = 0
    /// The text is never narrower than the visible area, so row tints reach the right edge.
    override func tile() {
        super.tile()
        if let document = documentView, document.frame.width < contentSize.width {
            document.setFrameSize(NSSize(width: contentSize.width, height: document.frame.height))
        }
        // The block buttons sit at the edge of this width: a new width moves them, so all is redrawn.
        if abs(contentSize.width - tiledWidth) > 0.5 {
            tiledWidth = contentSize.width
            documentView?.needsDisplay = true
        }
    }
}

/// Read-only text of a diff: row tints, changed words, search matches and a «Preparar bloque» button
/// on each block header. Lines never wrap; the gutter (`GitDiffLineRuler`) draws the numbers.
final class GitDiffTextView: NSTextView, @preconcurrency NSLayoutManagerDelegate {
    override var wantsDefaultClipping: Bool { true }
    var palette: GitDiffPalette = .current
    var hunkTitle = L("git.diff.stageHunk")
    var source: String?
    /// Identifies the text being prepared: a background result for an older text is dropped.
    var renderGeneration = 0
    /// A large patch shown with an estimated height takes the real one once the layout finishes.
    var fitsHeightWhenLaidOut = false
    var themeSignature = 0
    var displayLines: [GitDiffLine] = []
    var lineRanges: [NSRange] = []
    var wordRanges: [(NSRange, GitDiffLine.Kind)] = []
    var hunkCount = 0
    var onHunk: ((Int) -> Void)? { didSet { if (oldValue == nil) != (onHunk == nil) { updateAccessibilityActions(); needsDisplay = true } } }
    /// Search: the text it looks for and the ranges found.
    private(set) var query = ""
    private var matches: [NSRange] = []


    // MARK: Layout

    func layoutManager(_ layoutManager: NSLayoutManager, didCompleteLayoutFor textContainer: NSTextContainer?, atEnd layoutFinishedFlag: Bool) {
        guard fitsHeightWhenLaidOut, layoutFinishedFlag, let textContainer, let scroll = enclosingScrollView else { return }
        let height = max(scroll.contentSize.height, layoutManager.usedRect(for: textContainer).height + 28)
        guard abs(height - frame.height) > 0.5 else { return }
        // Not from inside the layout pass that reported it.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.fitsHeightWhenLaidOut else { return }
            self.setFrameSize(NSSize(width: self.frame.width, height: height))
            scroll.reflectScrolledClipView(scroll.contentView)
            self.needsDisplay = true
            scroll.verticalRulerView?.needsDisplay = true
        }
    }

    /// The display line under a character.
    func displayLine(at character: Int) -> GitDiffLine? {
        gitDiffLineIndex(for: character, in: lineRanges).flatMap { displayLines.indices.contains($0) ? displayLines[$0] : nil }
    }

    // MARK: Drawing

    static func background(_ line: GitDiffLine, palette: GitDiffPalette) -> NSColor? {
        if line.fileHeader { return palette.fileHeaderRow }
        switch line.kind {
        case .addition: return palette.additionRow
        case .deletion: return palette.deletionRow
        case .hunk: return palette.hunkRow
        case .metadata: return palette.metadataRow
        default: return nil
        }
    }

    override func drawBackground(in rect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: bounds).addClip()
        super.drawBackground(in: rect)
        guard let layoutManager, let textContainer else { return }
        // What AppKit asks for, which can lie outside the visible area (it draws ahead when scrolling).
        let range = layoutManager.glyphRange(forBoundingRect: rect.union(visibleRect), in: textContainer)
        layoutManager.enumerateLineFragments(forGlyphRange: range) { [self] lineRect, _, _, glyphs, _ in
            let character = layoutManager.characterIndexForGlyph(at: glyphs.location)
            guard let line = displayLine(at: character), let color = Self.background(line, palette: palette) else { return }
            let row = NSRect(x: 0, y: lineRect.minY + textContainerInset.height, width: bounds.width, height: lineRect.height)
            color.setFill(); row.fill()
            if line.fileHeader { NSColor.separatorColor.setFill(); NSRect(x: 0, y: row.minY, width: row.width, height: 1).fill() }
        }
        let visibleCharacters = layoutManager.characterRange(forGlyphRange: range, actualGlyphRange: nil)
        for (word, kind) in wordRanges where NSIntersectionRange(word, visibleCharacters).length > 0 {
            let glyphs = layoutManager.glyphRange(forCharacterRange: word, actualCharacterRange: nil)
            layoutManager.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: textContainer) { rect, _ in
                (kind == .addition ? self.palette.addedWord : self.palette.removedWord).setFill()
                NSBezierPath(roundedRect: rect.offsetBy(dx: self.textContainerInset.width, dy: self.textContainerInset.height).insetBy(dx: -1, dy: 1), xRadius: 3, yRadius: 3).fill()
            }
        }
        // With the background: the glyphs are drawn after this pass, and block headers are short.
        drawHunkButtons(in: rect.union(visibleRect))
    }

    private var hunkFont: NSFont { NSFont.systemFont(ofSize: TextScale.points(11), weight: .medium) }
    /// The Mac's accent, or the theme's when it brings its own.
    private var hunkAccent: NSColor { NSColor(Brand.accent) }
    private var hunkSymbol: NSImage? {
        NSImage(systemSymbolName: Symbols.stageHunk, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: hunkFont.pointSize, weight: .medium).applying(.init(paletteColors: [hunkAccent])))
    }

    /// Where the «Preparar bloque» buttons of the block headers in `area` go, in view coordinates.
    /// Fixed to the text, never to the visible area: AppKit moves what is already drawn when the view
    /// scrolls sideways, so a button that followed the visible edge left copies of itself behind. It
    /// sits at the edge of the unscrolled width (as wide as the window shows) and scrolls with the
    /// text; the block's context menu and its accessibility action reach it from anywhere.
    func hunkButtonFrames(in area: NSRect) -> [(rect: NSRect, hunk: Int)] {
        guard onHunk != nil, let layoutManager, let textContainer else { return [] }
        let titleSize = (hunkTitle as NSString).size(withAttributes: [.font: hunkFont])
        let width = titleSize.width + (hunkSymbol.map { $0.size.width + 4 } ?? 0) + 16
        let edge = enclosingScrollView?.contentSize.width ?? visibleRect.width
        var frames: [(rect: NSRect, hunk: Int)] = []
        let range = layoutManager.glyphRange(forBoundingRect: area, in: textContainer)
        layoutManager.enumerateLineFragments(forGlyphRange: range) { [self] lineRect, _, _, glyphs, _ in
            let character = layoutManager.characterIndexForGlyph(at: glyphs.location)
            guard let line = displayLine(at: character), line.kind == .hunk, let hunk = line.hunk else { return }
            let height = min(lineRect.height - 2, titleSize.height + 4)
            frames.append((NSRect(x: edge - width - 10, y: lineRect.minY + textContainerInset.height + (lineRect.height - height) / 2, width: width, height: height), hunk))
        }
        return frames
    }

    /// «Preparar bloque» on every block header, always shown.
    private func drawHunkButtons(in area: NSRect) {
        let frames = hunkButtonFrames(in: area)
        guard !frames.isEmpty else { return }
        let font = hunkFont, accent = hunkAccent, symbol = hunkSymbol
        let title = hunkTitle as NSString
        let titleSize = title.size(withAttributes: [.font: font])
        for (button, _) in frames {
            let shape = NSBezierPath(roundedRect: button, xRadius: button.height / 2, yRadius: button.height / 2)
            palette.surface.setFill(); shape.fill()
            accent.withAlphaComponent(0.6).setStroke(); shape.lineWidth = 1; shape.stroke()
            var x = button.minX + 8
            if let symbol {
                symbol.draw(in: NSRect(x: x, y: button.midY - symbol.size.height / 2, width: symbol.size.width, height: symbol.size.height))
                x += symbol.size.width + 4
            }
            title.draw(at: NSPoint(x: x, y: button.midY - titleSize.height / 2), withAttributes: [.font: font, .foregroundColor: accent])
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        // Worked out again here, not taken from the last drawing: AppKit often redraws only a part.
        let row = NSRect(x: 0, y: point.y - 1, width: bounds.width, height: 2)
        if let hit = hunkButtonFrames(in: row).first(where: { $0.rect.contains(point) }) { onHunk?(hit.hunk); return }
        super.mouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        guard onHunk != nil, let manager = layoutManager, let container = textContainer else { return menu }
        let point = convert(event.locationInWindow, from: nil)
        let glyph = manager.glyphIndex(for: NSPoint(x: point.x - textContainerInset.width, y: point.y - textContainerInset.height), in: container)
        guard glyph < manager.numberOfGlyphs, let hunk = displayLine(at: manager.characterIndexForGlyph(at: glyph))?.hunk else { return menu }
        menu.addItem(.separator())
        let item = NSMenuItem(title: hunkTitle, action: #selector(applyHunk(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = hunk
        item.image = NSImage(systemSymbolName: Symbols.stageHunk, accessibilityDescription: nil)
        menu.addItem(item)
        return menu
    }

    @objc private func applyHunk(_ sender: NSMenuItem) { if let index = sender.representedObject as? Int { onHunk?(index) } }

    // MARK: Accessibility

    /// One action per block for assistive clients and agents: «Preparar bloque 2».
    func updateAccessibilityActions() {
        guard onHunk != nil, hunkCount > 0 else { setAccessibilityCustomActions(nil); return }
        setAccessibilityCustomActions((0..<min(hunkCount, 200)).map { index in
            NSAccessibilityCustomAction(name: String(format: L("git.diff.stageHunkNumber"), index + 1), target: self, selector: #selector(performHunkAction(_:)))
        })
    }

    @objc private func performHunkAction(_ action: NSAccessibilityCustomAction) -> Bool {
        guard let index = accessibilityCustomActions()?.firstIndex(where: { $0 === action }) else { return false }
        onHunk?(index)
        return true
    }

    // MARK: Search

    /// Marks every occurrence of `text` and brings the first one into view.
    func search(_ text: String) {
        guard text != query else { return }
        query = text
        guard let manager = layoutManager, let storage = textStorage else { return }
        let whole = NSRange(location: 0, length: storage.length)
        manager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: whole)
        manager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: whole)
        matches = Array(GitDiffRenderer.matches(of: text, in: storage.string as NSString).prefix(5_000))
        // The system's find yellow with black text: syntax colors would not read on it in dark mode.
        for range in matches {
            manager.addTemporaryAttributes([.backgroundColor: NSColor.findHighlightColor, .foregroundColor: NSColor.black], forCharacterRange: range)
        }
        if let first = matches.first {
            scrollRangeToVisible(first)
            showFindIndicator(for: first)
        }
    }

    /// Re-applies the search to a new text.
    func refreshSearch() {
        let current = query
        query = ""
        matches = []
        if !current.isEmpty { search(current) }
    }
}

/// Gutter of a diff: old and new line numbers, the +/− mark and the colored edge of changed lines.
final class GitDiffLineRuler: NSRulerView {
    override var isFlipped: Bool { true }
    override var wantsDefaultClipping: Bool { true }

    override init(scrollView: NSScrollView?, orientation: NSRulerView.Orientation) {
        super.init(scrollView: scrollView, orientation: orientation)
        ruleThickness = TextScale.points(92)
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: bounds).addClip()
        guard let editor = clientView as? GitDiffTextView, let manager = editor.layoutManager, let container = editor.textContainer else { return }
        let palette = editor.palette
        palette.surface.setFill(); rect.intersection(bounds).fill()
        let range = manager.glyphRange(forBoundingRect: editor.visibleRect, in: container)
        let style = NSMutableParagraphStyle()
        style.alignment = .right
        let number: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: TextScale.points(10.5), weight: .regular),
                                                     .foregroundColor: palette.text.withAlphaComponent(0.55), .paragraphStyle: style]
        let markerFont = NSFont.monospacedSystemFont(ofSize: TextScale.points(11), weight: .semibold)
        manager.enumerateLineFragments(forGlyphRange: range) { [self] lineRect, _, _, glyphs, _ in
            guard let line = editor.displayLine(at: manager.characterIndexForGlyph(at: glyphs.location)) else { return }
            let y = convert(NSPoint(x: 0, y: lineRect.minY + editor.textContainerInset.height), from: editor).y
            let row = NSRect(x: 0, y: y, width: bounds.width, height: lineRect.height)
            if let tint = GitDiffTextView.background(line, palette: palette) { tint.setFill(); row.fill() }
            if line.fileHeader { NSColor.separatorColor.setFill(); NSRect(x: 0, y: row.minY, width: row.width, height: 1).fill() }
            if line.kind == .addition || line.kind == .deletion {
                let color = line.kind == .addition ? palette.addition : palette.deletion
                color.setFill(); NSRect(x: 0, y: row.minY, width: 3, height: row.height).fill()
                ((line.kind == .addition ? "+" : "−") as NSString).draw(at: NSPoint(x: bounds.width - TextScale.points(18), y: row.minY + 2),
                                                                       withAttributes: [.font: markerFont, .foregroundColor: color])
            }
            if let old = line.oldLine { (String(old) as NSString).draw(in: NSRect(x: 4, y: row.minY + 2.5, width: TextScale.points(30), height: row.height), withAttributes: number) }
            if let new = line.newLine { (String(new) as NSString).draw(in: NSRect(x: TextScale.points(38), y: row.minY + 2.5, width: TextScale.points(30), height: row.height), withAttributes: number) }
        }
        let visible = rect.intersection(bounds)
        NSColor.separatorColor.setFill()
        NSRect(x: bounds.maxX - 1, y: visible.minY, width: 1, height: visible.height).fill()
    }
}
