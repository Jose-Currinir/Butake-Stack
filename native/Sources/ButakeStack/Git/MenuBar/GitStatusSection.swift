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
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(L("git.statusBoard.title")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if board.refreshing { ProgressView().controlSize(.mini) }
                Button { Task { await board.refresh() } } label: { Label(L("common.refresh"), systemImage: Symbols.reload).labelStyle(.iconOnly) }
                    .buttonStyle(.borderless).controlSize(.small).disabled(board.refreshing)
                    .help(L("git.statusBoard.refreshHelp"))
                    .accessibilityIdentifier("panel.git.refresh")
            }
            .padding(.horizontal, 14)
            if rows.isEmpty {
                Label(L("git.statusBoard.allClear"), systemImage: Symbols.success)
                    .font(.callout).foregroundStyle(.secondary)
                    .padding(.horizontal, 14).padding(.vertical, 4)
                    .accessibilityIdentifier("panel.git.allClear")
            } else {
                // The repositories of a project of several parts together, under its name.
                let groups = board.grouped(rows)
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(groups, id: \.id) { group in
                            if let title = group.title {
                                Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary).lineLimit(1)
                                    .padding(.horizontal, 14).padding(.top, 4)
                                    .accessibilityAddTraits(.isHeader)
                                    .accessibilityIdentifier("panel.git.composite.\(group.id)")
                            }
                            ForEach(group.rows) { GitStatusRowView(row: $0, open: open) }
                        }
                    }
                }
                .frame(height: min(CGFloat(rows.count) * 46 + CGFloat(groups.filter { $0.title != nil }.count) * 22, 260))
                .accessibilityIdentifier("panel.git.list")
            }
            Toggle(isOn: $board.autoFetch) {
                Text(L("git.statusBoard.autoFetch")).font(.caption)
            }
            .toggleStyle(.checkbox).controlSize(.small)
            .help(L("git.statusBoard.autoFetchHelp"))
            .padding(.horizontal, 14)
            .accessibilityIdentifier("panel.git.autoFetch")
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
        HStack(spacing: 8) {
            Image(systemName: row.summary.problems > 0 || row.summary.unfinished || failure != nil ? Symbols.warning : Symbols.git)
                .foregroundStyle(row.summary.problems > 0 || row.summary.unfinished || failure != nil ? Brand.warning : .secondary)
                .frame(width: 18).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(row.entry.name).font(.callout.weight(.medium)).lineLimit(1)
                Text(failure.map { $0.title } ?? row.detail).font(.caption).foregroundStyle(failure == nil ? .secondary : Brand.warning)
                    .lineLimit(1).truncationMode(.middle)
                    .help(failure.map { $0.detail.isEmpty ? $0.title : $0.detail } ?? row.spokenDetail)
                    .accessibilityLabel(failure.map { $0.title } ?? row.spokenDetail)
            }
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
        .padding(.horizontal, 10).padding(.vertical, 5)
        .padding(.horizontal, 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(row.entry.name)
    }
}
