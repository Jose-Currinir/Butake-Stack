import SwiftUI

/// «Organizar commits»: the branch's commits that are not on the remote yet, to reorder (drag or
/// «Subir»/«Bajar»), combine, rename or remove, without an editor or a console. A copy of the
/// branch is kept first, so Historial offers «Deshacer» afterwards.
struct GitOrganizeSheet: View {
    let repository: GitRepository
    @State private var candidates: GitRewriteCandidates?
    @State private var plan: GitOrganizePlan?
    @State private var selection: Set<UUID> = []
    @State private var failure: String?
    @State private var confirming = false
    @State private var applying = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 720, idealWidth: 820, minHeight: 520, idealHeight: 620)
        .task { await load() }
        .confirmationDialog(L("git.organize.confirmTitle"), isPresented: $confirming) {
            Button(L("git.organize.apply")) { Task { await apply() } }
                .accessibilityIdentifier("git.organize.confirm")
            Button(L("common.cancel"), role: .cancel) {}.accessibilityIdentifier("git.organize.confirmCancel")
        } message: {
            Text(summary + "\n\n" + L("git.organize.confirmDetail"))
        }
        .accessibilityIdentifier("git.organize.sheet")
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: GitHistoryQA.organizeNote)) { note in
            guard let command = note.object as? String, var current = plan else { return }
            if command.hasPrefix("combine:"), let count = Int(command.dropFirst(8)) {
                selection = Set(current.items.prefix(count).map(\.id))
                if let joined = current.combine(selection) { selection = [joined] }
                plan = current
            } else if command == "apply" {
                Task { await apply() }
            }
        }
        #endif
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            IconTile(symbol: Symbols.gitOrganize, size: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(L("git.organize.title")).font(.uiTitle3.weight(.semibold))
                Text(String(format: L("git.organize.detail"), repository.branchTitle)).font(.uiCaption).foregroundStyle(.secondary)
                if let candidates {
                    Text(L("git.organize.boundary.\(candidates.boundary)")).font(.uiCaption).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(16)
    }

    @ViewBuilder private var content: some View {
        if let current = plan, !current.items.isEmpty {
            VStack(spacing: 0) {
                actions(current)
                List(selection: $selection) {
                    ForEach(Binding(get: { plan?.items ?? [] }, set: { plan?.items = $0 })) { $item in
                        GitOrganizeRow(item: $item, single: selection == [item.id]).tag(item.id)
                    }
                    .onMove { from, to in plan?.items.move(fromOffsets: from, toOffset: to) }
                }
                .listStyle(.inset)
                .themedScroll()
                .accessibilityIdentifier("git.organize.list")
                if let failure {
                    Label(failure, systemImage: Symbols.warning).font(.uiCaption).foregroundStyle(Brand.warningText)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(10).textSelection(.enabled)
                }
            }
        } else if candidates == nil && failure == nil {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView {
                Label(L("git.organize.emptyTitle"), systemImage: Symbols.success)
            } description: {
                Text(failure ?? L("git.organize.emptyDetail"))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func actions(_ current: GitOrganizePlan) -> some View {
        let chosen = current.items.filter { selection.contains($0.id) }
        return HStack(spacing: 6) {
            Button { if let id = edit({ $0.combine(selection) }) { selection = [id] } } label: { Label(L("git.organize.combine"), systemImage: Symbols.gitCombine) }
                .disabled(chosen.count < 2).help(L("git.organize.combineHelp")).accessibilityIdentifier("git.organize.combine")
            Button { _ = edit { $0.split(selection); return nil }; selection = [] } label: { Label(L("git.organize.split"), systemImage: Symbols.gitSplit) }
                .disabled(!chosen.contains { $0.commits.count > 1 }).help(L("git.organize.splitHelp")).accessibilityIdentifier("git.organize.split")
            Button { _ = edit { $0.toggleDrop(selection); return nil } } label: {
                Label(L(!chosen.isEmpty && chosen.allSatisfy(\.drop) ? "git.organize.keep" : "git.organize.remove"), systemImage: Symbols.remove)
            }
            .disabled(chosen.isEmpty).help(L("git.organize.removeHelp")).accessibilityIdentifier("git.organize.remove")
            Button { if let id = chosen.first?.id { _ = edit { $0.move(id, by: -1); return nil } } } label: { Label(L("git.organize.up"), systemImage: Symbols.gitMoveUp) }
                .disabled(chosen.count != 1 || current.items.first?.id == chosen.first?.id).accessibilityIdentifier("git.organize.up")
            Button { if let id = chosen.first?.id { _ = edit { $0.move(id, by: 1); return nil } } } label: { Label(L("git.organize.down"), systemImage: Symbols.gitMoveDown) }
                .disabled(chosen.count != 1 || current.items.last?.id == chosen.first?.id).accessibilityIdentifier("git.organize.down")
            Spacer(minLength: 4)
            Button { _ = edit { $0.reset(); return nil }; selection = [] } label: { Label(L("git.organize.reset"), systemImage: Symbols.startOver) }
                .disabled(!current.changed).help(L("git.organize.resetHelp")).accessibilityIdentifier("git.organize.reset")
        }
        .buttonStyle(.bordered).controlSize(.small)
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private func edit(_ change: (inout GitOrganizePlan) -> UUID?) -> UUID? {
        guard var current = plan else { return nil }
        let result = change(&current)
        plan = current
        return result
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if plan != nil { Text(summary).font(.uiCaption).foregroundStyle(.secondary) }
            Spacer()
            if applying { ProgressView().controlSize(.small) }
            Button(L("common.cancel"), role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction).disabled(applying)
                .accessibilityIdentifier("git.organize.cancel")
            Button { confirming = true } label: { Label(L("git.organize.apply"), systemImage: Symbols.gitOrganize) }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                .disabled(!(plan?.changed ?? false) || !(plan?.valid ?? false) || applying || repository.busy)
                .accessibilityIdentifier("git.organize.apply")
        }
        .padding(16)
    }

    private var summary: String {
        guard let plan else { return "" }
        let total = plan.items.reduce(0) { $0 + $1.commits.count }
        var parts = [String(format: L("git.organize.summary"), total, plan.kept)]
        if plan.combined > 0 { parts.append(String(format: L("git.organize.summaryCombined"), plan.combined)) }
        if plan.removed > 0 { parts.append(String(format: L("git.organize.summaryRemoved"), plan.removed)) }
        if plan.renamed > 0 { parts.append(String(format: L("git.organize.summaryRenamed"), plan.renamed)) }
        return parts.joined(separator: " · ")
    }

    private func load() async {
        do {
            let value: GitRewriteCandidates = try await repository.store.call(["method": "gitRewriteCandidates", "path": repository.root])
            candidates = value
            plan = GitOrganizePlan(value)
        } catch {
            let failure = GitFailure(error)
            self.failure = failure.detail.isEmpty ? failure.title : failure.detail
        }
    }

    private func apply() async {
        guard let candidates, let plan, !applying else { return }
        applying = true
        defer { applying = false }
        if await repository.applyRewrite(plan.plan(candidates), branch: candidates.branch) {
            dismiss()
        } else if repository.snapshot.operation == "rebase" {
            // It stopped on a conflict: Problemas takes it from here.
            dismiss()
        } else {
            failure = repository.failure?.detail
            repository.failure = nil
        }
    }
}

/// A row: drag handle, subject (struck out when removed), how many commits it combines, the
/// identifiers; selected alone, its message can be edited.
private struct GitOrganizeRow: View {
    @Binding var item: GitOrganizeItem
    let single: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: Symbols.dropDown).foregroundStyle(.tertiary).help(L("git.organize.dragHelp")).accessibilityHidden(true)
                Text(item.subject.isEmpty ? L("git.organize.noMessage") : item.subject).font(.uiBody).lineLimit(1)
                    .strikethrough(item.drop).foregroundStyle(item.drop ? .secondary : .primary)
                if item.commits.count > 1 {
                    Text(String(format: L("git.organize.combined"), item.commits.count)).font(.uiCaption).foregroundStyle(Brand.infoText)
                }
                if item.renamed && !item.drop { Text(L("git.organize.renamed")).font(.uiCaption).foregroundStyle(Brand.infoText) }
                if item.drop { Text(L("git.organize.removed")).font(.uiCaption).foregroundStyle(Brand.dangerText) }
                Spacer(minLength: 4)
                Text(item.commits.map(\.short).joined(separator: " + ")).font(.uiCaption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
            }
            if single && !item.drop {
                TextField(L("git.organize.message"), text: $item.message, axis: .vertical)
                    .lineLimit(2...6).textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("git.organize.message")
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("git.organize.item.\(item.commits.first?.short ?? "")")
    }
}
