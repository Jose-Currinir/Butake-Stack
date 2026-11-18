import SwiftUI

struct MigrationBox: Identifiable {
    let plan: DiskPlan
    var id: String { "migration" }
}

/// The first time the sidebar follows the disk: the folders of before that already match the disk
/// are converted alone, and the rest is shown here, with what would move, before anything does.
struct DiskMigrationSheet: View {
    let store: StackStore
    let plan: DiskPlan

    var body: some View {
        SheetFrame(title: L("groups.migrate.title"), symbol: Symbols.folder, detail: L("groups.migrate.detail"), width: 560, height: 460,
                   actionTitle: L("groups.migrate.accept"), actionID: "groups.migrate.accept", cancelID: "groups.migrate.later",
                   cancelTitle: L("groups.migrate.later")) {
            await store.migrateToDisk(accept: true)
            return true
        } content: {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !plan.matches.isEmpty {
                        Label(String(format: L("groups.migrate.matches"), plan.matches.count), systemImage: Symbols.success)
                            .font(.uiCallout).foregroundStyle(.secondary)
                            .accessibilityIdentifier("groups.migrate.matches")
                    }
                    ForEach(plan.proposals) { proposal in
                        VStack(alignment: .leading, spacing: 4) {
                            Label(String(format: L("groups.migrate.folder"), proposal.path), systemImage: Symbols.newFolder).font(.uiHeadline)
                            ForEach(proposal.moves) { move in
                                HStack(spacing: 6) {
                                    Text(move.title).lineLimit(1)
                                    Text("→").foregroundStyle(.secondary)
                                    Text(store.relativeToProjects(move.to)).font(.uiCaption.monospaced()).foregroundStyle(.secondary)
                                        .lineLimit(1).truncationMode(.middle)
                                    if move.conflict {
                                        Text(L("groups.migrate.conflict")).font(.uiCaption).foregroundStyle(Brand.warning)
                                    }
                                }
                                .padding(.leading, 22)
                            }
                        }
                        .accessibilityIdentifier("groups.migrate.proposal.\(proposal.group)")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } status: {
            Button(L("groups.migrate.keep")) { Task { await store.migrateToDisk(accept: false) } }
                .help(L("groups.migrate.keepHelp")).accessibilityIdentifier("groups.migrate.keep")
        }
    }
}
