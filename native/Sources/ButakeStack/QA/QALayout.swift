#if DEBUG
import AppKit

/// The layout of the window in the QA log, the same for every page ("QA layout:"): the window
/// against the screen, the sidebar's first row, the split view against the window, and the first
/// content of the content column and of the detail (search field, list or form, terminal) against
/// the title bar. Anything drawn under the title bar ends the line with "LAYOUT FAIL", which
/// capturar.py turns into a failed capture. A second line ("QA text:") lists the text fields and
/// buttons of AppKit (toolbar, title, tab bar) whose text does not fit, and the toolbar items sent
/// to its overflow menu.
@MainActor extension QAHooks {
    static func layoutReport(_ window: NSWindow) -> String {
        let screen = window.screen?.visibleFrame ?? .zero
        let titleBar = window.frame.height - window.contentLayoutRect.maxY
        var line = String(format: "QA layout: window %.0fx%.0f, top %.0f, screen top %.0f, inside screen %@, title bar %.0f",
                          window.frame.width, window.frame.height, window.frame.maxY, screen.maxY,
                          window.frame.maxY <= screen.maxY + 0.5 ? "yes" : "no", titleBar)
        var failures: [String] = []
        if let outline = sidebarOutline(window), let scroll = outline.enclosingScrollView {
            let clip = scroll.contentView
            // The first row whose top edge is inside the visible part of the list (clear of the insets; the clip is flipped).
            var visible = clip.bounds
            visible.origin.y += clip.contentInsets.top
            visible.size.height -= clip.contentInsets.top
            let range = outline.rows(in: outline.convert(visible, from: clip))
            line += String(format: ", sidebar scrolled %.0f, inset top %.0f", clip.bounds.minY + clip.contentInsets.top, clip.contentInsets.top)
            // A row cut by the top edge is scrolling under the edge effect; the first whole one is the measure.
            let top = outline.convert(visible, from: clip).minY
            if let index = (range.location..<range.location + range.length).first(where: { outline.rect(ofRow: $0).minY >= top - 0.5 }) {
                let first = outline.convert(outline.rect(ofRow: index), to: nil)
                let row = window.frame.height - first.maxY
                line += String(format: ", first row %d at %.0f, %@ the title bar", index, row, row >= titleBar - 0.5 ? "below" : "UNDER")
                if row < titleBar - 0.5 { failures.append("sidebar under the title bar") }
            }
            line += ", key \(window.isKeyWindow ? "yes" : "no"), first responder \(window.firstResponder.map { String(describing: type(of: $0)) } ?? "none")"
            line += ", rows \(outline.numberOfRows)"
        } else {
            line += ", sidebar none"
        }
        if let controller = window.contentView.flatMap(splitController) {
            // The window's columns: width of each and whether the content one is collapsed.
            line += ", columns " + controller.splitViewItems.map { String(format: "%.0f%@", $0.viewController.view.frame.width, $0.isCollapsed ? " collapsed" : "") }
                .joined(separator: " | ")
            line += columnsReport(window, controller: controller, titleBar: titleBar, failures: &failures)
        }
        return line + (failures.isEmpty ? ", layout ok" : ", LAYOUT FAIL: " + failures.joined(separator: "; "))
    }

    /// The columns against the window (P-15): the split view must fit inside it, and the first
    /// content of the content column and of the detail must start below the title bar. A page whose
    /// minimum height is taller than the window (a text with `fixedSize(vertical:)` asked for its
    /// size at a narrow width) makes the whole split view taller than the window: AppKit centers it,
    /// so every column starts under the title bar and the status bar is cut at the bottom.
    private static func columnsReport(_ window: NSWindow, controller: NSSplitViewController, titleBar: CGFloat, failures: inout [String]) -> String {
        let split = controller.splitView.convert(controller.splitView.bounds, to: nil)
        let splitTop = window.frame.height - split.maxY
        var line = String(format: ", split top %.0f bottom %.0f", splitTop, split.minY)
        if splitTop < -0.5 || split.minY < -0.5 { failures.append("split view taller than the window") }
        func top(_ view: NSView) -> CGFloat { window.frame.height - view.convert(view.bounds, to: nil).maxY }
        for (name, item) in zip(["content", "detail"], controller.splitViewItems.dropFirst()) where !item.isCollapsed {
            let root = item.viewController.view
            if name == "detail" {
                let start = top(root) + root.safeAreaInsets.top
                line += String(format: ", detail starts at %.0f", start)
                if start < titleBar - 0.5 { failures.append("detail under the title bar") }
            }
            if let search = all(NSSearchField.self, in: root).filter({ !$0.isHiddenOrHasHiddenAncestor }).min(by: { top($0) < top($1) }) {
                line += String(format: ", %@ search at %.0f", name, top(search))
                if top(search) < titleBar - 0.5 { failures.append("\(name) search under the title bar") }
            }
            // The first list or form of the column: where its content starts on screen (its top plus
            // the inset the toolbar leaves, or the document's top when it is scrolled), and its first
            // row. A horizontal scroll view, like the SSH tab bar's, spans under the toolbar with no
            // inset and places its row below it: only vertical ones are measured.
            let scrolls = all(NSScrollView.self, in: root).filter { !$0.isHiddenOrHasHiddenAncestor && $0.hasVerticalScroller && $0.frame.height > 40 && $0.frame.width > 80 }
            if let scroll = scrolls.min(by: { top($0) < top($1) }) {
                let content = max(top(scroll) + scroll.contentView.contentInsets.top, scroll.documentView.map(top) ?? 0)
                line += String(format: ", %@ content at %.0f", name, content)
                if content < titleBar - 0.5 { failures.append("\(name) content under the title bar") }
                if let table = scroll.documentView as? NSTableView, table.numberOfRows > 0 {
                    let row = window.frame.height - table.convert(table.rect(ofRow: 0), to: nil).maxY
                    line += String(format: ", %@ first row at %.0f", name, row)
                    if row < titleBar - 0.5 { failures.append("\(name) first row under the title bar") }
                }
            }
            if let terminal = all(NSView.self, in: root).first(where: { $0.accessibilityIdentifier() == "ssh.terminal.container" }) {
                line += String(format: ", terminal at %.0f", top(terminal))
                if top(terminal) < titleBar - 0.5 { failures.append("terminal under the title bar") }
            }
        }
        return line
    }

    /// Text of AppKit that does not fit where it is drawn: single-line text fields (the window's
    /// title, labels of the toolbar) and buttons whose intrinsic width is wider than their frame,
    /// and toolbar items the toolbar had to send to its overflow menu. SwiftUI's own Text is drawn
    /// without a text field and is checked by eye in the screenshots.
    static func textReport(_ window: NSWindow) -> String {
        var cut: [String] = []
        let windowButtons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { window.standardWindowButton($0) }
        var views = window.contentView.map { all(NSView.self, in: $0) } ?? []
        // The toolbar and the title live in the title bar's own view, outside the content view.
        if let frame = window.contentView?.superview { views += all(NSView.self, in: frame).filter { !views.contains($0) } }
        for view in views where !view.isHiddenOrHasHiddenAncestor && view.frame.width > 1 {
            if let field = view as? NSTextField, !field.isEditable, field.maximumNumberOfLines <= 1, !field.stringValue.isEmpty,
               field.intrinsicContentSize.width > field.bounds.width + 1 {
                cut.append("text «\(field.stringValue)» \(Int(field.intrinsicContentSize.width))>\(Int(field.bounds.width))")
            } else if let button = view as? NSButton, !windowButtons.contains(button), !button.title.isEmpty, button.intrinsicContentSize.width > button.bounds.width + 1 {
                cut.append("button «\(button.title)» \(Int(button.intrinsicContentSize.width))>\(Int(button.bounds.width))")
            }
        }
        var line = "QA text: " + (cut.isEmpty ? "nothing cut" : "CUT " + cut.joined(separator: "; "))
        if let toolbar = window.toolbar {
            let hidden = toolbar.items.filter { item in !(toolbar.visibleItems ?? []).contains(item) && item.itemIdentifier != .flexibleSpace && item.itemIdentifier != .space
                && !item.itemIdentifier.rawValue.localizedCaseInsensitiveContains("separator") }
            line += hidden.isEmpty ? ", toolbar all visible" : ", toolbar overflow: " + hidden.map { $0.label.isEmpty ? $0.itemIdentifier.rawValue : $0.label }.joined(separator: ", ")
            line += ", " + overlapReport(toolbar)
        }
        return line
    }

    /// Visible toolbar items whose frames cross (a button drawn over the tabs): "TOOLBAR OVERLAP"
    /// makes the capture fail, like LAYOUT FAIL.
    private static func overlapReport(_ toolbar: NSToolbar) -> String {
        let items = (toolbar.visibleItems ?? []).compactMap { item -> (String, NSRect)? in
            guard let view = item.view, view.window != nil, !view.isHiddenOrHasHiddenAncestor, view.frame.width > 1 else { return nil }
            return (item.label.isEmpty ? item.itemIdentifier.rawValue : item.label, view.convert(view.bounds, to: nil))
        }
        var crossed: [String] = []
        for (index, first) in items.enumerated() {
            for second in items.dropFirst(index + 1) where first.1.insetBy(dx: 0.5, dy: 0.5).intersects(second.1.insetBy(dx: 0.5, dy: 0.5)) {
                crossed.append("«\(first.0)»/«\(second.0)»")
            }
        }
        if !crossed.isEmpty { return "TOOLBAR OVERLAP " + crossed.joined(separator: ", ") }
        // Tabs in the bar (a segmented control, or their menu on a narrow page: "<area>.tabs") keep
        // clear of their neighbours: at least 8 pt.
        let tabs = (toolbar.visibleItems ?? []).first { item in
            item.view.map { view in all(NSView.self, in: view).contains { $0 is NSSegmentedControl || $0.accessibilityIdentifier().hasSuffix(".tabs") } } ?? false
        }
        guard let tabs, let frame = tabs.view.map({ $0.convert($0.bounds, to: nil) }) else { return "toolbar \(items.count) items apart" }
        let gaps = items.filter { $0.1 != frame }.map { max($0.1.minX - frame.maxX, frame.minX - $0.1.maxX) }
        let gap = gaps.min() ?? .infinity
        return gap < 8 ? "TOOLBAR OVERLAP tabs \(Int(gap)) pt from a button" : "toolbar \(items.count) items apart, tabs \(gap.isFinite ? "\(Int(gap)) pt" : "alone") from the nearest"
    }

    /// The sidebar's list: the outline view furthest to the left.
    static func sidebarOutline(_ window: NSWindow) -> NSOutlineView? {
        func outlines(_ view: NSView) -> [NSOutlineView] { (view as? NSOutlineView).map { [$0] } ?? view.subviews.flatMap(outlines) }
        return window.contentView.flatMap { outlines($0).min { $0.convert(NSPoint.zero, to: nil).x < $1.convert(NSPoint.zero, to: nil).x } }
    }

    /// The window's three columns (sidebar, content, detail).
    private static func splitController(_ view: NSView) -> NSSplitViewController? {
        if let split = view as? NSSplitView, let controller = split.delegate as? NSSplitViewController, controller.splitViewItems.count == 3 { return controller }
        return view.subviews.lazy.compactMap(splitController).first
    }

    private static func all<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { all(type, in: $0) }
    }
}
#endif
