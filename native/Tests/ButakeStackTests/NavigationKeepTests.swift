import Foundation
import Testing
@testable import ButakeStack

@MainActor @Suite("Navigation keeps what the user did")
struct NavigationKeepTests {
    private static let users = DBSelection(connection: "pg", database: "shop", schema: "public", table: "users")
    private static let orders = DBSelection(connection: "pg", database: "shop", schema: "public", table: "orders")

    @Test func tableEditsSurviveLeavingThePage() {
        let client = DatabaseClient()
        let key = DatabaseClient.pendingKey(Self.users)
        var edits = PendingEdits()
        edits.edits = [2: [1: .some("ana@example.test")]]
        edits.deleted = [4]
        edits.page = 1
        client.setPending(key, edits)
        // The page goes away and comes back: what it reads is the same.
        #expect(client.pendingEdits[key]?.count == 2)
        #expect(client.pendingEdits[key]?.page == 1)
        #expect(client.pendingCount(DatabaseClient.pendingKey(Self.orders)) == 0)
        #expect(client.pendingCount(connection: "pg") == 2)
        #expect(client.pendingTotal == 2)
    }

    @Test func emptyEditsRemoveTheEntry() {
        let client = DatabaseClient()
        let key = DatabaseClient.pendingKey(Self.users)
        client.setPending(key, PendingEdits(inserted: [[nil, "x"]]))
        #expect(client.pendingCount(key) == 1)
        client.setPending(key, PendingEdits())
        #expect(client.pendingEdits[key] == nil)
    }

    @Test func pruneDropsRowsThatNoLongerExist() {
        var edits = PendingEdits(edits: [0: [0: "a"], 9: [0: "b"]], deleted: [1, 7], inserted: [["1"]])
        edits.prune(rows: 3, columns: 2)
        #expect(edits.edits.keys.sorted() == [0])
        #expect(edits.deleted == [1])
        #expect(edits.inserted == [["1", nil]])
    }

    @Test func discardingAConnectionKeepsTheOthers() {
        let client = DatabaseClient()
        client.setPending(DatabaseClient.pendingKey(Self.users), PendingEdits(deleted: [1]))
        let other = DBSelection(connection: "pg2", database: "shop", table: "users")
        client.setPending(DatabaseClient.pendingKey(other), PendingEdits(deleted: [1, 2]))
        client.discardPending(connection: "pg")
        #expect(client.pendingTotal == 2)
        #expect(client.pendingCount(connection: "pg") == 0)
    }

    @Test func hidingTheListIsRememberedPerPage() throws {
        let suite = "cl.butake.stack.test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let visibility = ContentColumnVisibility(defaults: defaults)
        #expect(!visibility.isHidden(.tool("mail")))
        visibility.toggle(.tool("mail"))
        #expect(visibility.isHidden(.tool("mail")))
        #expect(!visibility.isHidden(.tool("git")))
        // A page without a list has nothing to hide.
        visibility.toggle(.home)
        #expect(!visibility.isHidden(.home))
        #expect(ContentColumnVisibility(defaults: defaults).isHidden(.tool("mail")))
        visibility.toggle(.tool("mail"))
        #expect(!ContentColumnVisibility(defaults: defaults).isHidden(.tool("mail")))
    }

    @Test func scrollMemoryKeepsTheLatestFiftyPages() {
        let memory = ScrollMemory()
        for index in 0..<60 { memory.set("page.\(index)", CGFloat(index * 10)) }
        #expect(memory.offset("page.0") == nil)
        #expect(memory.offset("page.59") == 590)
        memory.set("page.10", 5)
        memory.set("page.60", 1)
        #expect(memory.offset("page.10") == 5)
        memory.forget("page.10")
        #expect(memory.offset("page.10") == nil)
    }
}
