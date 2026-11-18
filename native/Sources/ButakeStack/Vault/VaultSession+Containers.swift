import Foundation

/// Apps and services of the vault: add, rename and delete, each saved at once and written to the access log.
extension VaultSession {
    @discardableResult func addContainer(kind: VaultContainer.Kind, name: String, bundleId: String?, notes: String = "", project: String? = nil) throws -> UUID {
        _ = try requireKey()
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let bundle = bundleId?.trimmingCharacters(in: .whitespaces).lowercased()
        switch kind {
        case .app:
            guard VaultNames.isSafeComponent(clean), !clean.contains("("), bundle.map({ $0.isEmpty || VaultNames.isBundleId($0) }) ?? true else { throw VaultError.invalidName }
        case .service:
            guard VaultNames.isServicePath(clean) else { throw VaultError.invalidName }
        }
        var container = VaultContainer(kind: kind, name: clean, bundleId: bundle?.isEmpty == true ? nil : bundle, notes: notes)
        if kind == .app { container.project = project }
        guard !index.containers.contains(where: { $0.kind == kind && $0.folderName.lowercased() == container.folderName.lowercased() }) else { throw VaultError.invalidName }
        var candidate = index
        candidate.containers.append(container)
        try persist(candidate)
        disk.append(VaultAccessEntry(action: .addContainer, target: container.id))
        return container.id
    }

    func updateContainer(_ container: VaultContainer) throws {
        guard let position = index.containers.firstIndex(where: { $0.id == container.id }) else { return }
        switch container.kind {
        case .app: guard VaultNames.isSafeComponent(container.name), container.bundleId.map(VaultNames.isBundleId) ?? true else { throw VaultError.invalidName }
        case .service: guard VaultNames.isServicePath(container.name) else { throw VaultError.invalidName }
        }
        var candidate = index
        candidate.containers[position] = container
        try persist(candidate)
        disk.append(VaultAccessEntry(action: .editContainer, target: container.id))
    }

    func deleteContainer(_ id: UUID) throws {
        _ = try requireKey()
        let items = index.items(in: id)
        var candidate = index
        candidate.items.removeAll { $0.container == id }
        candidate.containers.removeAll { $0.id == id }
        try persist(candidate)
        for item in items { for file in item.files { disk.deleteBlob(file.id) } }
        if selection == .container(id) { selection = nil }
        disk.append(VaultAccessEntry(action: .deleteContainer, target: id))
    }
}
