import AppKit
import SwiftUI

/// The AppKit diff (`NSTextView` with a gutter) for a patch text, as SwiftUI sees it. Large patches are
/// parsed and colored off the main thread; the previous content stays on screen meanwhile.
struct GitDiffText: NSViewRepresentable {
    let text: String
    /// File shown, for the syntax colors when the patch itself does not name it.
    var path: String?
    var search = ""
    var onStageHunk: ((Int) -> Void)?
    /// Inside another scroll view (one file of a multi-file diff): as tall as its content, the vertical
    /// scrolling left to the enclosing view and the measured height reported through `onHeight`.
    var embedded = false
    var onHeight: ((CGFloat) -> Void)?
    /// Read while the parent renders, so a theme or text size change rebuilds the colors.
    var themeSignature = Brand.theme.signature ^ Int(TextScale.shared.factor * 1_000) ^ (Brand.customAccent ? 1 : 0)

    func makeNSView(context: Context) -> NSScrollView { Self.makeScrollView(embedded: embedded) }

    /// The scroll view with its text view and gutter, empty.
    static func makeScrollView(embedded: Bool) -> NSScrollView {
        let scroll = GitDiffScrollView()
        scroll.embedded = embedded
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsetsZero
        scroll.contentView.automaticallyAdjustsContentInsets = false
        scroll.contentView.contentInsets = NSEdgeInsetsZero
        ThemedScroller.install(on: scroll)
        scroll.hasVerticalScroller = !embedded
        scroll.hasHorizontalScroller = true
        if embedded { scroll.verticalScrollElasticity = .none }
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        // macOS 14+ no longer clips by default: without this the gutter's separator escapes the view.
        scroll.clipsToBounds = true
        let editor = GitDiffTextView(frame: .zero)
        editor.isEditable = false
        editor.isSelectable = true
        editor.isRichText = false
        editor.usesFindBar = true
        editor.isIncrementalSearchingEnabled = true
        editor.font = GitDiffRenderer.codeFont
        // The gutter overlays the document (overlay scrollers), so the text starts past it.
        editor.textContainerInset = NSSize(width: TextScale.points(104), height: embedded ? 6 : 10)
        editor.isHorizontallyResizable = true
        editor.isVerticallyResizable = true
        editor.minSize = .zero
        editor.maxSize = NSSize(width: 1_000_000, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.containerSize = NSSize(width: 1_000_000, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.widthTracksTextView = false
        editor.drawsBackground = true
        editor.setAccessibilityIdentifier("git.diff.text")
        editor.setAccessibilityLabel(L("git.diff.label"))
        scroll.documentView = editor
        let ruler = GitDiffLineRuler(scrollView: scroll, orientation: .verticalRuler)
        ruler.clientView = editor
        ruler.clipsToBounds = true
        editor.clipsToBounds = true
        scroll.verticalRulerView = ruler
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true
        return scroll
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 600, height: proposal.height ?? 400)
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let editor = scroll.documentView as? GitDiffTextView else { return }
        editor.onHunk = onStageHunk
        if editor.themeSignature != themeSignature {
            editor.themeSignature = themeSignature
            editor.source = nil
            editor.palette = .current
            // The gutter grows with the text size (⌘+ / ⌘−).
            editor.textContainerInset.width = TextScale.points(104)
            scroll.verticalRulerView?.ruleThickness = TextScale.points(92)
            scroll.backgroundColor = editor.palette.surface
            editor.backgroundColor = editor.palette.surface
            editor.textColor = editor.palette.text
            scroll.verticalScroller?.needsDisplay = true
        }
        if editor.source != text {
            editor.source = text
            editor.renderGeneration &+= 1
            let generation = editor.renderGeneration, style = GitDiffRenderer.Style.current, path = path, embedded = embedded, onHeight = onHeight
            if text.utf8.count > GitDiffRenderer.backgroundThreshold {
                // Large patch: parsing and coloring take hundreds of milliseconds, so they run off the
                // main thread and are applied only if this is still the text to show.
                let text = text
                Task { @MainActor [weak editor, weak scroll] in
                    let prepared = await Task.detached(priority: .userInitiated) { GitDiffRenderer.prepare(text, path: path, style: style) }.value
                    guard let editor, let scroll, editor.renderGeneration == generation else { return }
                    Self.apply(prepared, to: editor, in: scroll, embedded: embedded, onHeight: onHeight, large: true)
                }
            } else {
                Self.apply(GitDiffRenderer.prepare(text, path: path, style: style), to: editor, in: scroll, embedded: embedded, onHeight: onHeight, large: false)
            }
        }
        editor.search(search)
        editor.needsDisplay = true
        scroll.verticalRulerView?.needsDisplay = true
    }

    /// Shows a prepared patch: sizes the document to it and starts at the top.
    static func apply(_ prepared: GitDiffPrepared, to editor: GitDiffTextView, in scroll: NSScrollView, embedded: Bool, onHeight: ((CGFloat) -> Void)?, large: Bool) {
        editor.displayLines = prepared.lines
        editor.wordRanges = prepared.words
        editor.hunkCount = prepared.hunkCount
        let font = GitDiffRenderer.codeFont
        // Monospaced: the width is the longest line times one glyph advance, no per-line measuring.
        let advance = ("0" as NSString).size(withAttributes: [.font: font]).width
        let width = max(scroll.contentSize.width, ceil(CGFloat(prepared.longest) * advance) + 220)
        editor.setFrameSize(NSSize(width: width, height: max(scroll.contentSize.height, 200)))
        editor.textContainer?.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        // Large patches are not laid out up front (hundreds of milliseconds): the text system lays out
        // what is shown and finishes the rest in the background; the view then takes its exact height.
        editor.fitsHeightWhenLaidOut = large && !embedded
        editor.layoutManager?.delegate = editor
        editor.lineRanges = prepared.ranges
        editor.textStorage?.setAttributedString(prepared.text)
        editor.updateAccessibilityActions()
        if let manager = editor.layoutManager, let container = editor.textContainer {
            let height: CGFloat
            if large && !embedded {
                // Lines never wrap: until the layout finishes, the height is the line count times the
                // height of a code line near the top.
                let sample = prepared.lines.firstIndex { $0.kind == .addition || $0.kind == .deletion || $0.kind == .context } ?? 0
                let measured = prepared.ranges.indices.contains(sample) && prepared.ranges[sample].location < min(prepared.text.length, 20_000)
                    ? manager.lineFragmentRect(forGlyphAt: manager.glyphIndexForCharacter(at: prepared.ranges[sample].location), effectiveRange: nil).height : 0
                let lineHeight = measured > 0 ? measured : manager.defaultLineHeight(for: font) + 3.5
                height = max(scroll.contentSize.height, CGFloat(prepared.lines.count) * lineHeight + 28)
            } else {
                manager.ensureLayout(for: container)
                let rect = manager.usedRect(for: container)
                // Embedded: exactly the content, without the empty fragment after the last line feed.
                height = embedded ? ceil(rect.height - manager.extraLineFragmentRect.height) + 2 * editor.textContainerInset.height
                    : max(scroll.contentSize.height, rect.height + 28)
            }
            editor.setFrameSize(NSSize(width: width, height: height))
            if embedded, let onHeight { DispatchQueue.main.async { onHeight(height) } }
        }
        editor.refreshSearch()
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        DispatchQueue.main.async {
            scroll.contentView.scroll(to: .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        editor.needsDisplay = true
        scroll.verticalRulerView?.needsDisplay = true
    }
}
