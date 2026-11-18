import AppKit
import SwiftUI

/// Rows as a native table: any number of columns, sort by clicking a header, NULL shown apart from
/// an empty string, cells edited in place (double click) and rows marked for deletion. Changes are
/// only reported; the page shows them and saves them with confirmation.
struct DataGrid: NSViewRepresentable {
    let columns: [String]
    let rows: [[String?]]
    var editable = false
    /// Row → column → new value (nil = NULL).
    var edits: [Int: [Int: String?]] = [:]
    var deleted: Set<Int> = []
    /// Rows at or after this index are new (not yet inserted).
    var firstNewRow = Int.max
    /// Sort columns in order (the first sorts first), each ascending or descending.
    var sorts: [(column: String, descending: Bool)] = []
    var onEdit: ((Int, Int, String?) -> Void)?
    /// A header clicked: the column, and whether ⇧ was held (add it to the sort instead of replacing).
    var onSort: ((String, Bool) -> Void)?
    var onDelete: (([Int]) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.allowsColumnReordering = false
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.rowHeight = 22
        table.gridStyleMask = [.solidVerticalGridLineMask]
        table.style = .plain
        table.intercellSpacing = NSSize(width: 6, height: 2)
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.setAccessibilityIdentifier("db.grid")
        let menu = NSMenu()
        menu.delegate = context.coordinator
        table.menu = menu
        context.coordinator.table = table
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let c = context.coordinator
        c.parent = self
        guard let table = c.table else { return }
        if c.columnNames != columns {
            c.columnNames = columns
            for column in table.tableColumns { table.removeTableColumn(column) }
            let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            for (index, name) in columns.enumerated() {
                let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("\(index)"))
                column.title = name
                let sample = rows.prefix(40).map { ($0[safe: index] ?? nil)?.prefix(60).count ?? 4 }.max() ?? 4
                let width = max(CGFloat(max(sample, name.count)) * font.pointSize * 0.62 + 18, 60)
                column.width = min(width, 360)
                column.minWidth = 40
                column.isEditable = editable
                table.addTableColumn(column)
            }
        }
        for (index, column) in table.tableColumns.enumerated() {
            let name = columns[safe: index] ?? column.title
            if let position = sorts.firstIndex(where: { $0.column == name }) {
                let arrow = sorts[position].descending ? "↓" : "↑"
                column.headerCell.title = sorts.count > 1 ? "\(name) \(arrow)\(position + 1)" : "\(name) \(arrow)"
            } else {
                column.headerCell.title = name
            }
        }
        // SwiftUI calls this on every change around the grid (typing a filter, a toast): reload
        // only when what the grid shows changed.
        let shown = Coordinator.Shown(rows: rows, edits: edits.mapValues { $0.mapValues { $0 ?? "\u{0}NULL" } }, deleted: deleted, editable: editable)
        if c.shown != shown {
            c.shown = shown
            table.reloadData()
        }
    }

    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSMenuDelegate {
        var parent: DataGrid?
        weak var table: NSTableView?
        var columnNames: [String] = []
        struct Shown: Equatable {
            var rows: [[String?]]
            var edits: [Int: [Int: String]]
            var deleted: Set<Int>
            var editable: Bool
        }
        var shown: Shown?

        func numberOfRows(in tableView: NSTableView) -> Int { parent?.rows.count ?? 0 }

        func value(_ row: Int, _ column: Int) -> String? {
            guard let parent else { return nil }
            if let edited = parent.edits[row]?[column] { return edited }
            return parent.rows[safe: row]?[safe: column] ?? nil
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let parent, let tableColumn, let column = Int(tableColumn.identifier.rawValue) else { return nil }
            let id = NSUserInterfaceItemIdentifier("cell")
            let field = (tableView.makeView(withIdentifier: id, owner: nil) as? NSTextField) ?? {
                let f = NSTextField()
                f.identifier = id
                f.isBordered = false
                f.drawsBackground = true
                f.lineBreakMode = .byTruncatingTail
                f.cell?.usesSingleLineMode = true
                f.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
                return f
            }()
            let value = self.value(row, column)
            let edited = parent.edits[row]?[column] != nil
            let isNew = row >= parent.firstNewRow
            if let value {
                field.stringValue = value
                field.textColor = .labelColor
                field.toolTip = value.count > 40 ? String(value.prefix(2000)) : nil
            } else {
                field.stringValue = "NULL"
                field.textColor = .tertiaryLabelColor
                field.toolTip = nil
            }
            field.isEditable = parent.editable && !parent.deleted.contains(row) && value?.contains(where: \.isNewline) != true
            field.delegate = self
            field.tag = row * 10_000 + column
            if parent.deleted.contains(row) {
                field.backgroundColor = NSColor.systemRed.withAlphaComponent(0.18)
            } else if edited || isNew {
                field.backgroundColor = NSColor.systemYellow.withAlphaComponent(isNew ? 0.12 : 0.28)
            } else {
                field.backgroundColor = .clear
            }
            return field
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField, let parent else { return }
            let row = field.tag / 10_000, column = field.tag % 10_000
            let old = value(row, column)
            let new = field.stringValue == "NULL" && old == nil ? nil : field.stringValue
            if new != old { parent.onEdit?(row, column, new) }
        }

        func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
            guard let index = Int(tableColumn.identifier.rawValue), let name = columnNames[safe: index] else { return }
            parent?.onSort?(name, NSEvent.modifierFlags.contains(.shift))
        }

        // Context menu: copy, NULL, delete.
        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let table, let parent else { return }
            let row = table.clickedRow, column = table.clickedColumn
            guard row >= 0 else { return }
            if !table.selectedRowIndexes.contains(row) { table.selectRowIndexes([row], byExtendingSelection: false) }
            menu.addItem(item(L("db.grid.copyValue"), #selector(copyValue(_:)), tag: row * 10_000 + max(column, 0)))
            menu.addItem(item(L("db.grid.copyRows"), #selector(copyRows(_:)), tag: 0))
            if parent.editable {
                menu.addItem(.separator())
                if column >= 0 { menu.addItem(item(L("db.grid.setNull"), #selector(setNull(_:)), tag: row * 10_000 + column)) }
                menu.addItem(item(L("db.grid.deleteRows"), #selector(deleteRows(_:)), tag: 0))
            }
        }
        private func item(_ title: String, _ action: Selector, tag: Int) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.tag = tag
            return item
        }
        @objc func copyValue(_ sender: NSMenuItem) {
            let value = self.value(sender.tag / 10_000, sender.tag % 10_000) ?? "NULL"
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
        }
        @objc func copyRows(_ sender: NSMenuItem) {
            guard let table else { return }
            let lines = table.selectedRowIndexes.map { row in
                (0..<columnNames.count).map { value(row, $0) ?? "NULL" }.joined(separator: "\t")
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(([columnNames.joined(separator: "\t")] + lines).joined(separator: "\n"), forType: .string)
        }
        @objc func setNull(_ sender: NSMenuItem) { parent?.onEdit?(sender.tag / 10_000, sender.tag % 10_000, nil) }
        @objc func deleteRows(_ sender: NSMenuItem) {
            guard let table else { return }
            parent?.onDelete?(Array(table.selectedRowIndexes))
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

/// SQL text with syntax colors (keywords, strings, numbers, comments) and the selection reported,
/// so the page can run just the selected text.
struct SQLEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var selection: String
    var onRun: (() -> Void)?
    /// Words to offer for what is being typed: the partial word, and the name before a dot
    /// (`users.` → columns of users) when there is one.
    var completions: ((String, String?) -> [String])?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    /// Knows when the completion list is inserting text (so typing that text does not reopen it).
    final class CompletingTextView: NSTextView {
        var isCompleting = false
        override func insertCompletion(_ word: String, forPartialWordRange charRange: NSRange, movement: Int, isFinal flag: Bool) {
            isCompleting = true
            defer { isCompleting = false }
            super.insertCompletion(word, forPartialWordRange: charRange, movement: movement, isFinal: flag)
        }
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        let size = scroll.contentSize
        let view = CompletingTextView(frame: NSRect(origin: .zero, size: size))
        view.minSize = NSSize(width: 0, height: size.height)
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.containerSize = NSSize(width: size.width, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = true
        scroll.documentView = view
        view.isRichText = false
        view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        view.textContainerInset = NSSize(width: 6, height: 8)
        view.delegate = context.coordinator
        view.string = text
        view.setAccessibilityIdentifier("db.sql.editor")
        context.coordinator.view = view
        context.coordinator.highlight()
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = context.coordinator.view, view.string != text else { return }
        view.string = text
        context.coordinator.highlight()
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SQLEditor
        weak var view: NSTextView?
        init(_ parent: SQLEditor) { self.parent = parent }

        /// What the last edit typed (completion opens only while typing, never on delete).
        private var lastTyped = ""

        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
            lastTyped = replacementString ?? ""
            return true
        }

        func textDidChange(_ notification: Notification) {
            guard let view else { return }
            parent.text = view.string
            highlight()
            // Opens the list after two letters of a word, or right after "table.".
            guard parent.completions != nil, let completing = view as? CompletingTextView, !completing.isCompleting,
                  lastTyped.count == 1, let typed = lastTyped.first, typed.isLetter || typed == "_" || typed == "." else { return }
            let (word, _) = currentWord(view)
            if typed == "." || word.count >= 2 {
                DispatchQueue.main.async { [weak view] in view?.complete(nil) }
            }
        }

        /// The word before the cursor and the name before its dot, if any.
        func currentWord(_ view: NSTextView) -> (String, String?) {
            let text = view.string as NSString
            let end = view.selectedRange().location
            var start = end
            func isWord(_ c: unichar) -> Bool { Character(UnicodeScalar(c) ?? " ").isLetter || Character(UnicodeScalar(c) ?? " ").isNumber || c == 95 }
            while start > 0, isWord(text.character(at: start - 1)) { start -= 1 }
            let word = text.substring(with: NSRange(location: start, length: end - start))
            guard start > 0, text.character(at: start - 1) == 46 else { return (word, nil) }
            var qualifierStart = start - 1
            while qualifierStart > 0, isWord(text.character(at: qualifierStart - 1)) || [34, 96].contains(text.character(at: qualifierStart - 1)) { qualifierStart -= 1 }
            let qualifier = text.substring(with: NSRange(location: qualifierStart, length: start - 1 - qualifierStart)).trimmingCharacters(in: CharacterSet(charactersIn: "\"`"))
            return (word, qualifier.isEmpty ? nil : qualifier)
        }

        func textView(_ textView: NSTextView, completions words: [String], forPartialWordRange charRange: NSRange, indexOfSelectedItem index: UnsafeMutablePointer<Int>?) -> [String] {
            guard let completions = parent.completions else { return [] }
            let (_, qualifier) = currentWord(textView)
            let partial = (textView.string as NSString).substring(with: charRange)
            let list = completions(partial, qualifier)
            // Nothing chosen until the user picks (↓ and ↩): typing on never inserts a guess.
            index?.pointee = -1
            return list
        }
        func textViewDidChangeSelection(_ notification: Notification) {
            guard let view else { return }
            let range = view.selectedRange()
            parent.selection = range.length > 0 ? (view.string as NSString).substring(with: range) : ""
        }
        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            // ⌘↩ runs (the button has the same shortcut; this covers the focused editor).
            if selector == #selector(NSResponder.insertNewline(_:)), NSEvent.modifierFlags.contains(.command) {
                parent.onRun?()
                return true
            }
            return false
        }

        func highlight() {
            guard let view, let storage = view.textStorage else { return }
            SQLHighlighter.apply(to: storage)
        }
    }
}

enum SQLHighlighter {
    static let keywords: Set<String> = Set("""
    select from where and or not in is null like ilike between exists insert into values update set delete create drop alter table view index \
    database schema primary key foreign references unique default on join left right inner outer full cross group by order having limit offset \
    as distinct union all case when then else end begin commit rollback transaction grant revoke to with returning explain show describe use \
    if replace truncate column add constraint check cascade asc desc true false count sum avg min max cast interval procedure function trigger \
    event declare return returns language
    """.split(separator: " ").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })

    private static let patterns: [(NSRegularExpression, NSColor)] = {
        func re(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p, options: []) }
        return [
            (re("\\b[0-9]+(\\.[0-9]+)?\\b"), .systemOrange),
            (re("'(?:[^'\\\\]|\\\\.|'')*'"), .systemGreen),
            (re("\"(?:[^\"]|\"\")*\"|`[^`]*`"), .systemTeal),
            (re("--[^\\n]*|#[^\\n]*|/\\*[\\s\\S]*?\\*/"), .secondaryLabelColor),
        ]
    }()
    private static let word = try! NSRegularExpression(pattern: "\\b[A-Za-z_]+\\b")

    static func apply(to storage: NSTextStorage) {
        let text = storage.string
        let all = NSRange(location: 0, length: (text as NSString).length)
        storage.beginEditing()
        storage.removeAttribute(.foregroundColor, range: all)
        storage.addAttribute(.foregroundColor, value: NSColor.labelColor, range: all)
        storage.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular), range: all)
        for match in word.matches(in: text, range: all) {
            let token = (text as NSString).substring(with: match.range).lowercased()
            if keywords.contains(token) {
                storage.addAttribute(.foregroundColor, value: NSColor.systemPurple, range: match.range)
                storage.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold), range: match.range)
            }
        }
        for (pattern, color) in patterns {
            for match in pattern.matches(in: text, range: all) {
                storage.addAttribute(.foregroundColor, value: color, range: match.range)
                storage.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular), range: match.range)
            }
        }
        storage.endEditing()
    }
}
