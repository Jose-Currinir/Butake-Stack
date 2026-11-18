import Foundation

/// What a folder import brings and leaves out, by category: in the preview (from the current ticks) and,
/// once imported, kept in the vault's index as «Última importación». Only relative paths, reasons and
/// counts: never what a file holds.
struct VaultImportSummary: Codable, Sendable, Equatable {
    enum Category: String, Codable, CaseIterable, Sendable, Identifiable {
        case imported, readme, history, dump, env, quarantine, duplicate, unrecognized, unselected
        var id: String { rawValue }
        /// What the summary can tick to include: history and what nobody recognized. Dumps (personal
        /// data) and quarantines (sensitive material) are never offered here.
        var includable: Bool { self == .history || self == .unrecognized }
        /// Left out of the import.
        var isLeftOut: Bool { self != .imported && self != .readme }
    }

    struct Entry: Codable, Sendable, Hashable {
        var path: String
        /// A reason key (`vault.summary.reason.<reason>`), never a value.
        var reason: String?
    }

    var date = Date()
    /// The names of the folders read (their last component).
    var folders: [String] = []
    /// By `Category.rawValue`.
    var entries: [String: [Entry]] = [:]

    func list(_ category: Category) -> [Entry] { entries[category.rawValue] ?? [] }
    func count(_ category: Category) -> Int { list(category).count }

    /// Why a file stays out, whatever its tick: nil for a file that is imported when ticked.
    static func leftCategory(_ file: VaultFolder.Candidate) -> Category? {
        switch file.exclusion {
        case .quarantine: return .quarantine
        case .dump: return .dump
        default: break
        }
        if file.kind == .envFile { return .env }
        if file.exclusion != nil { return .history }
        if file.duplicate || file.copyOf != nil { return .duplicate }
        if file.unrecognized || file.kind.isRetired { return .unrecognized }
        return nil
    }

    static func reason(_ file: VaultFolder.Candidate, in category: Category) -> String? {
        switch category {
        case .history: file.exclusion?.rawValue
        case .duplicate: file.duplicate ? "already" : "copy"
        case .unrecognized: file.kind.isRetired ? file.kind.rawValue : "unknown"
        default: nil
        }
    }

    /// The summary of these groups: `imported` are the files stored (after an import); without it, the
    /// ticked ones (the preview). `kept` says whether a group has (or will have) its app or service, where
    /// its READMEs go as notes.
    static func make(_ groups: [VaultFolder.Group], folders: [String], imported: Set<UUID>? = nil, failed: Set<UUID> = [],
                     kept: (VaultFolder.Group) -> Bool = { $0.bringsSomething }, date: Date = Date()) -> VaultImportSummary {
        var entries: [Category: [Entry]] = [:]
        func add(_ category: Category, _ path: String, _ reason: String? = nil) { entries[category, default: []].append(Entry(path: path, reason: reason)) }
        for group in groups {
            let keeps = kept(group)
            for readme in group.readmes { add(.readme, readme.relative, keeps ? nil : "notKept") }
            for file in group.files {
                let stored = imported.map { $0.contains(file.id) } ?? (file.selected && !file.kind.isRetired)
                if stored { add(.imported, file.relative); continue }
                if let category = leftCategory(file) { add(category, file.relative, reason(file, in: category)) }
                else { add(.unselected, file.relative, failed.contains(file.id) ? "failed" : nil) }
            }
            for skipped in group.skipped { add(.unrecognized, skipped.relative, "skip.\(skipped.reason.rawValue)") }
        }
        return VaultImportSummary(date: date, folders: folders,
                                  entries: Dictionary(uniqueKeysWithValues: entries.map { ($0.key.rawValue, $0.value) }))
    }

    /// Every reason a summary can give (for the texts).
    static var reasons: [String] {
        VaultBackupLayout.Exclusion.allCases.filter { !$0.isSealed }.map(\.rawValue)
            + ["already", "copy", "unknown", "notKept", "failed"]
            + VaultItemKind.allCases.filter(\.isRetired).map(\.rawValue)
            + VaultFolder.Skipped.Reason.allCases.map { "skip.\($0.rawValue)" }
    }
}
