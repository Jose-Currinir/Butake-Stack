import SwiftUI

/// A new app or service, or one being edited: its name, an app's identifier and project, and its
/// notes. The project is suggested by name or identifier, never chosen without the user.
struct VaultContainerSheet: View {
    @Bindable var vault: VaultSession
    let original: VaultContainer?
    let kind: VaultContainer.Kind
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var bundleId = ""
    @State private var notes = ""
    @State private var project: String?
    private var projects: [Project] { StackStore.shared.projects.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending } }
    private var composites: [ProjectGroup] { StackStore.shared.composites }
    /// A project that matches the name or identifier, while none is chosen.
    private var suggestion: Project? {
        guard project == nil else { return nil }
        return VaultProjects.suggestion(name: name, bundleId: bundleId, in: projects)
    }
    var valid: Bool {
        let clean = name.trimmingCharacters(in: .whitespaces)
        let bundle = bundleId.trimmingCharacters(in: .whitespaces)
        return kind == .app ? VaultNames.isSafeComponent(clean) && !clean.contains("(") && (bundle.isEmpty || VaultNames.isBundleId(bundle)) : VaultNames.isServicePath(clean)
    }
    var body: some View {
        SheetFrame(title: original == nil ? (kind == .app ? L("vault.newApp") : L("vault.newService")) : L("common.edit"),
                   symbol: kind == .app ? Symbols.app : Symbols.server,
                   detail: kind == .app ? L("vault.newAppDetail") : L("vault.newServiceDetail"),
                   width: 520,
                   height: kind == .app ? 540 : 400,
                   actionTitle: original == nil ? L("common.create") : L("common.save"),
                   actionID: "vault.sheet.container.confirm",
                   canAct: valid,
                   cancelID: "vault.sheet.container.cancel",
                   action: { save(); return false }) {
            Form {
                TextField(kind == .app ? L("vault.appName") : L("vault.servicePath"), text: $name, prompt: Text(L(kind == .app ? "vault.appNamePrompt" : "vault.servicePathPrompt")))
                    .accessibilityIdentifier("vault.sheet.container.name")
                if kind == .app {
                    TextField(L("vault.bundleId"), text: $bundleId, prompt: Text(L("vault.bundleIdPrompt"))).accessibilityIdentifier("vault.sheet.container.bundle")
                    LabeledContent(L("common.folder")) {
                        Text(VaultContainer(kind: .app, name: name.isEmpty ? "…" : name, bundleId: bundleId.isEmpty ? nil : bundleId).folderName + "/")
                            .font(.uiCaption.monospaced()).foregroundStyle(.secondary)
                    }
                    Text(L("vault.templateHint")).font(.uiCaption).foregroundStyle(.secondary)
                    Section {
                        Picker(L("vault.project"), selection: $project) {
                            Text(L("vault.project.none")).tag(String?.none)
                            ForEach(projects) { Text($0.title).tag(String?.some($0.id)) }
                            // A project of several parts: its parts inherit the link.
                            ForEach(composites) { Text(String(format: L("vault.project.composite"), $0.name)).tag(String?.some(VaultProjects.link(composite: $0.id))) }
                            if let project, !projects.contains(where: { $0.id == project }), !composites.contains(where: { VaultProjects.link(composite: $0.id) == project }) {
                                Text(L("vault.project.missing")).tag(String?.some(project))
                            }
                        }
                        .accessibilityIdentifier("vault.sheet.container.project")
                        if let suggestion {
                            LabeledContent(String(format: L("vault.project.suggestion"), suggestion.title)) {
                                Button { project = suggestion.id } label: { Label(L("vault.project.useSuggestion"), systemImage: Symbols.link) }
                                    .buttonStyle(.bordered).accessibilityIdentifier("vault.sheet.container.useSuggestion")
                            }
                        }
                    } footer: {
                        Text(L("vault.project.footer")).font(.uiCaption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                Section(L("vault.notes")) {
                    TextEditor(text: $notes).font(.uiCallout).frame(height: 90).accessibilityIdentifier("vault.sheet.container.notes")
                }
            }
            .formStyle(.grouped).themedScroll()
        }
        .onAppear {
            project = original?.project
            name = original?.name ?? ""
            bundleId = original?.bundleId ?? ""
            notes = original?.notes ?? ""
        }
    }
    func save() {
        do {
            if var container = original {
                container.name = name.trimmingCharacters(in: .whitespaces)
                container.bundleId = bundleId.trimmingCharacters(in: .whitespaces).isEmpty ? nil : bundleId.trimmingCharacters(in: .whitespaces).lowercased()
                container.notes = notes
                if container.kind == .app { container.project = project }
                try vault.updateContainer(container)
            } else {
                let id = try vault.addContainer(kind: kind, name: name, bundleId: bundleId, notes: notes, project: project)
                vault.selection = .container(id)
            }
            dismiss()
        } catch { vault.message = L((error as? VaultError)?.messageKey ?? "vault.error.io") }
    }
}
