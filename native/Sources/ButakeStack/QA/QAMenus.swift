#if DEBUG
import AppKit

extension QAHooks {
    // MARK: Menus

    /// The menu bar as text: titles in order, shortcuts, disabled items and repeated shortcuts.
    static func menuOutline() -> String {
        var lines: [String] = []
        var shortcuts: [String: [String]] = [:]
        func walk(_ menu: NSMenu, depth: Int) {
            // As if the menu opened: SwiftUI refreshes its items then.
            menu.delegate?.menuNeedsUpdate?(menu)
            menu.delegate?.menuWillOpen?(menu)
            menu.update()
            for item in menu.items where !item.isHidden {
                let indent = String(repeating: "    ", count: depth)
                if item.isSeparatorItem { lines.append(indent + "—"); continue }
                var line = indent + item.title
                let key = shortcut(item)
                if !key.isEmpty {
                    line += "    " + key
                    shortcuts[key, default: []].append(item.title)
                }
                if !item.isEnabled && item.submenu == nil { line += "    [desactivado]" }
                lines.append(line)
                if let submenu = item.submenu { walk(submenu, depth: depth + 1) }
            }
            menu.delegate?.menuDidClose?(menu)
        }
        if let main = NSApp.mainMenu { walk(main, depth: 0) }
        let repeated = shortcuts.filter { $0.value.count > 1 }.sorted { $0.key < $1.key }
        lines.append("")
        lines.append(repeated.isEmpty ? "Atajos repetidos: ninguno" : "Atajos repetidos:")
        for (key, titles) in repeated { lines.append("    \(key): " + titles.joined(separator: " · ")) }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func shortcut(_ item: NSMenuItem) -> String {
        guard !item.keyEquivalent.isEmpty else { return "" }
        let flags = item.keyEquivalentModifierMask
        var text = ""
        if flags.contains(.function) { text += "fn " }
        if flags.contains(.control) { text += "⌃" }
        if flags.contains(.option) { text += "⌥" }
        if flags.contains(.shift) || item.keyEquivalent != item.keyEquivalent.lowercased() { text += "⇧" }
        if flags.contains(.command) { text += "⌘" }
        let names: [String: String] = ["\u{8}": "⌫", "\u{7f}": "⌫", "\r": "↩", "\u{1b}": "⎋", "\t": "⇥", " ": "Espacio"]
        let key = item.keyEquivalent
        if let name = names[key] { return text + name }
        if let scalar = key.unicodeScalars.first, (0xF700...0xF8FF).contains(scalar.value) { return text + "F\(scalar.value)" }
        return text + key.localizedUppercase
    }
}
#endif
