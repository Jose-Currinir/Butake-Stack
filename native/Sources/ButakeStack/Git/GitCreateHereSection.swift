import SwiftUI

/// The «Git» section of a project without a repository (only while the tool is on): «Crear
/// repositorio aquí» starts one in the project's folder, asks first and then opens it in the tool.
/// A folder inside another repository gets no offer: a repository there would hide in the other.
struct GitCreateHereSection: View {
    let project: Project
    @State private var confirming = false
    @State private var working = false
    @State private var failure: GitFailure?

    var body: some View {
        if !Self.insideRepository(project.path) {
            Section {
                LabeledContent {
                    Button { confirming = true } label: { Label(L("git.createHere.action"), systemImage: Symbols.gitCreateRepository) }
                        .buttonStyle(.bordered).disabled(working)
                        .help(L("git.createHere.help"))
                        .accessibilityIdentifier("project.git.createHere")
                } label: {
                    Text(L("git.createHere.title"))
                    Text(L("git.createHere.detail"))
                }
            } header: {
                Text(verbatim: "Git")
            }
            .confirmationDialog(String(format: L("git.createHere.confirmTitle"), project.title), isPresented: $confirming, titleVisibility: .visible) {
                Button(L("git.createHere.confirm")) { Task { await create() } }
                    .accessibilityIdentifier("project.git.createHereConfirm")
                Button(L("common.cancel"), role: .cancel) {}.accessibilityIdentifier("project.git.createHereCancel")
            } message: {
                Text(L("git.createHere.confirmDetail"))
            }
            .alert(failure?.title ?? "", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button(L("common.close"), role: .cancel) {}.accessibilityIdentifier("project.git.createHereClose")
            } message: {
                Text(failure?.detail ?? "")
            }
        }
    }

    /// The project's folder or one above it already is a repository.
    static func insideRepository(_ path: String, fileManager: FileManager = .default) -> Bool {
        var folder = URL(fileURLWithPath: path).standardizedFileURL
        while folder.path != "/" {
            if fileManager.fileExists(atPath: folder.appendingPathComponent(".git").path) { return true }
            folder.deleteLastPathComponent()
        }
        return false
    }

    private func create() async {
        working = true
        defer { working = false }
        let folder = URL(fileURLWithPath: project.path).standardizedFileURL
        do {
            let path: String = try await StackStore.shared.call(["method": "gitInit", "path": folder.deletingLastPathComponent().path,
                                                                 "name": folder.lastPathComponent, "develop": true])
            await StackStore.shared.refreshGit()
            StackStore.shared.notify(String(format: L("git.create.done"), project.title))
            GitTool.shared.show(path)
        } catch {
            failure = GitFailure(error)
        }
    }
}
