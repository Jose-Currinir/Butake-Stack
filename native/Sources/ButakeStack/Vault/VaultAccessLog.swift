import SwiftUI

/// The vault's access log as one more source of Registros: who did what and when, newest first.
/// It only holds ids; the names are shown while the vault is unlocked.
struct VaultAccessLog: View {
    @Bindable var vault: VaultSession
    @State private var entries: [VaultAccessEntry] = []
    @State private var wide = true

    var body: some View {
        // `readLog` already returns the newest first.
        Table(entries) {
            TableColumn(L("vault.log.date")) { entry in
                Text(entry.date.formatted(date: .numeric, time: .shortened)).monospacedDigit().lineLimit(1)
                    .help(entry.date.formatted(date: .complete, time: .standard))
            }
            .width(min: 100, ideal: 120)
            TableColumn(L("vault.log.action")) { entry in
                Label { Text(L("vault.action.\(entry.action.rawValue)")).lineLimit(1) } icon: {
                    Image(systemName: entry.action.symbol).foregroundStyle(tint(entry.action))
                }
                .help(L("vault.action.\(entry.action.rawValue)"))
            }
            .width(min: 100, ideal: 140)
            TableColumn(L("vault.log.target")) { entry in
                if let name = vault.targetName(entry.target) { Text(name).lineLimit(1).truncationMode(.middle).help(name) }
                else if entry.target != nil { Text(L(vault.isUnlocked ? "vault.log.removed" : "vault.log.locked")).foregroundStyle(.secondary).lineLimit(1) }
            }
            .width(min: 80, ideal: 150)
            // The least important: who, always this Mac's user; it gives its room at a narrow width.
            if wide {
                TableColumn(L("vault.log.user")) { entry in Text(entry.user).foregroundStyle(.secondary).lineLimit(1) }
                    .width(min: 70, ideal: 100)
            }
        }
        .onGeometryChange(for: Bool.self) { $0.size.width >= 560 } action: { wide = $0 }
        .font(.uiBody)
        .overlay {
            if entries.isEmpty { ContentUnavailableView(L("vault.log.empty"), systemImage: Symbols.logs) }
        }
        .accessibilityIdentifier("vault.log.table")
        .task {
            // New entries appear while it is on screen (the file is short and local).
            var modified: Date?
            while !Task.isCancelled {
                let read = await vault.accessLog(since: modified)
                modified = read.modified
                if let list = read.entries, list != entries { entries = list }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private func tint(_ action: VaultAccessEntry.Action) -> Color {
        switch action {
        case .unlockFailed, .deleteItem, .deleteContainer: Brand.danger
        case .reveal, .copy, .saveFile, .downloadFolder, .exportArchive: Brand.warning
        default: .secondary
        }
    }
}

extension VaultAccessEntry.Action {
    /// The symbol of each action in the access log, from the vault's own concepts.
    var symbol: String {
        switch self {
        case .unlock, .create: Symbols.unlocked
        case .unlockFailed: Symbols.unlockFailed
        case .lock: Symbols.locked
        case .reveal: Symbols.reveal
        case .copy: Symbols.copy
        case .saveFile, .downloadFolder: Symbols.dump
        case .exportArchive: Symbols.backup
        case .importArchive, .importFolder: Symbols.importing
        case .deleteItem, .deleteContainer: Symbols.delete
        case .moveToEnvironments: Symbols.environments
        case .moveToKeys: Symbols.key
        default: Symbols.edit
        }
    }
}
