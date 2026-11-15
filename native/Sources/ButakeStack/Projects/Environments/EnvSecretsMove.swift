import Foundation
import Security

/// Renaming a project (P-41): the Entornos items of its old id go to the new one. Each item is copied
/// as it is (its data and the names in its attributes, never decoded, so no value is looked at or
/// shown), read back, and only then are the old ones deleted. If the Keychain does not answer,
/// nothing of the new id stays and the old items are kept: the rename does not happen (or, started
/// from the command line, stays pending until the next try).
extension EnvSecrets {
    enum MoveFailure: Error, Equatable {
        case unavailable(OSStatus)
        /// The new id already has an item with other data.
        case conflict
        case write, verification
    }

    /// Copies every item of `site` (single and old per-variable items) to `newSite`; returns the
    /// accounts it created, to remove them if the rename does not go through. An item already
    /// copied with the same data (an earlier try that stopped halfway) counts as copied.
    func copyAll(site: String, to newSite: String) throws -> [String] {
        let existing = Set(items.list(prefix: newSite + "/").map(\.account))
        var created: [String] = []
        do {
            for entry in items.list(prefix: site + "/") {
                let target = newSite + String(entry.account.dropFirst(site.count))
                let data: Data
                switch items.read(entry.account) {
                case .found(let found): data = found
                case .missing: continue
                case .failed(let status): throw MoveFailure.unavailable(status)
                }
                if existing.contains(target) {
                    guard case .found(let there) = items.read(target), there == data else { throw MoveFailure.conflict }
                    continue
                }
                guard items.write(data, account: target, label: Self.label(target), attributes: entry.attributes) else { throw MoveFailure.write }
                created.append(target)
                guard case .found(let back) = items.read(target), back == data else { throw MoveFailure.verification }
            }
        } catch {
            removeCopies(created)
            throw error
        }
        return created
    }

    /// Undoes `copyAll` when the rename did not go through.
    func removeCopies(_ accounts: [String]) {
        for account in accounts { items.remove(account, quietly: true) }
    }

    /// `copyAll`, then the old items go: what a rename started outside the app leaves to do.
    func move(site: String, to newSite: String) throws {
        _ = try copyAll(site: site, to: newSite)
        deleteAll(site: site)
    }

    /// "Stack · <site> · <env>" (and " · <KEY>" for an old per-variable item).
    static func label(_ account: String) -> String {
        "Stack · " + account.split(separator: "/", omittingEmptySubsequences: false).joined(separator: " · ")
    }
}
