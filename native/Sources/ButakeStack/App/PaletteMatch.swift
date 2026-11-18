import Foundation

/// How the palette (and the shortcuts sheet) match what is typed: without accents or capitals, every
/// word must appear, and the rows are ordered by how well the title fits.
enum PaletteMatch {
    /// «Configuración» → «configuracion».
    static func fold(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
    }

    /// nil when a word is nowhere in the title or the detail. Higher is better: a title that starts
    /// with the whole query beats a title with a word that starts like each typed word, which beats a
    /// title that merely contains them, which beats a match in the detail only.
    static func score(query: String, title: String, detail: String = "") -> Int? {
        let words = fold(query).split(separator: " ").map(String.init)
        guard !words.isEmpty else { return 0 }
        let title = fold(title), detail = fold(detail)
        let titleWords = title.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        var total = 0
        for word in words {
            if title.hasPrefix(word) { total += 3 }
            else if titleWords.contains(where: { $0.hasPrefix(word) }) { total += 2 }
            else if title.contains(word) { total += 1 }
            else if detail.contains(word) { total += 0 }
            else { return nil }
        }
        let whole = words.joined(separator: " ")
        return total + (title == whole ? 150 : title.hasPrefix(whole) ? 100 : 0)
    }

    /// `items` that match, best first; equal scores keep their order.
    static func rank<T>(_ items: [T], query: String, title: (T) -> String, detail: (T) -> String) -> [T] {
        guard !fold(query).split(separator: " ").isEmpty else { return items }
        let scored = items.enumerated().compactMap { index, item -> (Int, Int, T)? in
            score(query: query, title: title(item), detail: detail(item)).map { ($0, index, item) }
        }
        return scored.sorted { $0.0 != $1.0 ? $0.0 > $1.0 : $0.1 < $1.1 }.map(\.2)
    }

    /// The title cut into pieces, `true` for the ones that matched a typed word (shown in semibold).
    static func segments(of title: String, query: String) -> [(text: String, matched: Bool)] {
        var ranges: [Range<String.Index>] = []
        for word in query.split(separator: " ") {
            if let range = title.range(of: String(word), options: [.diacriticInsensitive, .caseInsensitive]) { ranges.append(range) }
        }
        ranges.sort { $0.lowerBound < $1.lowerBound }
        var merged: [Range<String.Index>] = []
        for range in ranges {
            if let last = merged.last, range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        var pieces: [(String, Bool)] = []
        var cursor = title.startIndex
        for range in merged {
            if cursor < range.lowerBound { pieces.append((String(title[cursor..<range.lowerBound]), false)) }
            pieces.append((String(title[range]), true))
            cursor = range.upperBound
        }
        if cursor < title.endIndex { pieces.append((String(title[cursor...]), false)) }
        return pieces
    }
}

/// The last palette rows used, kept as ids only (nothing of what they open) in UserDefaults.
enum PaletteRecents {
    static let key = "palette.recents"
    static let limit = 8
    static let prefix = "recent."

    static func ids(_ defaults: UserDefaults = .standard) -> [String] {
        defaults.stringArray(forKey: key) ?? []
    }

    /// The row with `id` goes first; no duplicates; at most `limit`.
    static func record(_ id: String, _ defaults: UserDefaults = .standard) {
        let base = id.hasPrefix(prefix) ? String(id.dropFirst(prefix.count)) : id
        defaults.set(Array(([base] + ids(defaults).filter { $0 != base }).prefix(limit)), forKey: key)
    }

    static func clear(_ defaults: UserDefaults = .standard) { defaults.removeObject(forKey: key) }
}
