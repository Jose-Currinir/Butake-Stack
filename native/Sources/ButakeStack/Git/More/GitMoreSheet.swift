import SwiftUI

/// «Más…»: what is used now and then, in plain lists with their basic actions: changes kept aside,
/// tags, remotes, other working folders and the repository's files with a preview.
struct GitMoreSheet: View {
    let repository: GitRepository
    @State var section: GitMoreSection = .stashes
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                IconTile(symbol: Symbols.more, size: 32)
                Text(L("git.more.title")).font(.uiTitle3.weight(.semibold))
                Spacer()
                Picker(L("git.more.section"), selection: $section) {
                    ForEach(GitMoreSection.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .accessibilityIdentifier("git.more.section")
            }
            .padding(16)
            Divider()
            Group {
                switch section {
                case .stashes: GitStashList(repository: repository)
                case .tags: GitTagList(repository: repository)
                case .remotes: GitRemoteList(repository: repository)
                case .worktrees: GitWorktreeList(repository: repository)
                case .files: GitFilesBrowser(repository: repository)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack {
                Spacer()
                Button(L("common.close")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("git.more.close")
            }
            .padding(16)
        }
        .frame(minWidth: 820, idealWidth: 920, minHeight: 560, idealHeight: 660)
        .onAppear {
            #if DEBUG
            if let wanted = GitHistoryQA.moreSection { section = wanted }
            #endif
        }
        .accessibilityIdentifier("git.more.sheet")
    }
}

enum GitMoreSection: String, CaseIterable, Identifiable {
    case stashes, tags, remotes, worktrees, files
    var id: String { rawValue }
    var title: String { L("git.more.\(rawValue)") }
    var symbol: String {
        switch self {
        case .stashes: Symbols.gitStash
        case .tags: Symbols.tags
        case .remotes: Symbols.cloud
        case .worktrees: Symbols.gitWorktree
        case .files: Symbols.file
        }
    }
}
