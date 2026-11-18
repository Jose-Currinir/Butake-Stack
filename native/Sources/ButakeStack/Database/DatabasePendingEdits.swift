import Foundation

/// Unsaved edits of one table, kept by the client (not by the page) so that leaving the page,
/// opening another table or coming back never loses them.
struct PendingEdits: Equatable {
    var edits: [Int: [Int: String?]] = [:]
    var deleted: Set<Int> = []
    var inserted: [[String?]] = []
    /// What the row numbers above refer to: the page, filters and sorting they were made under.
    var page = 0
    var filters: [[String: String]] = []
    var sorts: [Sort] = []
    struct Sort: Equatable { var column: String; var descending: Bool }

    var count: Int { edits.count + deleted.count + inserted.count }
    var isEmpty: Bool { count == 0 }

    /// Drops what no longer fits the rows read again (fewer rows, other columns).
    mutating func prune(rows: Int, columns: Int) {
        edits = edits.filter { $0.key < rows }
        deleted = deleted.filter { $0 < rows }
        inserted = inserted.map { Array($0.prefix(columns)) + Array(repeating: nil, count: max(0, columns - $0.count)) }
    }
}

extension DatabaseClient {
    /// "<connection>/<database>/<schema>/<table>": one entry per table of each connection.
    static func pendingKey(_ selection: DBSelection) -> String {
        [selection.connection, selection.database ?? "", selection.schema ?? "", selection.table ?? ""].joined(separator: "/")
    }

    func pendingCount(_ key: String) -> Int { pendingEdits[key]?.count ?? 0 }

    /// Unsaved changes of the tables of a connection.
    func pendingCount(connection id: String) -> Int {
        pendingEdits.filter { $0.key.hasPrefix("\(id)/") }.values.reduce(0) { $0 + $1.count }
    }

    var pendingTotal: Int { pendingEdits.values.reduce(0) { $0 + $1.count } }

    /// Stores the edits of a table; an empty set removes the entry.
    func setPending(_ key: String, _ value: PendingEdits) {
        if value.isEmpty { pendingEdits[key] = nil } else { pendingEdits[key] = value }
    }

    func discardPending(connection id: String) {
        pendingEdits = pendingEdits.filter { !$0.key.hasPrefix("\(id)/") }
    }

    /// Before closing a connection: its unsaved edits are lost, so the user must agree.
    func confirmDiscardPending(connection: DBConnection) async -> Bool {
        let count = pendingCount(connection: connection.id)
        guard count > 0 else { return true }
        return await confirmSimple(String(format: L("db.confirm.disconnectEdits"), count, connection.name))
    }
}
