import Foundation

extension VaultSession {
    /// «Firma» of an app, in place of its page (from the app, or from a project's Resumen).
    func openSigning(_ app: UUID) {
        selection = .container(app)
        inspected = nil
        signing = app
    }

    /// Reads again what can be known of the files of an app and of the services every app shares
    /// (certificates, profiles, keys), for items kept before Stack read their certificates or
    /// capabilities. Values never leave the index; only metadata changes.
    @discardableResult func reread(_ app: UUID) async -> Int {
        guard let key = try? requireKey() else { return 0 }
        let generation = sessionGeneration
        let targets = index.items.filter { item in
            !item.files.isEmpty && (item.container == app || index.container(item.container)?.kind == .service)
        }
        var updated: [UUID: VaultMetadata] = [:]
        let disk = self.disk
        for item in targets {
            guard let file = item.files.first else { continue }
            let data = await Task.detached(priority: .userInitiated) { try? disk.readBlob(file.id, key: key) }.value
            guard (try? checkSession(generation)) != nil else { return 0 }
            guard let data else { continue }
            let metadata = await inspect(item, data: data, fileName: file.name)
            if metadata != item.metadata { updated[item.id] = metadata }
        }
        guard (try? checkSession(generation)) != nil, !updated.isEmpty else { return 0 }
        var candidate = index
        for position in candidate.items.indices {
            if let metadata = updated[candidate.items[position].id] { candidate.items[position].metadata = metadata }
        }
        do { try persist(candidate) } catch { message = L((error as? VaultError)?.messageKey ?? "vault.error.io"); return 0 }
        for id in updated.keys { disk.append(VaultAccessEntry(action: .editItem, target: id)) }
        return updated.count
    }
}
