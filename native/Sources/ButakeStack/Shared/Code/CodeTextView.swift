import AppKit
import SwiftUI

enum CodeEditorStyle {
    static var font: NSFont { .monospacedSystemFont(ofSize: TextScale.points(12.5), weight: .regular) }
    static var advance: CGFloat { ("0" as NSString).size(withAttributes: [.font: font]).width }
    static let currentLine = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor.white.withAlphaComponent(0.05) : NSColor.black.withAlphaComponent(0.035)
    }
}

/// Text view of the editor: knows where each line starts (for the gutter) and paints the caret's line.
final class CodeTextView: NSTextView {
    override var wantsDefaultClipping: Bool { true }
    /// UTF-16 offset where each line starts, built once per text change (nil when the text changed), so
    /// the gutter finds a line number with a binary search. Counted on the line feed: right for CRLF.
    var lineStarts: [Int]?

    func lineNumber(at location: Int) -> Int {
        let starts = lineStartOffsets()
        var low = 0, high = starts.count - 1
        while low < high { let mid = (low + high + 1) / 2; if starts[mid] <= location { low = mid } else { high = mid - 1 } }
        return low + 1
    }

    /// `lineStarts`, built when the text changed since the last call.
    func lineStartOffsets() -> [Int] {
        if let lineStarts { return lineStarts }
        let text = string as NSString
        let length = text.length
        var starts = [0]
        var buffer = [unichar](repeating: 0, count: min(max(length, 1), 65_536))
        var offset = 0
        while offset < length {
            let count = min(buffer.count, length - offset)
            text.getCharacters(&buffer, range: NSRange(location: offset, length: count))
            for index in 0..<count where buffer[index] == 0x0A { starts.append(offset + index + 1) }
            offset += count
        }
        lineStarts = starts
        return starts
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        // The caret's line, only while there is no selection of several characters.
        guard selectedRange().length == 0, let manager = layoutManager else { return }
        let text = string as NSString
        let length = text.length
        let caret = min(selectedRange().location, length)
        let lineRect: NSRect
        if length == 0 || caret == length && text.character(at: length - 1) == 0x0A {
            lineRect = manager.extraLineFragmentRect
        } else {
            lineRect = manager.lineFragmentRect(forGlyphAt: manager.glyphIndexForCharacter(at: max(0, min(caret, length - 1))), effectiveRange: nil)
        }
        CodeEditorStyle.currentLine.setFill()
        NSRect(x: 0, y: lineRect.minY + textContainerInset.height, width: bounds.width, height: lineRect.height).fill()
    }
}

/// Line numbers of the editor, the caret's in a stronger color.
final class CodeLineRuler: NSRulerView {
    override var isFlipped: Bool { true }
    var surface: NSColor = .textBackgroundColor

    override init(scrollView: NSScrollView?, orientation: NSRulerView.Orientation) {
        super.init(scrollView: scrollView, orientation: orientation)
        ruleThickness = TextScale.points(54)
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: bounds).addClip()
        surface.setFill(); rect.intersection(bounds).fill()
        guard let view = clientView as? CodeTextView, let manager = view.layoutManager, let container = view.textContainer else { return }
        let text = view.string as NSString
        let caretLine = view.lineNumber(at: min(view.selectedRange().location, text.length))
        let style = NSMutableParagraphStyle()
        style.alignment = .right
        let normal: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: TextScale.points(10.5), weight: .regular), .foregroundColor: NSColor.tertiaryLabelColor, .paragraphStyle: style]
        let current: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: TextScale.points(10.5), weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: style]
        let glyphs = manager.glyphRange(forBoundingRect: view.visibleRect, in: container)
        var number = view.lineNumber(at: manager.characterIndexForGlyph(at: glyphs.location))
        var lastLineStart = -1
        manager.enumerateLineFragments(forGlyphRange: glyphs) { [self] lineRect, _, _, range, _ in
            let character = manager.characterIndexForGlyph(at: range.location)
            let lineStart = text.lineRange(for: NSRange(location: character, length: 0)).location
            guard lineStart != lastLineStart else { return } // a wrapped continuation
            if lastLineStart >= 0 { number += 1 }
            lastLineStart = lineStart
            let y = convert(NSPoint(x: 0, y: lineRect.minY + view.textContainerInset.height), from: view).y
            ("\(number)" as NSString).draw(in: NSRect(x: 4, y: y + 2, width: bounds.width - 16, height: lineRect.height), withAttributes: number == caretLine ? current : normal)
        }
        if text.length == 0 || text.hasSuffix("\n") {
            let extra = manager.extraLineFragmentRect
            if extra.height > 0 {
                let y = convert(NSPoint(x: 0, y: extra.minY + view.textContainerInset.height), from: view).y
                ("\(text.length == 0 ? 1 : number + 1)" as NSString).draw(in: NSRect(x: 4, y: y + 2, width: bounds.width - 16, height: extra.height), withAttributes: normal)
            }
        }
    }
}
