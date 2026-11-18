import Foundation

/// Sizes and dates shown or written by the app, formatted the same way everywhere.
enum Format {
    /// "1,2 MB"; numeric even for zero.
    static func fileSizeText(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: bytes)
    }

    /// "—" when the size is unknown.
    static func fileSizeText(_ bytes: Int?) -> String {
        bytes.map { fileSizeText(Int64($0)) } ?? "—"
    }

    /// ISO date for file names and plain-text files ("2026-11-13"); with the time, without colons
    /// so it is valid in any file name ("2026-11-13T094512Z").
    static func fileStamp(_ date: Date = Date(), time: Bool = false) -> String {
        guard time else { return date.formatted(.iso8601.year().month().day()) }
        return date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false)).replacingOccurrences(of: ":", with: "")
    }

    /// "13 nov 2026".
    static func shortDate(_ date: Date) -> String { date.formatted(date: .abbreviated, time: .omitted) }

    /// "13 nov 2026, 09:45".
    static func shortDateTime(_ date: Date) -> String { date.formatted(date: .abbreviated, time: .shortened) }
}

extension String {
    /// The text in capitals, for data that is written that way: SQL keywords, environment variable
    /// names. Never for what is shown as a heading (docs/estandar-ui.md, rule 16).
    var dataCapitals: String { uppercased() } // lint-ui: data written in capitals (SQL, environment variables), never a heading
}
