import Foundation

/// «Importar carpeta…»: the chosen files of a scanned backup into the vault, without an app or service
/// that would stay empty; the accounts an earlier import kept as services of their own gathered into
/// their service; and «Quitar contenedores vacíos…», which only ever removes apps and services without
/// a single item.
extension VaultSession {
    /// Copies the chosen files of a scanned folder (the origin is only read), checking each hash. A group
    /// with nothing to import creates nothing: its README is told in the summary. The summary of what
    /// came in and what stayed out is kept as «Última importación» (paths and counts only).
    @discardableResult func importFolder(_ groups: [VaultFolder.Group], folders: [String] = []) async -> (added: Int, failed: Int) {
        var added = 0, failed = 0
        // The import belongs to this unlocked session: a lock and unlock meanwhile ends it.
        let generation = sessionGeneration
        var stored = Set<UUID>(), failedFiles = Set<UUID>(), kept = Set<UUID>()
        let total = groups.reduce(0) { $0 + $1.files.filter { $0.selected && !$0.kind.isRetired }.count }
        var done = 0
        importProgress = (0, total)
        defer { importProgress = nil }
        for group in groups {
            let chosen = group.files.filter { $0.selected && !$0.kind.isRetired }
            let legacy = legacyServices(of: group)
            let existing = group.existing ?? matchContainer(group)
            guard !chosen.isEmpty || existing != nil || !legacy.isEmpty else { continue }
            let notes = await group.readme.asyncFlatMap(Self.readText) ?? ""
            let containerId: UUID
            if let existing {
                containerId = existing
                if !notes.isEmpty { fillNotes(String(notes.prefix(100_000)), of: existing) }
            } else {
                guard let id = try? addContainer(kind: group.kind, name: group.name, bundleId: group.bundleId, notes: String(notes.prefix(100_000))) else {
                    failed += chosen.count
                    failedFiles.formUnion(chosen.map(\.id))
                    done += chosen.count
                    importProgress = (done, total)
                    continue
                }
                containerId = id
            }
            kept.insert(group.id)
            // The README of each account goes to the service's notes, under the account's name.
            var sections: [(heading: String, text: String)] = []
            for readme in group.readmes {
                guard let account = readme.account, let text = await Self.readText(readme.url) else { continue }
                sections.append((heading: VaultContainer.accountTitle(account), text: text))
            }
            appendNotes(sections, to: containerId)
            gather(legacy, into: containerId)
            // The group's items are encrypted one by one and the index is saved once at its end.
            var staged: [(id: UUID, item: VaultItem)] = []
            for candidate in chosen {
                defer { done += 1; importProgress = (done, total) }
                let fieldsOnly = candidate.dataFile == candidate.url || candidate.valueOnly
                var draft = VaultItem(container: containerId, section: group.kind == .app ? (candidate.section ?? .terceros) : nil,
                                      kind: candidate.kind, name: candidate.name, environment: candidate.environment)
                if group.kind == .service { draft.account = candidate.account.flatMap(VaultNames.account) }
                if let dataFile = candidate.dataFile, let text = await Self.readText(dataFile) {
                    let parsed = VaultFolder.parseDataFile(text)
                    draft.fields = parsed.fields
                    draft.notes = parsed.notes
                    if parsed.environment != .none { draft.environment = parsed.environment }
                    if fieldsOnly, let kind = parsed.kind {
                        guard !kind.isRetired else { continue }
                        draft.kind = kind
                    }
                } else if !candidate.valueOnly {
                    draft.fields = VaultInspector.suggestedFields(kind: candidate.kind, fileName: candidate.name)
                }
                // Passwords and values of the files beside it: read now, straight into its fields.
                VaultCompanions.merge(candidate.companions, kind: draft.kind, name: candidate.name, into: &draft.fields)
                var files: [(String, Data)] = []
                if !fieldsOnly {
                    guard let data = await Self.readData(candidate.url), data.count <= VaultFolder.maximumFileSize else {
                        failed += 1; failedFiles.insert(candidate.id); continue
                    }
                    files = [(candidate.name, data)]
                }
                if let item = try? await stageItem(draft, files: files) { staged.append((candidate.id, item)) }
                else { failed += 1; failedFiles.insert(candidate.id) }
            }
            let result = storeBatch(staged.map(\.item), generation: generation)
            for entry in staged {
                if result.contains(entry.item.id) { added += 1; stored.insert(entry.id) } else { failed += 1; failedFiles.insert(entry.id) }
            }
        }
        disk.append(VaultAccessEntry(action: .importFolder))
        if isUnlocked {
            var candidate = index
            candidate.lastImport = VaultImportSummary.make(groups, folders: folders, imported: stored, failed: failedFiles, kept: { kept.contains($0.id) })
            do { try persist(candidate) } catch { message = L("vault.import.summaryNotSaved") }
        }
        return (added, failed)
    }

    /// Adds already staged items to the index with a single save. If it fails, their blobs are
    /// removed and nothing counts as stored. Returns the ids that were stored.
    func storeBatch(_ items: [VaultItem], generation: UUID) -> Set<UUID> {
        guard !items.isEmpty else { return [] }
        guard (try? checkSession(generation)) != nil else {
            for item in items { for file in item.files { disk.deleteBlob(file.id) } }
            return []
        }
        let valid = items.filter { index.container($0.container) != nil }
        var candidate = index
        candidate.items.append(contentsOf: valid)
        do {
            guard !valid.isEmpty else { throw VaultError.invalidName }
            try persist(candidate)
        } catch {
            for item in items { for file in item.files { disk.deleteBlob(file.id) } }
            return []
        }
        for item in items where !valid.contains(where: { $0.id == item.id }) { for file in item.files { disk.deleteBlob(file.id) } }
        for item in valid { disk.append(VaultAccessEntry(action: .addItem, target: item.id)) }
        return Set(valid.map(\.id))
    }

    /// Text and bytes of a file of the folder, read off the main actor.
    nonisolated static func readText(_ url: URL) async -> String? {
        await Task.detached(priority: .userInitiated) { try? String(contentsOf: url, encoding: .utf8) }.value
    }
    nonisolated static func readData(_ url: URL) async -> Data? {
        await Task.detached(priority: .userInitiated) { try? Data(contentsOf: url) }.value
    }

    func matchContainer(_ group: VaultFolder.Group) -> UUID? { Self.matchContainer(group, in: index) }

    nonisolated static func matchContainer(_ group: VaultFolder.Group, in index: VaultIndex) -> UUID? {
        index.containers.first { container in
            guard container.kind == group.kind else { return false }
            if let bundle = group.bundleId, container.bundleId == bundle { return true }
            return container.folderName.lowercased() == group.folderName.lowercased()
        }?.id
    }

    /// The services an earlier import made of the accounts of this one (`cloudflare/cuenta`) that hold
    /// items. The empty ones are not gathered (that would leave an empty service): «Quitar contenedores
    /// vacíos…» removes them.
    func legacyServices(of group: VaultFolder.Group) -> [UUID] { Self.legacyServices(of: group, in: index) }

    nonisolated static func legacyServices(of group: VaultFolder.Group, in index: VaultIndex) -> [UUID] {
        guard group.kind == .service else { return [] }
        let prefix = group.name.lowercased() + "/"
        let used = Set(index.items.map(\.container))
        return index.containers.filter { $0.kind == .service && $0.name.lowercased().hasPrefix(prefix) && used.contains($0.id) }.map(\.id)
    }

    /// Marks what is already in the vault (same hash in the same service or app, or in the accounts an
    /// earlier import kept apart) and leaves it unselected, like the kinds the vault no longer keeps (a
    /// project's .env, an SSH key). Dumps and quarantines are not read.
    func markDuplicates(_ groups: [VaultFolder.Group]) -> [VaultFolder.Group] { Self.markDuplicates(groups, in: index) }

    /// The same check on a copy of the index, so it can run off the main actor.
    nonisolated static func markDuplicates(_ groups: [VaultFolder.Group], in index: VaultIndex) -> [VaultFolder.Group] {
        groups.map { group in
            var group = group
            for position in group.files.indices where group.files[position].kind.isRetired { group.files[position].selected = false }
            group.existing = matchContainer(group, in: index)
            group.legacy = legacyServices(of: group, in: index)
            let containers = [group.existing].compactMap { $0 } + group.legacy
            guard !containers.isEmpty else { return group }
            let items = containers.flatMap { index.items(in: $0) }
            let hashes = Set(items.flatMap { $0.files.map(\.sha256) })
            let names = Set(items.filter(\.files.isEmpty).map(\.name))
            for position in group.files.indices where !group.files[position].sealed {
                let file = group.files[position]
                // Fields only (a lone .datos.txt): already there when an item without files has its name.
                if file.dataFile == file.url || file.valueOnly {
                    if names.contains(file.name) { group.files[position].duplicate = true; group.files[position].selected = false }
                    continue
                }
                let hash = file.sha256.isEmpty ? (try? Data(contentsOf: file.url)).map(VaultCrypto.sha256) : file.sha256
                if let hash, hashes.contains(hash) {
                    group.files[position].duplicate = true
                    group.files[position].selected = false
                }
            }
            return group
        }
    }

    /// Notes under a heading each (an account's README), added once: a text already there is not repeated.
    func appendNotes(_ sections: [(heading: String, text: String)], to container: UUID) {
        guard let position = index.containers.firstIndex(where: { $0.id == container }) else { return }
        let before = index.containers[position].notes
        let notes = sections.reduce(before) { notes, section in Self.appending(section.text, heading: section.heading, to: notes) }
        guard notes != before else { return }
        var candidate = index
        candidate.containers[position].notes = String(notes.prefix(100_000))
        try? persist(candidate)
    }

    static func appending(_ text: String, heading: String, to notes: String) -> String {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, !notes.contains(body) else { return notes }
        let block = "## \(heading)\n\n\(body)"
        return notes.isEmpty ? block : notes + "\n\n" + block
    }

    /// The accounts an earlier import kept as services (`cloudflare/cuenta`) into their service: their
    /// items move with the account they came from and their notes go under its name. No item is
    /// deleted; the services left without items are removed. A quarantine's notes are not carried.
    func gather(_ legacy: [UUID], into target: UUID) {
        guard let parent = index.container(target), parent.kind == .service else { return }
        var candidate = index
        var notes = parent.notes
        var moved: [UUID] = []
        for id in legacy where id != target {
            guard let old = candidate.container(id), old.name.count > parent.name.count + 1 else { continue }
            let rest = String(old.name.dropFirst(parent.name.count + 1))
            for position in candidate.items.indices where candidate.items[position].container == id {
                candidate.items[position].container = target
                let joined = [rest, candidate.items[position].account].compactMap { $0 }.joined(separator: "/")
                candidate.items[position].account = VaultNames.account(joined) ?? VaultNames.account(rest)
            }
            if !rest.split(separator: "/").contains(where: { VaultBackupLayout.excluded(folder: String($0)) == .quarantine }) {
                notes = Self.appending(old.notes, heading: VaultContainer.accountTitle(rest), to: notes)
            }
            candidate.containers.removeAll { $0.id == id }
            moved.append(id)
        }
        guard !moved.isEmpty, let position = candidate.containers.firstIndex(where: { $0.id == target }) else { return }
        candidate.containers[position].notes = String(notes.prefix(100_000))
        guard (try? persist(candidate)) != nil else { return }
        if let selected = selection, moved.contains(where: { selected == .container($0) }) { selection = .container(target) }
        disk.append(VaultAccessEntry(action: .editContainer, target: target))
        for id in moved { disk.append(VaultAccessEntry(action: .deleteContainer, target: id)) }
    }

    // MARK: Empty apps and services

    /// Apps and services without a single item (what an earlier import left: a folder with only a README).
    var emptyContainers: [VaultContainer] {
        let used = Set(index.items.map(\.container))
        return index.containers.filter { !used.contains($0.id) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Removes the apps and services that hold no item, after the user confirms. An account kept as a
    /// service of its own leaves its notes in its service, when there is one and it is not a quarantine.
    /// Never removes an item: a container that has one is kept.
    @discardableResult func removeEmptyContainers() throws -> Int {
        _ = try requireKey()
        let empty = emptyContainers
        guard !empty.isEmpty else { return 0 }
        let ids = Set(empty.map(\.id))
        var candidate = index
        for old in empty where old.kind == .service && old.name.contains("/") && !old.notes.isEmpty {
            let parts = old.name.split(separator: "/").map(String.init)
            guard !parts.contains(where: { VaultBackupLayout.excluded(folder: $0) == .quarantine }),
                  let position = candidate.containers.firstIndex(where: {
                      $0.kind == .service && !ids.contains($0.id) && $0.name.lowercased() == parts[0].lowercased()
                  }) else { continue }
            candidate.containers[position].notes = String(Self.appending(old.notes, heading: VaultContainer.accountTitle(parts.dropFirst().joined(separator: "/")),
                                                                         to: candidate.containers[position].notes).prefix(100_000))
        }
        let used = Set(candidate.items.map(\.container))
        candidate.containers.removeAll { ids.contains($0.id) && !used.contains($0.id) }
        try persist(candidate)
        if case .container(let id)? = selection, ids.contains(id) { selection = nil }
        for id in ids { disk.append(VaultAccessEntry(action: .deleteContainer, target: id)) }
        return ids.count
    }
}

private extension Optional {
    /// `flatMap` with an async transform.
    func asyncFlatMap<T>(_ transform: (Wrapped) async -> T?) async -> T? {
        guard let value = self else { return nil }
        return await transform(value)
    }
}
