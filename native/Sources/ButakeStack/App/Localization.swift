import Foundation

/// The visible text for `key`. A missing key shows the key itself; in debug builds it also stops
/// at an assertion so the gap is found before release.
func L(_ key: String) -> String {
    guard let text = localized(key) else {
        assertionFailure("Missing Localizable.strings key: \(key)")
        return key
    }
    return text
}

/// The visible text for `key`, or nil when the table has no such key (for optional texts).
func localized(_ key: String) -> String? {
    let text = Bundle.module.localizedString(forKey: key, value: missingMarker, table: "Localizable")
    return text == missingMarker ? nil : text
}

private let missingMarker = "\u{0}missing\u{0}"
