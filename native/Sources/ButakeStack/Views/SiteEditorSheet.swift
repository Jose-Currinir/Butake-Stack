import SwiftUI

/// Create (from a detection) or edit a site. Everything the engine proposes is editable.
struct SiteEditorSheet: View {
    @Bindable var store: StackStore
    @State var project: Project
    let notes: [String]
    let isNew: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var domain = ""

    init(store: StackStore, project: Project, notes: [String], isNew: Bool) {
        self.store = store
        _project = State(initialValue: project)
        self.notes = notes
        self.isNew = isNew
        _domain = State(initialValue: project.domain)
    }

    var phpChoices: [String] { Array(Set(store.phpRuntimes.filter(\.installed).map(\.series) + [project.php].compactMap { $0 })).sorted() }
    var nodeChoices: [String] {
        let majors = (store.installedTools["node"] ?? []).map { String($0.version.split(separator: ".").first ?? "") }
        return Array(Set(majors + [project.node].compactMap { $0 })).sorted()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                SiteAvatar(name: project.name.isEmpty ? "?" : project.name, size: 42)
                VStack(alignment: .leading, spacing: 2) {
                    Text(isNew ? L("editor.newTitle") : L("editor.editTitle")).font(.uiTitle2.weight(.semibold))
                    Text(project.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).font(.uiCaption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
            }
            .padding(20)
            Divider()
            Form {
                Section {
                    TextField(L("site.name"), text: $project.name).accessibilityIdentifier("editor.name")
                    TextField(L("site.domain"), text: $domain).accessibilityIdentifier("editor.domain")
                    LabeledContent(L("site.folder")) { Text(project.path).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle) }
                    Picker(L("site.kind"), selection: $project.kind) {
                        ForEach(["laravel", "php", "static"], id: \.self) { Text(L("kind.\($0)")).tag($0) }
                    }.accessibilityIdentifier("editor.kind")
                    TextField(L("site.docroot"), text: $project.docroot).accessibilityIdentifier("editor.docroot")
                    Toggle(L("site.https"), isOn: $project.https).accessibilityIdentifier("editor.https")
                } header: { Label(L("editor.general"), systemImage: "slider.horizontal.3") }
                Section {
                    Picker("PHP", selection: Binding(get: { project.php ?? "" }, set: { project.runtime["php"] = $0.isEmpty ? nil : $0 })) {
                        Text(L("value.none")).tag("")
                        ForEach(phpChoices, id: \.self) { Text($0).tag($0) }
                    }.accessibilityIdentifier("editor.php")
                    Picker("Node", selection: Binding(get: { project.node ?? "" }, set: { project.runtime["node"] = $0.isEmpty ? nil : $0 })) {
                        Text(L("value.none")).tag("")
                        ForEach(nodeChoices, id: \.self) { Text($0).tag($0) }
                    }.accessibilityIdentifier("editor.node")
                    if let node = project.node, !(store.installedTools["node"] ?? []).contains(where: { $0.version.hasPrefix(node + ".") }) {
                        Label(String(format: L("editor.nodeMissing"), node), systemImage: "exclamationmark.triangle.fill").font(.uiCaption).foregroundStyle(Brand.warning)
                    }
                } header: { Label(L("site.environment"), systemImage: "cpu") }
                if !project.processes.isEmpty {
                    Section {
                        ForEach($project.processes) { $process in
                            Toggle(isOn: $process.autostart) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(process.name)
                                    Text(process.commandLine).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                }
                            }.accessibilityIdentifier("editor.process.\(process.name)")
                        }
                        Text(L("editor.processesHelp")).font(.uiCaption).foregroundStyle(.secondary)
                    } header: { Label(L("site.processes"), systemImage: "gearshape.2") }
                }
                if !notes.isEmpty {
                    Section {
                        ForEach(notes, id: \.self) { Label(L("note.\($0)"), systemImage: "info.circle").foregroundStyle(.secondary) }
                    } header: { Label(L("editor.notes"), systemImage: "exclamationmark.bubble") }
                }
            }.formStyle(.grouped).themedScroll()
            Divider()
            HStack {
                Spacer()
                Button(L("action.cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isNew ? L("editor.create") : L("action.save")) {
                    project.domains = [domain.lowercased().trimmingCharacters(in: .whitespaces)] + project.domains.dropFirst()
                    Task { if await store.save(project) { dismiss() } }
                }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).accessibilityIdentifier("editor.save")
            }.padding(14)
        }.frame(width: 640, height: 680)
    }
}
