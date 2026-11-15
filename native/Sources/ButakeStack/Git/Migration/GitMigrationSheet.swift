import SwiftUI

/// «Traer mis repositorios»: what will come from the former Butake Git app (its repositories and
/// its equivalent preferences), what will not (its accounts) and, once done, what came.
struct GitMigrationSheet: View {
    @Bindable var migration = GitMigration.shared
    @State private var result: GitMigrationResult?

    var body: some View {
        if let result {
            SheetFrame(title: L("git.migration.doneTitle"), symbol: Symbols.importing, detail: summary(result), width: 500,
                       actionTitle: L("common.done"), actionID: "git.migration.close") { true } content: {
                if !result.failed.isEmpty {
                    Notice(.warning, String(format: L("git.migration.failed"), result.failed.joined(separator: ", ")),
                           detail: L("git.migration.failedDetail"))
                }
            }
        } else {
            SheetFrame(title: L("git.migration.title"), symbol: Symbols.importing, detail: L("git.migration.detail"), note: L("git.migration.note"),
                       width: 540, height: 540, actionTitle: L("git.migration.action"), actionSymbol: Symbols.importing,
                       actionID: "git.migration.run", canAct: migration.source.map { !$0.isEmpty } == true,
                       cancelID: "git.migration.cancel", cancelTitle: L("git.migration.later")) {
                result = await migration.bring()
                return false
            } content: {
                form
            } status: {
                EmptyView()
            }
        }
    }

    private var form: some View {
        let source = migration.source
        return Form {
            Section(L("git.migration.repositories")) {
                if let source, !source.repositories.isEmpty {
                    ForEach(source.repositories, id: \.self) { path in
                        LabeledContent {
                            Text(path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).lineLimit(1).truncationMode(.middle).help(path)
                        } label: {
                            Label((path as NSString).lastPathComponent, systemImage: Symbols.git)
                        }
                    }
                } else {
                    Text(L("git.migration.noRepositories")).foregroundStyle(.secondary)
                }
            }
            Section {
                if source?.autoFetch == true {
                    LabeledContent(L("git.statusBoard.autoFetch"), value: L("git.migration.on"))
                }
                if let parent = source?.cloneParent {
                    LabeledContent(L("git.migration.cloneParent")) {
                        Text(parent.replacingOccurrences(of: NSHomeDirectory(), with: "~")).lineLimit(1).truncationMode(.middle).help(parent)
                    }
                }
                LabeledContent(L("git.migration.accounts"), value: L("git.migration.accountsValue"))
            } header: {
                Text(L("git.migration.preferences"))
            } footer: {
                SettingsFooter(L("git.migration.accountsFooter"))
            }
        }
        .formStyle(.grouped).themedScroll()
        .accessibilityIdentifier("git.migration.list")
    }

    private func summary(_ result: GitMigrationResult) -> String {
        var parts = [String(format: L("git.migration.added"), result.added)]
        if result.known > 0 { parts.append(String(format: L("git.migration.known"), result.known)) }
        if result.missing > 0 { parts.append(String(format: L("git.migration.missing"), result.missing)) }
        return parts.joined(separator: " ")
    }
}

extension View {
    /// The «Traer mis repositorios» sheet, in the window that asked for it.
    func gitMigrationSheet(in presenter: GitMigration.Presenter) -> some View {
        modifier(GitMigrationPresenter(presenter: presenter))
    }
}

private struct GitMigrationPresenter: ViewModifier {
    let presenter: GitMigration.Presenter
    @Bindable var migration = GitMigration.shared
    func body(content: Content) -> some View {
        content.sheet(isPresented: Binding(get: { migration.presenter == presenter }, set: { if !$0 { migration.presenter = nil } })) {
            GitMigrationSheet().themedSheet()
        }
    }
}
