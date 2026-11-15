import AppKit
import SwiftUI

/// Native code editor: line numbers, syntax colors, the caret's line, indentation kept on a new line,
/// and none of the "smart" substitutions (quotes, dashes, spelling) that would corrupt a source file.
/// A large file is colored in slices of a few milliseconds and each edit recolors only its lines.
struct CodeEditor: NSViewRepresentable {
    @Binding var text: String
    /// File edited, for its syntax colors.
    var path: String
    var editable = true
    var themeSignature = Brand.theme.signature ^ Int(TextScale.shared.factor * 1_000) ^ (Brand.customAccent ? 1 : 0)

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        ThemedScroller.install(on: scroll)
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.clipsToBounds = true
        let view = CodeTextView(frame: .zero)
        view.delegate = context.coordinator
        view.isRichText = false
        view.importsGraphics = false
        view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.isGrammarCheckingEnabled = false
        view.smartInsertDeleteEnabled = false
        view.usesFindBar = true
        view.isIncrementalSearchingEnabled = true
        view.textContainerInset = NSSize(width: 10, height: 12)
        view.isHorizontallyResizable = true
        view.isVerticallyResizable = true
        view.minSize = .zero
        view.maxSize = NSSize(width: 1_000_000, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.containerSize = NSSize(width: 1_000_000, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = false
        view.autoresizingMask = [.width]
        view.setAccessibilityIdentifier("git.editor.text")
        view.setAccessibilityLabel(L("git.editor.label"))
        scroll.documentView = view
        let ruler = CodeLineRuler(scrollView: scroll, orientation: .verticalRuler)
        ruler.clientView = view
        scroll.verticalRulerView = ruler
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true
        context.coordinator.textView = view
        context.coordinator.applyTheme(view, scroll: scroll)
        // Large files: lay out what is on screen, not the whole document, after every coloring pass.
        view.layoutManager?.allowsNonContiguousLayout = true
        view.textStorage?.delegate = context.coordinator
        view.string = text
        view.isEditable = editable
        context.coordinator.synced = text
        context.coordinator.themeSignature = themeSignature
        context.coordinator.highlight(view)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? CodeTextView else { return }
        let coordinator = context.coordinator
        coordinator.parent = self
        view.isEditable = editable
        if coordinator.themeSignature != themeSignature {
            coordinator.themeSignature = themeSignature
            coordinator.applyTheme(view, scroll: scroll)
            coordinator.highlight(view)
        }
        // `synced` is the last text exchanged with the binding: while it is the same storage this check
        // is O(1), instead of comparing the whole document on every SwiftUI update.
        guard coordinator.synced != text else { return }
        coordinator.synced = text
        guard view.string != text else { return }
        let selection = view.selectedRanges
        view.string = text
        view.lineStarts = nil
        coordinator.highlight(view)
        // Undo steps recorded for the previous text would apply over the new one.
        view.undoManager?.removeAllActions()
        let length = (text as NSString).length
        let valid = selection.filter { $0.rangeValue.upperBound <= length }
        view.selectedRanges = valid.isEmpty ? [NSValue(range: NSRange(location: 0, length: 0))] : valid
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate, @preconcurrency NSTextStorageDelegate {
        var parent: CodeEditor
        weak var textView: CodeTextView?
        var themeSignature = 0
        /// Last text sent to or received from the binding (see `updateNSView`).
        var synced = ""
        private var palette = GitDiffPalette.current
        private var syntax = SyntaxColors.current
        private var pending: DispatchWorkItem?
        /// Whether each line ends inside a block comment (index = line): an edit recolors only its own
        /// lines, and the lines below only while their comment state actually changes.
        private var lineEndStates: [Bool] = []
        /// False until a full pass has finished (and beyond the size limit): edits then do a full pass.
        private var statesValid = false
        /// Bumped by every full pass and by edits that invalidate one in flight.
        private var generation = 0
        /// Characters edited since the last coloring, in current coordinates.
        private var edited: Range<Int>?
        /// Our own attribute changes also reach the storage delegate.
        private var applying = false
        static let sizeLimit = 600_000
        /// A full pass finished and edits are colored incrementally.
        var isColored: Bool { statesValid }

        init(_ parent: CodeEditor) { self.parent = parent }

        func applyTheme(_ view: CodeTextView, scroll: NSScrollView) {
            palette = .current
            syntax = .current
            scroll.backgroundColor = palette.surface
            view.backgroundColor = palette.surface
            view.textColor = palette.text
            view.font = CodeEditorStyle.font
            view.insertionPointColor = NSColor(Brand.accent)
            view.selectedTextAttributes = [.backgroundColor: NSColor.selectedTextBackgroundColor]
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 3
            paragraph.defaultTabInterval = CodeEditorStyle.advance * 4
            paragraph.tabStops = []
            view.defaultParagraphStyle = paragraph
            view.typingAttributes = [.font: CodeEditorStyle.font, .foregroundColor: palette.text, .paragraphStyle: paragraph]
            (scroll.verticalRulerView as? CodeLineRuler)?.surface = palette.surface
            scroll.verticalRulerView?.ruleThickness = TextScale.points(54)
            scroll.verticalRulerView?.needsDisplay = true
        }

        func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions, range editedRange: NSRange, changeInLength delta: Int) {
            guard editedMask.contains(.editedCharacters), !applying else { return }
            var lower = editedRange.location, upper = editedRange.location + editedRange.length
            if let previous = edited {
                let shifted = previous.upperBound >= editedRange.location ? previous.upperBound + delta : previous.upperBound
                lower = min(lower, previous.lowerBound)
                upper = max(upper, shifted)
            }
            edited = lower..<max(lower, upper)
        }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? CodeTextView else { return }
            view.lineStarts = nil
            // Native storage: later comparisons against it are a plain memory compare.
            var value = view.string
            value.makeContiguousUTF8()
            synced = value
            parent.text = value
            // While an input method is composing, its marked text keeps its attributes: color on commit.
            guard !view.hasMarkedText() else { return }
            if let range = edited, statesValid, recolor(view, edited: range) { edited = nil; return }
            // No valid line states (a full pass still running or impossible): a full pass once typing pauses.
            generation &+= 1
            statesValid = false
            pending?.cancel()
            let work = DispatchWorkItem { [weak self, weak view] in
                MainActor.assumeIsolated { if let view { self?.highlight(view) } }
            }
            pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + ((view.string as NSString).length < 40_000 ? 0.05 : 0.3), execute: work)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            view.needsDisplay = true
            view.enclosingScrollView?.verticalRulerView?.needsDisplay = true
        }

        /// A new line keeps the previous line's indentation, and one level more after `{ [ ( :`.
        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
            let text = textView.string as NSString
            let caret = textView.selectedRange().location
            let lineRange = text.lineRange(for: NSRange(location: min(caret, text.length), length: 0))
            let line = text.substring(with: NSRange(location: lineRange.location, length: max(0, caret - lineRange.location)))
            var indent = String(line.prefix { $0 == " " || $0 == "\t" })
            if let last = line.trimmingCharacters(in: .whitespaces).last, "{[(:".contains(last) { indent += "    " }
            // The file's own line ending: a bare "\n" inside a CRLF file would mix both.
            let newline = text.range(of: "\r\n", options: .literal).location != NSNotFound ? "\r\n" : "\n"
            textView.insertText(newline + indent, replacementRange: textView.selectedRange())
            return true
        }

        // MARK: Coloring

        private func baseAttributes(_ view: NSTextView) -> [NSAttributedString.Key: Any] {
            [.font: CodeEditorStyle.font, .foregroundColor: palette.text, .paragraphStyle: view.defaultParagraphStyle ?? .default]
        }

        private func highlighter() -> SyntaxHighlighter { SyntaxHighlighter(language: CodeLanguage.of(parent.path), colors: syntax) }

        /// Resets and colors one line; `state` is the block-comment state entering it and leaving it.
        private func color(_ line: Int, starts: [Int], text: NSString, storage: NSTextStorage, base: [NSAttributedString.Key: Any], highlighter: SyntaxHighlighter, state: inout Bool) {
            let start = starts[line], end = line + 1 < starts.count ? starts[line + 1] : text.length
            guard end > start else { return }
            storage.setAttributes(base, range: NSRange(location: start, length: end - start))
            var contentEnd = end
            if contentEnd > start, text.character(at: contentEnd - 1) == 0x0A { contentEnd -= 1 }
            if contentEnd > start, text.character(at: contentEnd - 1) == 0x0D { contentEnd -= 1 }
            guard contentEnd > start else { return }
            for (span, value) in highlighter.spans(text.substring(with: NSRange(location: start, length: contentEnd - start)), inBlockComment: &state) {
                storage.addAttribute(.foregroundColor, value: value, range: NSRange(location: start + span.location, length: span.length))
            }
        }

        private static func lineIndex(_ starts: [Int], at location: Int) -> Int {
            var low = 0, high = starts.count - 1
            while low < high { let mid = (low + high + 1) / 2; if starts[mid] <= location { low = mid } else { high = mid - 1 } }
            return low
        }

        /// Recolors the edited lines and what follows while its comment state changes. False when the
        /// cached states cannot answer (the caller then does a full pass).
        private func recolor(_ view: CodeTextView, edited: Range<Int>) -> Bool {
            guard let storage = view.textStorage else { return false }
            let text = storage.string as NSString, length = text.length
            guard length < Coordinator.sizeLimit else { statesValid = false; return true }
            let starts = view.lineStartOffsets()
            let first = Coordinator.lineIndex(starts, at: min(edited.lowerBound, length)), last = Coordinator.lineIndex(starts, at: min(edited.upperBound, length))
            // Lines the edit replaced, in the old numbering.
            let oldLast = last - (starts.count - lineEndStates.count)
            guard oldLast >= first, oldLast < lineEndStates.count, last - first < 3_000 else { return false }
            let oldExit = lineEndStates[oldLast]
            var state = first > 0 ? lineEndStates[first - 1] : false
            let base = baseAttributes(view), highlighter = highlighter()
            var fresh: [Bool] = []
            fresh.reserveCapacity(last - first + 1)
            applying = true
            storage.beginEditing()
            for line in first...last {
                color(line, starts: starts, text: text, storage: storage, base: base, highlighter: highlighter, state: &state)
                fresh.append(state)
            }
            lineEndStates.replaceSubrange(first...oldLast, with: fresh)
            var complete = true
            if state != oldExit {
                // The edit opened or closed a block comment: the lines below change until the old state returns.
                var line = last + 1
                while line < starts.count {
                    if line - last > 3_000 { complete = false; break }
                    let cached = lineEndStates[line]
                    color(line, starts: starts, text: text, storage: storage, base: base, highlighter: highlighter, state: &state)
                    lineEndStates[line] = state
                    line += 1
                    if state == cached { break }
                }
            }
            storage.endEditing()
            applying = false
            view.enclosingScrollView?.verticalRulerView?.needsDisplay = true
            // A comment change that reaches far down: finish with a sliced full pass instead of stalling.
            if !complete { highlight(view) }
            return true
        }

        /// Full pass: first load, theme change and a text replaced from outside. In slices of a few
        /// milliseconds, so a large file never blocks the main thread while it is colored.
        func highlight(_ view: NSTextView) {
            pending?.cancel()
            generation &+= 1
            edited = nil
            statesValid = false
            guard let view = view as? CodeTextView, let storage = view.textStorage else { return }
            let length = (storage.string as NSString).length
            guard length < Coordinator.sizeLimit else { return }
            let starts = view.lineStartOffsets()
            applying = true
            storage.beginEditing()
            storage.setAttributes(baseAttributes(view), range: NSRange(location: 0, length: length))
            storage.endEditing()
            applying = false
            lineEndStates = [Bool](repeating: false, count: starts.count)
            continueHighlight(view, from: 0, state: false, generation: generation, highlighter: highlighter())
        }

        private func continueHighlight(_ view: CodeTextView, from line: Int, state: Bool, generation: Int, highlighter: SyntaxHighlighter) {
            guard generation == self.generation, let storage = view.textStorage else { return }
            let text = storage.string as NSString, starts = view.lineStartOffsets()
            guard starts.count == lineEndStates.count else { return }
            let base = baseAttributes(view), deadline = CFAbsoluteTimeGetCurrent() + 0.008
            var line = line, state = state
            applying = true
            storage.beginEditing()
            while line < starts.count {
                color(line, starts: starts, text: text, storage: storage, base: base, highlighter: highlighter, state: &state)
                lineEndStates[line] = state
                line += 1
                if line % 32 == 0, CFAbsoluteTimeGetCurrent() > deadline { break }
            }
            storage.endEditing()
            applying = false
            if line < starts.count {
                let next = line, carried = state
                DispatchQueue.main.async { [weak self, weak view] in
                    MainActor.assumeIsolated {
                        if let self, let view { self.continueHighlight(view, from: next, state: carried, generation: generation, highlighter: highlighter) }
                    }
                }
            } else {
                statesValid = true
                view.enclosingScrollView?.verticalRulerView?.needsDisplay = true
            }
        }
    }
}
