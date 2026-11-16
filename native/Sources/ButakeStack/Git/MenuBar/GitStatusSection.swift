import SwiftUI

/// The «Git» part of the menu bar panel (only while the tool is on): each repository with changes,
/// commits to bring or to send, or something to fix, with «Bajar», «Subir» and «Abrir»; under them,
/// «Buscar cambios cada 5 minutos» (off unless turned on) and «Actualizar».
struct GitStatusSection: View {
    /// Opens the window on the Git tool with that repository.
    let open: (String) -> Void
    @Bindable var board = GitStatusBoard.shared

    var body: some View {
        let rows = board.rows
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(L("git.statusBoard.title")).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Toggle(isOn: $board.autoFetch) { Text(L("git.statusBoard.autoFetchShort")).font(.caption2).foregroundStyle(.secondary) }
                    .toggleStyle(.checkbox).controlSize(.mini)
                    .help(L("git.statusBoard.autoFetch") + ". " + L("git.statusBoard.autoFetchHelp"))
                    .accessibilityLabel(L("git.statusBoard.autoFetch"))
                    .accessibilityIdentifier("panel.git.autoFetch")
                if board.refreshing { ProgressView().controlSize(.mini) }
                Button { Task { await board.refresh() } } label: { Label(L("common.refresh"), systemImage: Symbols.reload).labelStyle(.iconOnly) }
                    .buttonStyle(.borderless).controlSize(.small).disabled(board.refreshing)
                    .help(L("git.statusBoard.refreshHelp"))
                    .accessibilityIdentifier("panel.git.refresh")
            }
            .padding(.horizontal, 14)
            if rows.isEmpty {
                Label(L("git.statusBoard.allClear"), systemImage: Symbols.success)
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 14).padding(.vertical, 2)
                    .accessibilityIdentifier("panel.git.allClear")
            } else {
                // The repositories of a project of several parts together, under its name.
                let groups = board.grouped(rows)
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(groups, id: \.id) { group in
                            if let title = group.title {
                                Text(title).font(.caption2.weight(.medium)).foregroundStyle(.tertiary).lineLimit(1)
                                    .padding(.horizontal, 14).frame(height: 16)
                                    .accessibilityAddTraits(.isHeader)
                                    .accessibilityIdentifier("panel.git.composite.\(group.id)")
                            }
                            ForEach(group.rows) { GitStatusRowView(row: $0, open: open) }
                        }
                    }
                }
                .frame(height: min(CGFloat(rows.count) * 27 + CGFloat(groups.filter { $0.title != nil }.count) * 16, 178))
                .accessibilityIdentifier("panel.git.list")
            }
        }
        .task { await board.refresh() }
    }
}

/// A repository: its name, what it has pending and its actions at the end of the row.
private struct GitStatusRowView: View {
    let row: GitStatusRow
    let open: (String) -> Void
    @Bindable var board = GitStatusBoard.shared

    var body: some View {
        let failure = board.failures[row.entry.path]
        let working = board.working == row.entry.path
        HStack(spacing: 6) {
            Image(systemName: row.summary.problems > 0 || row.summary.unfinished || failure != nil ? Symbols.warning : Symbols.git)
                .foregroundStyle(row.summary.problems > 0 || row.summary.unfinished || failure != nil ? Brand.warning : .secondary)
                .font(.caption).frame(width: 16).accessibilityHidden(true)
            // One line: the name and, fainter, what it has pending.
            Text(row.entry.name).font(.callout).lineLimit(1).layoutPriority(1)
            Text(failure.map { $0.title } ?? row.detail).font(.caption2).foregroundStyle(failure == nil ? .secondary : Brand.warning)
                .lineLimit(1).truncationMode(.tail)
                .accessibilityLabel(failure.map { $0.title } ?? row.spokenDetail)
            Spacer(minLength: 4)
            if working {
                ProgressView().controlSize(.small)
            } else {
                if row.canPull {
                    Button { Task { await board.transfer(.pull, row.entry) } } label: {
                        Label(String(format: L("git.statusBoard.pull"), row.summary.behind), systemImage: Symbols.gitPull).labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless).disabled(board.working != nil)
                    .help(String(format: L("git.statusBoard.pullHelp"), row.summary.behind))
                    .accessibilityIdentifier("panel.git.pull.\(row.entry.name)")
                }
                if row.canPush {
                    Button { Task { await board.transfer(.push, row.entry) } } label: {
                        Label(String(format: L("git.statusBoard.push"), row.summary.ahead), systemImage: Symbols.gitPush).labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless).disabled(board.working != nil)
                    .help(String(format: L("git.statusBoard.pushHelp"), row.summary.ahead))
                    .accessibilityIdentifier("panel.git.push.\(row.entry.name)")
                }
            }
            Button { open(row.entry.path) } label: { Label(L("common.open"), systemImage: Symbols.forward).labelStyle(.iconOnly) }
                .buttonStyle(.borderless)
                .help(String(format: L("git.statusBoard.openHelp"), row.entry.name))
                .accessibilityIdentifier("panel.git.open.\(row.entry.name)")
        }
        .padding(.horizontal, 14).frame(height: 27)
        .help(row.entry.name + " · " + (failure.map { $0.detail.isEmpty ? $0.title : $0.detail } ?? row.spokenDetail))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(row.entry.name)
    }
}
