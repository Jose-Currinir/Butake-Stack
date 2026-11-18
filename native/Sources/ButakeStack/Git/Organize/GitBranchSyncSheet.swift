import SwiftUI

/// `gitBranchSync`: two branches compared by content (a commit copied to the other branch counts
/// as present in both).
struct GitBranchSyncResult: Decodable, Sendable {
    var left: String
    var right: String
    var onlyLeft: [GitCommitSummary]
    var onlyRight: [GitCommitSummary]
    var equivalentLeft: [GitCommitSummary]
    var equivalentRight: [GitCommitSummary]
}

/// «Sincronizar ramas»: what each of two branches lacks from the other, and the chosen commits
/// copied across (one confirmation, then back to the branch you were on).
struct GitBranchSyncSheet: View {
    let repository: GitRepository
    @State private var left = ""
    @State private var right = ""
    @State private var result: GitBranchSyncResult?
    @State private var chosen: Set<String> = []
    @State private var loading = false
    @State private var failure: String?
    @State private var copying: GitCopyRequest?
    @Environment(\.dismiss) private var dismiss

    private var names: [String] { repository.localBranches.map(\.name) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                IconTile(symbol: Symbols.gitSyncBranches, size: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text(L("git.syncBranches.title")).font(.uiTitle3.weight(.semibold))
                    Text(L("git.syncBranches.detail")).font(.uiCaption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(16)
            Form {
                Section {
                    Picker(L("git.syncBranches.left"), selection: $left) { ForEach(names, id: \.self) { Text($0).tag($0) } }
                        .accessibilityIdentifier("git.syncBranches.left")
                    Picker(L("git.syncBranches.right"), selection: $right) { ForEach(names, id: \.self) { Text($0).tag($0) } }
                        .accessibilityIdentifier("git.syncBranches.right")
                }
                if let result, result.left == left, result.right == right {
                    side(result.onlyLeft, from: left, to: right)
                    side(result.onlyRight, from: right, to: left)
                    let copied = result.equivalentLeft.count + result.equivalentRight.count
                    if copied > 0 {
                        Section { Text(String(format: L("git.syncBranches.inBoth"), copied)).foregroundStyle(.secondary) }
                    }
                } else if loading {
                    Section { ProgressView().frame(maxWidth: .infinity) }
                } else if let failure {
                    Section { Label(failure, systemImage: Symbols.warning).foregroundStyle(Brand.warningText) }
                }
            }
            .formStyle(.grouped)
            .themedScroll()
            Divider()
            HStack {
                Spacer()
                Button(L("common.close")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("git.syncBranches.close")
            }
            .padding(16)
        }
        .frame(minWidth: 640, idealWidth: 720, minHeight: 520, idealHeight: 640)
        .onAppear {
            let primary = repository.snapshot.primaryBranch
            left = names.contains(primary) ? primary : names.first ?? ""
            let current = repository.snapshot.branch
            right = current != left && names.contains(current) ? current : names.first { $0 != left } ?? ""
        }
        .task(id: "\(left)|\(right)|\(repository.snapshot.headCommit?.hash ?? "")") { await load() }
        .confirmationDialog(String(format: L("git.history.copyTitle"), copying?.target ?? ""),
                            isPresented: Binding(get: { copying != nil }, set: { if !$0 { copying = nil } }), presenting: copying) { request in
            Button(L("git.history.copyConfirm")) {
                Task {
                    if await repository.copyCommits(request.hashes, to: request.target) { chosen = []; await load() }
                }
            }
            .accessibilityIdentifier("git.syncBranches.copyConfirm")
            Button(L("common.cancel"), role: .cancel) {}.accessibilityIdentifier("git.syncBranches.confirmCancel")
        } message: { request in
            Text(String(format: L("git.history.copyDetail"), request.title, request.target, repository.branchTitle))
        }
        .accessibilityIdentifier("git.syncBranches.sheet")
    }

    /// The commits only in `from`, with a box each and «Copiar a ‹to›».
    @ViewBuilder private func side(_ commits: [GitCommitSummary], from: String, to: String) -> some View {
        Section {
            if commits.isEmpty {
                Text(String(format: L("git.syncBranches.nothing"), to, from)).foregroundStyle(.secondary)
            } else {
                ForEach(commits) { commit in
                    Toggle(isOn: Binding(get: { chosen.contains(commit.hash) }, set: { if $0 { chosen.insert(commit.hash) } else { chosen.remove(commit.hash) } })) {
                        Text(commit.subject).lineLimit(1)
                        Text("\(commit.hash.prefix(7)) · \(commit.author)").font(.uiCaption.monospaced())
                    }
                    .toggleStyle(.checkbox)
                    .accessibilityIdentifier("git.syncBranches.commit.\(commit.hash.prefix(7))")
                }
            }
        } header: {
            HStack {
                Text(String(format: L("git.syncBranches.onlyIn"), from, commits.count))
                Spacer()
                let picked = commits.filter { chosen.contains($0.hash) }
                Button {
                    copying = GitCopyRequest(hashes: picked.map(\.hash), title: String(format: L("git.syncBranches.commits"), picked.count), target: to)
                } label: {
                    Label(String(format: L("git.syncBranches.copyTo"), to), systemImage: Symbols.gitCopyCommits)
                }
                .buttonStyle(.bordered).controlSize(.small)
                .disabled(picked.isEmpty || repository.busy || !repository.files.isEmpty)
                .help(L(repository.files.isEmpty ? "git.syncBranches.copyHelp" : "git.syncBranches.dirtyHelp"))
                .accessibilityIdentifier("git.syncBranches.copyTo.\(to)")
            }
        }
    }

    private func load() async {
        guard !left.isEmpty, !right.isEmpty, left != right else { result = nil; return }
        loading = true
        defer { loading = false }
        do {
            result = try await repository.store.call(["method": "gitBranchSync", "path": repository.root, "left": left, "right": right])
            failure = nil
        } catch {
            result = nil
            let failure = GitFailure(error)
            self.failure = failure.detail.isEmpty ? failure.title : failure.detail
        }
    }
}
