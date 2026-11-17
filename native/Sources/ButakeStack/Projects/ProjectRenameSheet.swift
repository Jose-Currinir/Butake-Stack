import SwiftUI

/// «Renombrar…» of a project (P-41): its title and its identifier, with what changes said before
/// anything does. The `.test` address only changes when the user asks for it here.
struct ProjectRenameSheet: View {
    @Bindable var store: StackStore
    let request: RenameRequest
    @State private var name = ""
    @State private var newId = ""
    @State private var changeDomain = false
    @FocusState private var focused: Bool

    private var project: Project { request.project }
    private var cleanName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var cleanId: String { newId.trimmingCharacters(in: .whitespaces) }
    /// The local domain the project gets with «Cambiar también la dirección».
    private var domainPreview: String {
        let tld = project.domain.split(separator: ".").last.map(String.init) ?? store.config?.tld.first ?? "test"
        return "\(cleanId).\(tld)"
    }
    /// Why the new identifier cannot be used, or nil.
    private var idProblem: String? {
        guard cleanId != project.id else { return nil }
        if !Self.validId(cleanId) { return L("rename.id.invalid") }
        if store.projects.contains(where: { $0.id == cleanId }) { return L("rename.id.taken") }
        if changeDomain, store.projects.contains(where: { $0.id != project.id && $0.domains.contains(domainPreview) }) { return L("error.domain_in_use") }
        return nil
    }
    private var idChanges: Bool { cleanId != project.id }
    private var canRename: Bool {
        !cleanName.isEmpty && idProblem == nil && (idChanges || cleanName != project.name)
    }

    /// As the engine checks it: lowercase letters, digits and dashes, 1 to 40.
    nonisolated static func validId(_ id: String) -> Bool {
        // Bytes, not characters: a combining mark after a letter is not a letter the engine accepts.
        !id.isEmpty && id.utf8.count <= 40 && id.utf8.allSatisfy { ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) || $0 == 45 }
    }

    var body: some View {
        SheetFrame(title: L("rename.title"), symbol: Symbols.renameProject, detail: project.title, width: 520,
                   actionTitle: L("rename.action"), actionID: "rename.save", canAct: canRename, cancelID: "rename.cancel") {
            if !idChanges {
                var edited = project
                edited.name = cleanName
                return await store.save(edited)
            }
            return await store.renameProject(project, to: cleanId, name: cleanName, domain: changeDomain)
        } content: {
            form
        }
        .onAppear {
            name = project.name
            newId = request.proposedId ?? project.id
            focused = true
        }
    }

    private var form: some View {
        Form {
            Section {
                TextField(L("rename.name"), text: $name).focused($focused).accessibilityIdentifier("rename.name")
                LabeledContent(L("rename.id")) {
                    TextField(L("rename.id"), text: $newId).labelsHidden().multilineTextAlignment(.trailing)
                        .font(.uiBody.monospaced()).accessibilityIdentifier("rename.id")
                }
            } footer: {
                Text(idProblem ?? L("rename.id.hint")).font(.uiCaption).foregroundStyle(idProblem == nil ? Color.secondary : Brand.warning)
                    .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("rename.id.note")
            }
            if idChanges {
                Section(L("rename.domain")) {
                    LabeledContent(L("rename.domain.now"), value: project.domain)
                    Toggle(String(format: L("rename.domain.change"), domainPreview), isOn: $changeDomain)
                        .accessibilityIdentifier("rename.domain.change")
                }
                Section(L("rename.changes")) {
                    ForEach(changes, id: \.self) { line in
                        Text(line).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .accessibilityIdentifier("rename.changes")
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: idChanges ? 420 : 160)
    }

    /// What the rename changes, as the user should know it before confirming.
    private var changes: [String] {
        var lines = [L("rename.changes.record"), L("rename.changes.markers"), L("rename.changes.secrets"), L("rename.changes.links")]
        if project.enabled && !project.isMissing { lines.append(L("rename.changes.restart")) }
        lines.append(L("rename.changes.same"))
        return lines
    }
}
