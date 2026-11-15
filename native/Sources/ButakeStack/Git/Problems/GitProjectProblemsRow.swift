import SwiftUI

/// The «Git» row of a project's page: how many problems its repository has, when it is the one
/// open in the Git tool, and the way to them.
struct GitProjectProblemsRow: View {
    let path: String
    @Bindable var tool = GitTool.shared

    var body: some View {
        if tool.requirement.ready, let repository = tool.repository, Self.same(repository.root, path) {
            let count = GitProblemSources.shared.problems(for: repository).count
            if count > 0 {
                LabeledContent {
                    Button {
                        tool.tab = .problems
                        tool.show(path)
                    } label: { Label(L("git.problems.show"), systemImage: Symbols.gitProblems) }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("project.git.problems")
                } label: {
                    Label { Text(String(format: L("git.problems.count"), count)) } icon: {
                        Image(systemName: Symbols.warning).foregroundStyle(Brand.warning)
                    }
                }
            }
        }
    }

    /// The project's folder is the repository's (or inside it).
    static func same(_ root: String, _ path: String) -> Bool {
        let folder = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        let top = URL(fileURLWithPath: root).standardizedFileURL.resolvingSymlinksInPath().path
        return folder == top || folder.hasPrefix(top + "/")
    }
}
