import SwiftUI

/// The repository's files (tracked and new, not the ignored ones) with a filter, and a read-only
/// preview of the chosen one.
struct GitFilesBrowser: View {
    let repository: GitRepository
    @State private var paths: [String]?
    @State private var filter = ""
    @State private var selection: String?
    /// Why the files could not be read: not the same as «no files».
    @State private var failure: GitFailure?
    @State private var retries = 0

    private var shown: [String] {
        let all = paths ?? []
        let query = filter.trimmingCharacters(in: .whitespaces)
        return Array((query.isEmpty ? all : all.filter { $0.localizedCaseInsensitiveContains(query) }).prefix(5_000))
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                FilterField(text: $filter, identifier: "git.files.filter", prompt: L("git.files.filter")).padding(10)
                Divider()
                List(shown, id: \.self, selection: $selection) { path in
                    Label { Text(path).lineLimit(1).truncationMode(.middle).help(path) } icon: { FileTypeIcon(path: path, size: 16) }
                }
                .listStyle(.sidebar)
                .themedScroll()
                .accessibilityIdentifier("git.files.list")
                .overlay {
                    if let failure {
                        ContentUnavailableView {
                            Label(failure.title, systemImage: Symbols.warning)
                        } description: {
                            Text(failure.detail)
                        } actions: {
                            Button(L("common.retry")) { retries += 1 }.accessibilityIdentifier("git.files.retry")
                        }
                    } else if paths == nil {
                        ProgressView()
                    } else if shown.isEmpty {
                        if filter.isEmpty {
                            ContentUnavailableView(L("git.files.emptyTitle"), systemImage: Symbols.file, description: Text(L("git.files.emptyDetail")))
                        } else {
                            ContentUnavailableView.search(text: filter)
                        }
                    }
                }
            }
            .frame(minWidth: 240, idealWidth: 300, maxWidth: 420)
            Group {
                if let selection {
                    GitFilePreview(repository: repository, path: selection).id(selection)
                } else {
                    ContentUnavailableView(L("git.files.chooseTitle"), systemImage: Symbols.file, description: Text(L("git.files.chooseDetail")))
                }
            }
            .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: retries) {
            do {
                let output = try await repository.query(["ls-files", "--cached", "--others", "--exclude-standard", "-z"])
                guard !Task.isCancelled else { return }
                paths = output.split(separator: "\0").map(String.init)
                failure = nil
            } catch {
                let problem = GitFailure(error)
                if !problem.cancelled && !Task.isCancelled { failure = problem }
            }
        }
    }
}
