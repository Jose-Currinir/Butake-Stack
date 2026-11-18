#if DEBUG
import Foundation

extension QAHooks {
    /// BUTAKE_QA_DB_PENDING: the tree of the selected connection with a table holding unsaved edits.
    static func seedPendingEdits(_ client: DatabaseClient) {
        guard env["BUTAKE_QA_DB_PENDING"] != nil, let selection = client.selection else { return }
        let database = selection.database ?? "tienda"
        client.status[selection.connection] = .ok("MySQL 9.1")
        client.databases[selection.connection] = [DBDatabase(name: database, size: nil, tables: 3, system: false)]
        client.objects["\(selection.connection)/\(database)"] = ["clientes", "pedidos", "productos"].map {
            DBObject(schema: nil, name: $0, view: false, rows: nil, size: nil, engine: nil)
        }
        client.expanded.formUnion([selection.connection, "\(selection.connection)/\(database)"])
        let table = DBSelection(connection: selection.connection, database: database, table: selection.table ?? "clientes")
        client.setPending(DatabaseClient.pendingKey(table), PendingEdits(edits: [0: [1: "ana@ejemplo.test"], 3: [2: nil]], deleted: [5]))
    }
}
#endif
