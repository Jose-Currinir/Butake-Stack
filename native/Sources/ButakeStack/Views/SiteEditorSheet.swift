import SwiftUI

/// Create (from a detection) or edit a site. Everything the engine proposes is editable.
struct SiteEditorSheet: View {
    @Bindable var store: StackStore
    @State var project: Project
    let notes: [String]
    let isNew: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var domain = ""
    /// Versions when the sheet opened: only what changes is written to the project's files.
    @State private var original: [String: String] = [:]
    @State private var rust = ""
    @State private var originalRust = ""

    init(store: StackStore, project: Project, notes: [String], isNew: Bool) {
        self.store = store
        _project = State(initialValue: project)
        self.notes = notes
        self.isNew = isNew
        _domain = State(initialValue: project.domain)
        _original = State(initialValue: project.runtime)
    }

    var phpChoices: [String] { Array(Set(store.phpRuntimes.filter(\.installed).map(\.series) + [project.php].compactMap { $0 })).sorted() }
    var nodeChoices: [String] {
        let majors = (store.installedTools["node"] ?? []).map { String($0.version.split(separator: ".").first ?? "") }
        return Array(Set(majors + [project.node].compactMap { $0 })).sorted()
    }

    var javaChoices: [String] {
        let majors = (store.installedTools["jdk"] ?? []).map { String($0.version.split(separator: ".").first ?? "") }
        return Array(Set(majors + [project.runtime["jdk"]].compactMap { $0 })).sorted { $0.compare($1, options: .numeric) == .orderedAscending }
    }
    var pythonChoices: [String] {
        Array(Set(store.pythonRuntimes.map(\.line) + [project.runtime["python"]].compactMap { $0 })).sorted { $0.compare($1, options: .numeric) == .orderedAscending }
    }
    var pythonSite: Bool { ["django", "fastapi"].contains(project.kind) }
    /// A version picker that writes Stack's setting (the file is written on save).
    func picker(_ title: String, _ key: String, _ choices: [String], id: String) -> some View {
        Picker(title, selection: Binding(get: { project.runtime[key] ?? "" }, set: { project.runtime[key] = $0.isEmpty ? nil : $0 })) {
            Text(store.globalVersion(key).map { String(format: L("editor.globalVersion"), $0) } ?? L("value.none")).tag("")
            ForEach(choices, id: \.self) { Text($0).tag($0) }
        }.accessibilityIdentifier(id)
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
                        ForEach(["laravel", "php", "astro", "emdash", "next", "django", "fastapi", "rust", "kmp", "node", "static"], id: \.self) { Text(L("kind.\($0)")).tag($0) }
                    }.accessibilityIdentifier("editor.kind")
                    TextField(L("site.docroot"), text: $project.docroot).accessibilityIdentifier("editor.docroot")
                    Toggle(L("site.https"), isOn: $project.https).accessibilityIdentifier("editor.https")
                } header: { Label(L("editor.general"), systemImage: "slider.horizontal.3") }
                Section {
                    picker("PHP", "php", phpChoices, id: "editor.php")
                    picker("Node", "node", nodeChoices, id: "editor.node")
                    if project.kind == "kmp" || project.runtime["jdk"] != nil || !javaChoices.isEmpty {
                        picker("Java", "jdk", javaChoices, id: "editor.java")
                    }
                    if pythonSite || project.runtime["python"] != nil || !pythonChoices.isEmpty {
                        picker("Python", "python", pythonChoices, id: "editor.python")
                    }
                    if project.kind == "rust" {
                        Picker("Rust", selection: $rust) {
                            Text(L("editor.rustDefault")).tag("")
                            ForEach(Array(Set(store.rustToolchains.map(\.short) + [rust].filter { !$0.isEmpty })).sorted(), id: \.self) { Text($0).tag($0) }
                        }.accessibilityIdentifier("editor.rust")
                    }
                    Text(L("editor.versionFiles")).font(.uiCaption).foregroundStyle(.secondary)
                    if let node = project.node, !(store.installedTools["node"] ?? []).contains(where: { $0.version.hasPrefix(node + ".") }) {
                        Label(String(format: L("editor.nodeMissing"), node), systemImage: "exclamationmark.triangle.fill").font(.uiCaption).foregroundStyle(Brand.warning)
                    }
                    if pythonSite && !isNew {
                        HStack {
                            Text(L("editor.venv")).font(.uiCaption).foregroundStyle(.secondary)
                            Spacer()
                            Button(L("editor.recreateVenv")) { Task { await store.preparePython(project.id, manager: manager, recreate: true) } }
                                .controlSize(.small).disabled(store.busy != nil).accessibilityIdentifier("editor.recreateVenv")
                        }
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
                    Task { if await store.save(project) { await applyVersions(); dismiss() } }
                }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).accessibilityIdentifier("editor.save")
            }.padding(14)
        }.frame(width: 640, height: 680)
        .task {
            if project.kind == "rust" {
                await store.loadRust()
                let files: [String: String?]? = try? await store.call(["method": "siteVersionFiles", "id": project.id])
                rust = (files?["rust"] ?? nil) ?? ""
                originalRust = rust
            }
        }
    }

    /// uv when the project is managed by uv (uv.lock) and uv is installed; pip and venv otherwise.
    var manager: String {
        FileManager.default.fileExists(atPath: project.path + "/uv.lock") && store.devTools["uv"]?.installed == true ? "uv" : "pip"
    }
    /// Writes each changed version in the project's standard file (.nvmrc, .java-version,
    /// .python-version, rust-toolchain.toml) and prepares the Python environment when needed.
    func applyVersions() async {
        for key in ["php", "node", "jdk", "python"] where project.runtime[key] != original[key] {
            do { try await store.setSiteVersion(project.id, key, project.runtime[key] ?? "") } catch { store.report(error) }
        }
        if project.kind == "rust", rust != originalRust, !rust.isEmpty {
            do { try await store.setSiteVersion(project.id, "rust", rust) } catch { store.report(error) }
        }
        let venvMissing = !FileManager.default.fileExists(atPath: project.path + "/.venv/bin/python")
        if pythonSite && (isNew || venvMissing || project.runtime["python"] != original["python"]) {
            await store.preparePython(project.id, manager: manager, recreate: project.runtime["python"] != original["python"] && !isNew)
        }
    }
}
