import SwiftUI

/// The page of a project whose folder is not where Stack expects it (moved or renamed outside
/// Stack, or on a drive that is not connected): what happened, where it was and the two ways out.
/// It does not start until its folder is found.
struct MissingProjectPanel: View {
    let store: StackStore
    let project: Project
    var body: some View {
        let path = project.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        ContentUnavailableView {
            Label(L("missing.title"), systemImage: Symbols.missingFolder)
        } description: {
            Text(L("missing.detail"))
            Text("\(L("missing.path")) \(path)").font(.uiCaption.monospaced()).lineLimit(1).truncationMode(.middle).help(project.path)
                .accessibilityIdentifier("project.missing.path")
        } actions: {
            // Side by side when they fit; one over the other with large text.
            ViewThatFits {
                HStack { actions }
                VStack { actions }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("project.missing")
    }

    @ViewBuilder private var actions: some View {
        Button { store.findFolder(project) } label: { Label(L("missing.find"), systemImage: Symbols.findFolder) }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("project.missing.find")
        Button(role: .destructive) { store.removing = project } label: { Label(L("missing.remove"), systemImage: Symbols.remove) }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("project.missing.remove")
    }
}
