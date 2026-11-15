import SwiftUI

/// «Nuevo pull request…»: from the current branch (already on the remote) into another one,
/// with a title, a description and, optionally, as a draft. Creating it on the provider asks first.
struct GitPullRequestSheet: View {
    let session: GitHostingSession
    @State private var title = ""
    @State private var description = ""
    @State private var target = ""
    @State private var draft = false
    @State private var confirming = false
    @Environment(\.dismiss) private var dismiss

    private var snapshot: GitSnapshot { session.repository.snapshot }
    private var source: String { snapshot.branch }
    /// The branches of `origin` it can go into (not the current one).
    private var targets: [String] {
        let names = snapshot.remoteBranches.filter { $0.remote == "origin" && $0.short != source && $0.short != "HEAD" }.map(\.short)
        return names.isEmpty ? [snapshot.primaryBranch] : names
    }
    /// The branch must be on the provider before a pull request can bring it.
    private var published: Bool { snapshot.remoteBranches.contains { $0.remote == "origin" && $0.short == source } }
    private var provider: GitHostingProvider { session.hosted?.provider ?? .github }
    private var clean: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        SheetFrame(title: L("git.pr.newTitle"), symbol: Symbols.gitNewPullRequest,
                   detail: String(format: L("git.pr.newDetail"), source, provider.title),
                   note: !published ? String(format: L("git.pr.newUnpublished"), source) : session.failure?.errorDescription,
                   width: 520, height: 500,
                   actionTitle: L("git.pr.createEllipsis"), actionSymbol: Symbols.gitNewPullRequest, actionID: "git.pr.sheet.create",
                   canAct: published && !clean.isEmpty && !target.isEmpty && target != source && !session.working, cancelID: "git.pr.sheet.cancel") {
            confirming = true
            return false
        } content: {
            Form {
                TextField(L("git.pr.field.title"), text: $title, prompt: Text(L("git.pr.titlePrompt")))
                    .accessibilityIdentifier("git.pr.sheet.title")
                Picker(L("git.pr.field.target"), selection: $target) {
                    ForEach(targets, id: \.self) { Text($0).tag($0) }
                }
                .accessibilityIdentifier("git.pr.sheet.target")
                Toggle(L("git.pr.field.draft"), isOn: $draft).help(L("git.pr.draftToggleHelp"))
                    .accessibilityIdentifier("git.pr.sheet.draft")
                Section(L("git.pr.description")) {
                    TextEditor(text: $description).font(.uiBody).frame(minHeight: 90)
                        .scrollContentBackground(.hidden)
                        .accessibilityLabel(L("git.pr.description"))
                        .accessibilityIdentifier("git.pr.sheet.description")
                }
            }
            .formStyle(.grouped).themedScroll()
        }
        .onAppear {
            title = snapshot.headCommit?.subject ?? ""
            target = targets.contains(snapshot.primaryBranch) ? snapshot.primaryBranch : targets.first ?? ""
            session.failure = nil
        }
        .confirmationDialog(String(format: L("git.pr.createTitle"), provider.title), isPresented: $confirming, titleVisibility: .visible) {
            Button(L("git.pr.createConfirm")) {
                Task { if await session.create(title: clean, body: description, target: target, draft: draft) { dismiss() } }
            }
            .accessibilityIdentifier("git.pr.sheet.confirm")
            Button(L("common.cancel"), role: .cancel) {}.accessibilityIdentifier("git.pr.sheet.confirmCancel")
        } message: {
            Text(String(format: L("git.pr.createDetail"), source, target, session.hosted?.path ?? ""))
        }
    }
}
