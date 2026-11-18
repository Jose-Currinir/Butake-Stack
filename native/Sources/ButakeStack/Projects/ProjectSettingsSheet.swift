import SwiftUI

/// Ajustes del proyecto, and the same form for a project just detected. Everything the engine
/// proposes is editable; this is the only place where a project is edited.
struct ProjectSettingsSheet: View {
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
    /// «Comprobar» and «Compilar» of a project without a server, as command lines.
    @State private var commands: [String: String] = [:]

    init(store: StackStore, project: Project, notes: [String], isNew: Bool) {
        self.store = store
        _project = State(initialValue: project)
        self.notes = notes
        self.isNew = isNew
        _domain = State(initialValue: project.domain)
        _original = State(initialValue: project.runtime)
        _commands = State(initialValue: Dictionary(uniqueKeysWithValues: Self.commandNames.map { name in
            (name, project.processes.first { $0.name == name }?.editableLine ?? "")
        }))
    }

    /// The commands a project without a server defines here.
    static let commandNames = ["check", "build"]
    /// Kinds whose own server Caddy proxies to: they have a port.
    static let proxied: Set<String> = ["astro", "emdash", "next", "kmp", "node", "proxy", "django", "fastapi", "rust"]

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
        SheetFrame(title: isNew ? L("editor.newTitle") : L("project.settingsTitle"), symbol: Symbols.settings,
                   detail: project.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"),
                   width: 600, height: 560,
                   actionTitle: isNew ? L("editor.create") : L("common.save"), actionID: "editor.save",
                   cancelID: "editor.cancel") {
            // A project without a server keeps the domains it had (its kind back gives them again).
            if project.isServed {
                project.domains = [domain.lowercased().trimmingCharacters(in: .whitespaces)] + project.domains.dropFirst()
            } else {
                applyCommands()
            }
            guard await store.save(project) else { return false }
            await applyVersions()
            return true
        } content: {
            form
        }
        .task {
            if project.kind == "rust" {
                await store.loadRust()
                let files: [String: String?]? = try? await store.call(["method": "siteVersionFiles", "id": project.id])
                rust = (files?["rust"] ?? nil) ?? ""
                originalRust = rust
            }
        }
    }

    private var form: some View {
        Form {
            Section {
                TextField(L("common.name"), text: $project.name).accessibilityIdentifier("editor.name")
                if project.isServed {
                    TextField(L("site.domain"), text: $domain).accessibilityIdentifier("editor.domain")
                }
                Picker(L("common.type"), selection: $project.kind) {
                    ForEach(["laravel", "php", "astro", "emdash", "next", "django", "fastapi", "rust", "kmp", "node", "static", Project.unserved], id: \.self) { Text(L("kind.\($0)")).tag($0) }
                }.accessibilityIdentifier("editor.kind")
                if project.isServed {
                    TextField(L("site.docroot"), text: $project.docroot).accessibilityIdentifier("editor.docroot")
                    Toggle(L("site.https"), isOn: $project.https).accessibilityIdentifier("editor.https")
                }
                // The port of its own server: Stack picks a free one; a fixed one is checked
                // against every other project when saving.
                if Self.proxied.contains(project.kind) {
                    TextField(L("editor.port"), value: $project.upstream, format: .number.grouping(.never), prompt: Text(L("editor.portAuto")))
                        .accessibilityIdentifier("editor.port")
                }
            } footer: {
                if !project.isServed {
                    Text(L("unserved.detail")).font(.uiCaption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if !project.isServed {
                Section {
                    ForEach(Self.commandNames, id: \.self) { name in
                        TextField(ProjectCommandsSection.title(name), text: Binding(get: { commands[name] ?? "" }, set: { commands[name] = $0 }),
                                  prompt: Text(L("commands.\(name)Prompt")))
                            .accessibilityIdentifier("editor.command.\(name)")
                    }
                } header: {
                    Text(L("commands.title"))
                } footer: {
                    Text(L("commands.editHelp")).font(.uiCaption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
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
                if let node = project.node, !(store.installedTools["node"] ?? []).contains(where: { $0.version.hasPrefix(node + ".") }) {
                    Label(String(format: L("editor.nodeMissing"), node), systemImage: Symbols.warning).foregroundStyle(Brand.warning)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if pythonSite && !isNew {
                    LabeledContent(L("editor.venv")) {
                        Button { Task { await store.preparePython(project.id, manager: manager, recreate: true) } } label: {
                            Label(L("editor.recreateVenv"), systemImage: Symbols.reload)
                        }
                        .buttonStyle(.bordered).disabled(store.busy != nil).accessibilityIdentifier("editor.recreateVenv")
                    }
                }
            } header: {
                Text(L("site.environment"))
            } footer: {
                Text(L("editor.versionFiles")).font(.uiCaption).foregroundStyle(.secondary).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
            }
            if project.isServed && !project.processes.isEmpty {
                Section {
                    ForEach($project.processes) { $process in
                        Toggle(isOn: $process.autostart) {
                            Text(process.name)
                            Text(process.commandLine).font(.uiCaption.monospaced()).lineLimit(1).truncationMode(.middle).help(process.commandLine)
                        }.accessibilityIdentifier("editor.process.\(process.name)")
                    }
                } header: {
                    Text(L("site.processes"))
                } footer: {
                    Text(L("editor.processesHelp")).font(.uiCaption).foregroundStyle(.secondary).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if !notes.isEmpty {
                Section(L("editor.notes")) {
                    ForEach(notes, id: \.self) { Label(L("note.\($0)"), systemImage: Symbols.info).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading) }
                }
            }
        }
        .formStyle(.grouped).themedScroll()
        .frame(minHeight: 280)
        // A project that becomes served gets an address to start from.
        .onChange(of: project.kind) { _, _ in
            if project.isServed && domain.isEmpty { domain = "\(project.id).\(store.config?.tld.first ?? "test")" }
        }
    }

    /// «Comprobar» and «Compilar» into the project's processes: the program and its arguments as
    /// words (no shell; quotes and backslashes group a word), never started on their own; an empty
    /// line removes the command. A command whose text was not edited is left as it is.
    func applyCommands() {
        for name in Self.commandNames {
            let text = commands[name] ?? ""
            if text == project.processes.first(where: { $0.name == name })?.editableLine ?? "" { continue }
            let words = ProjectProcess.words(of: text)
            project.processes.removeAll { $0.name == name }
            if let program = words.first {
                project.processes.append(ProjectProcess(name: name, program: program, args: Array(words.dropFirst()), autostart: false))
            }
        }
        project.processes.sort { (Self.commandNames.firstIndex(of: $0.name) ?? 2) < (Self.commandNames.firstIndex(of: $1.name) ?? 2) }
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
