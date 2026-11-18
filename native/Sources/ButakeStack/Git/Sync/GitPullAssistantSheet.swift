import SwiftUI

/// The pull assistant: bringing the remote's commits was not direct. It says why in plain words
/// and offers the ways out the engine knows (DISENO.md, «Bajar con asistente»):
/// - both sides moved (`pull_diverged`): combine them (a merge commit) or reorganize mine on top;
/// - changes here would be overwritten (`pull_local_changes`): keep them aside, bring, put them back;
/// - the branch has no remote yet (`pull_no_upstream`): publish it;
/// - files collide (`pull_conflicts`): they are resolved in Problemas.
struct GitPullAssistantSheet: View {
    let repository: GitRepository
    let problem: GitFailure
    @State private var choice: GitAction?
    @Environment(\.dismiss) private var dismiss

    private var options: [(action: GitAction, title: String, detail: String)] {
        switch problem.code {
        case "pull_diverged":
            [(.pullMerge, L("git.pull.merge"), String(format: L("git.pull.mergeDetail"), repository.branchTitle)),
             (.pullRebase, L("git.pull.rebase"), L("git.pull.rebaseDetail"))]
        case "pull_local_changes":
            [(.pullAutostash, L("git.pull.autostash"), L("git.pull.autostashDetail"))]
        case "pull_no_upstream":
            [(.push, L("git.sync.publishBranch"), L("git.sync.publishBranchHelp"))]
        default: []
        }
    }

    var body: some View {
        SheetFrame(title: L("git.pull.title"), symbol: Symbols.gitPull, detail: problem.title, note: L("git.pull.note"), width: 500,
                   actionTitle: options.isEmpty ? L("git.pull.openProblems") : L("git.pull.continue"),
                   actionID: "git.pull.continue", canAct: options.isEmpty || choice != nil, cancelID: "git.pull.cancel") {
            if let choice {
                dismiss()
                if choice == .push { await repository.push() } else { await repository.resolvePull(choice) }
            } else {
                GitTool.shared.tab = .problems
            }
            return true
        } content: {
            VStack(alignment: .leading, spacing: 12) {
                Text(problem.detail).font(.uiBody).frame(maxWidth: .infinity, alignment: .leading)
                if !options.isEmpty {
                    Picker(L("git.pull.choose"), selection: $choice) {
                        ForEach(options, id: \.action) { option in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(option.title).font(.uiBody.weight(.medium))
                                Text(option.detail).font(.uiCaption).foregroundStyle(.secondary)
                            }
                            .tag(Optional(option.action))
                            .accessibilityIdentifier("git.pull.option.\(option.action.rawValue)")
                        }
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                }
            }
        }
        .onAppear {
            #if DEBUG
            choice = GitQA.pullChoice ?? options.first?.action
            #else
            choice = options.first?.action
            #endif
        }
    }
}
