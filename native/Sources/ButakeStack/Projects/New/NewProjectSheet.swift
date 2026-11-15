import AppKit
import SwiftUI

/// Project assistant. A sidebar of project kinds (and "open an existing folder"); each kind shows
/// what it needs, its templates and options, and creates the project with its official generator
/// and the stack's own PHP, Composer and Node. Creating shows each step live, and ends in a summary
/// with what to do next; a failure says why and keeps the log. Created and opened projects go
/// through the same detection. Sites are registered off, like every site.
struct NewProjectSheet: View {
    @Bindable var store: StackStore
    @Environment(\.dismiss) var dismiss
    @AppStorage("newProject.kind") private var savedKind = "laravel"
    @State var selection: Selection = .kind("laravel")
    @State var name = ""
    /// A folder chosen with «Elegir…»: used as it is, without App, Service or Web.
    @State var chosenParent: String?
    /// The subfolder picked in the form; nil follows the kind's suggestion.
    @State var placeChoice: ProjectPlace?
    @AppStorage(Folder.sortsKey) var sortsByPlace = true
    @State var kit = "none"
    @State var testing = "pest"
    @State var database = "sqlite"
    @State var templates: [String: String] = [:]
    @State var platform = "cloudflare"
    @State var python = ""
    @State var php = ""
    /// pip and venv (with every Python) or uv (optional, recommended when installed).
    @State var manager = "pip"
    @State private var managerChosen = false
    /// Framework line ("5.2", "12"); empty: the newest that fits the chosen language.
    @State var frameworkVersion = ""
    @State var git = true
    @AppStorage("newProject.group") var groupChoice = ""
    @State var phase: Phase = .form
    @State var log: [String] = []
    @State var started = Date()
    @State var showLog = false
    @State var dropping = false
    @FocusState var nameFocused: Bool

    enum Selection: Hashable { case kind(String), open }
    enum Phase { case form, creating, done(CreatedProject), failed(String) }

    var kind: String { if case .kind(let id) = selection { id } else { "" } }
    var info: ProjectKindInfo { ProjectKindInfo.of(kind) }
    var slug: String {
        name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }.reduce(into: "") { $0.append($1) }
            .split(separator: "-").joined(separator: "-")
    }
    var template: String { templates[kind] ?? ProjectKindInfo.templates[kind]?.first?.id ?? "" }
    var suggestedPlace: ProjectPlace { ProjectPlace.suggested(kind: kind, template: template) ?? .web }
    var place: ProjectPlace { placeChoice ?? suggestedPlace }
    /// Where the project's folder goes: the one chosen by hand, else the projects folder of Ajustes ›
    /// Avanzado (in the place's subfolder unless sorting is off there).
    var parent: String { chosenParent ?? Folder.newProjects(in: place) }
    var target: String { (parent as NSString).appendingPathComponent(slug) }
    var address: String { "\(info.proxied ? "https" : "http")://\(slug).test" }

    // MARK: Requirements and validation

    var phpVersion: String? { chosenPhp ?? store.phpRuntimes.filter(\.installed).map(\.series).sorted().last }
    var needsPython: Bool { kind == "django" || kind == "fastapi" }
    /// Installed lines of a language, newest first.
    var installedPython: [String] { store.pythonRuntimes.map(\.line).sorted { $0.compare($1, options: .numeric) == .orderedDescending } }
    var installedPhp: [String] { store.phpRuntimes.filter(\.verified).map(\.series).sorted { $0.compare($1, options: .numeric) == .orderedDescending } }
    /// What the framework's newest version needs (PyPI's requires_python, Packagist's require.php).
    var requirement: FrameworkRequirement? { store.requirements[kind] }
    func compatible(_ line: String) -> Bool { requirement.map { $0.compatible.contains(line) } ?? true }
    /// The newest installed line that the framework supports: what the assistant proposes.
    var proposedPython: String? { installedPython.first(where: compatible) ?? installedPython.first }
    var chosenPython: String? { python.isEmpty ? proposedPython : python }
    var proposedPhp: String? { installedPhp.first(where: compatible) ?? installedPhp.first }
    var chosenPhp: String? { kind == "laravel" ? (php.isEmpty ? proposedPhp : php) : nil }
    /// The language line the project will use (Python or PHP).
    var chosenLanguage: String? { kind == "laravel" ? chosenPhp : chosenPython }
    var frameworkVersions: [FrameworkVersion] { requirement?.versions ?? [] }
    /// The newest framework line that supports the chosen language line.
    var proposedFramework: FrameworkVersion? {
        frameworkVersions.first { v in chosenLanguage.map { v.compatible.contains($0) } ?? true } ?? frameworkVersions.first
    }
    func frameworkNote(_ language: String) -> String? {
        chosenFramework.map { String(format: L("new.requires"), "\(L("kind.\(kind)")) \($0.cycle)", "\(language) \(FrameworkVersionChoice.range($0.requirement))") }
    }
    var chosenFramework: FrameworkVersion? {
        frameworkVersions.first { $0.cycle == frameworkVersion && (chosenLanguage.map($0.compatible.contains) ?? true) } ?? proposedFramework
    }
    var nodeVersion: String? { (store.installedTools["node"] ?? []).map(\.version).sorted { $0.compare($1, options: .numeric) == .orderedDescending }.first }
    var needsNode: Bool { info.needsNode || (kind == "laravel" && kit != "none") }
    @State var installing = false
    var installsHere: Bool { (info.needsPhp && phpVersion == nil) || (needsNode && nodeVersion == nil) || (needsPython && installedPython.isEmpty) }
    /// The language page that installs what `missingRuntime` reports.
    var installLanguage: String {
        if info.needsPhp && phpVersion == nil { return "php" }
        if needsNode && nodeVersion == nil { return "node" }
        if needsPython { return "python" }
        return info.needsTool == "rustup" ? "rust" : "swift"
    }
    var missingRuntime: String? {
        if info.needsPhp && phpVersion == nil { return L("new.needsPhp") }
        if needsNode && nodeVersion == nil { return L("new.needsNode") }
        if needsPython && installedPython.isEmpty { return L("new.needsPython") }
        if needsPython && manager == "uv" && store.devTools["uv"]?.installed != true { return String(format: L("new.needsTool"), L("tool.uv")) }
        if let tool = info.needsTool {
            let ready = tool == "clt" ? store.appleTools : (store.devTools[tool]?.installed == true && store.devTools[tool]?.broken != true)
            if !ready { return String(format: L("new.needsTool"), L("tool.\(tool)")) }
        }
        return nil
    }
    /// What's wrong with the name, if anything: checked as the user types.
    var nameProblem: String? {
        if slug.isEmpty { return nil }
        if slug.count > 40 { return L("new.problem.long") }
        if FileManager.default.fileExists(atPath: target) { return L("new.problem.folder") }
        if store.projects.contains(where: { $0.id == slug }) { return L("new.problem.site") }
        return nil
    }
    var canCreate: Bool { !slug.isEmpty && nameProblem == nil && missingRuntime == nil && !parent.isEmpty && !info.wizard }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(spacing: 0) {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                footer
            }
        }
        .frame(minWidth: 780, idealWidth: 880, minHeight: 560, idealHeight: 680)
        .interactiveDismissDisabled(isCreating)
        .onAppear {
            if ProjectKindInfo.all.contains(where: { $0.id == savedKind }) { selection = .kind(savedKind) }
            nameFocused = true
        }
        .onChange(of: selection) { _, new in
            if case .kind(let id) = new { savedKind = id }
            // Another kind brings its own suggestion.
            placeChoice = nil
        }
        .task {
            if store.installedTools["node"] == nil { await store.refreshRuntimes() }
            if store.projectVersions.isEmpty { await store.loadProjectVersions() }
            if store.devTools.isEmpty || store.pythonLines.isEmpty { await store.refreshDevTools() }
            if store.devTools["uv"]?.installed == true && manager == "pip" && !managerChosen { manager = "uv" }
        }
        .task(id: kind) {
            if ["django", "fastapi", "laravel"].contains(kind) {
                await store.loadLifecycle(kind == "laravel" ? "php" : "python")
                await store.loadRequirement(kind)
            }
        }
        .onChange(of: manager) { _, _ in managerChosen = true }
        #if DEBUG
        .task { await qaNewProject() }
        #endif
    }

    var isCreating: Bool { if case .creating = phase { true } else { false } }
    var isForm: Bool { if case .form = phase { true } else { false } }

    // MARK: Sidebar

    /// The kinds of project by group, and opening an existing folder: a list the arrow keys move through.
    private var sidebar: some View {
        List(selection: Binding(get: { selection }, set: { if let new = $0 { select(new) } })) {
            ForEach(ProjectKindInfo.groups, id: \.self) { group in
                Section(L("new.group.\(group)")) {
                    ForEach(ProjectKindInfo.all.filter { $0.group == group }) { item in
                        Label { Text(L("kind.\(item.id)")) } icon: { TechLogo(tech: .of(item.logo), size: 20) }
                            .tag(Selection.kind(item.id))
                            .accessibilityIdentifier("new.kind.\(item.id)")
                    }
                }
            }
            Section {
                Label { Text(L("new.modeOpen")) } icon: { IconTile(symbol: Symbols.folder, size: 20) }
                    .tag(Selection.open)
                    .accessibilityIdentifier("new.mode.open")
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 200, idealWidth: 230, maxWidth: 260)
        .disabled(!isForm)
        .accessibilityIdentifier("new.kinds")
    }

    func select(_ new: Selection) {
        withAnimation(.snappy(duration: 0.25)) { selection = new }
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        switch phase {
        case .form:
            Group {
                if selection == .open { openPane } else if info.wizard { wizardPane } else { form }
            }
            .id(selection)
            .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 8)), removal: .opacity))
        case .creating:
            creatingPane.transition(.opacity.combined(with: .scale(scale: 0.98)))
        case .done(let created):
            donePane(created).transition(.opacity.combined(with: .scale(scale: 0.98)))
        case .failed(let message):
            failedPane(message).transition(.opacity)
        }
    }

    /// Why «Crear proyecto» is off, said in the footer; nil when the project can be created.
    var blockedReason: String? {
        if slug.isEmpty { return L("new.blocked.name") }
        if let nameProblem { return nameProblem }
        if let missingRuntime { return missingRuntime }
        if parent.isEmpty { return L("new.blocked.location") }
        return nil
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            switch phase {
            case .form:
                if selection != .open && !info.wizard {
                    if let blockedReason {
                        Label(blockedReason, systemImage: Symbols.info).font(.uiCaption).foregroundStyle(.secondary)
                            .lineLimit(2).truncationMode(.tail).help(blockedReason)
                            .accessibilityIdentifier("new.blocked")
                    } else {
                        let summary = String(format: L("new.summary"), L("kind.\(kind)"), target.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        Text(summary).font(.uiCaption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(summary)
                    }
                }
                Spacer()
                Button(L("common.cancel")) { dismiss() }.keyboardShortcut(.cancelAction).accessibilityIdentifier("new.cancel")
                if selection != .open && !info.wizard {
                    Button(L("new.create")) { create() }
                        .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                        .disabled(!canCreate).accessibilityIdentifier("new.create")
                }
            case .creating:
                Text(L("new.creatingHint")).font(.uiCaption).foregroundStyle(.secondary)
                Spacer()
            case .done(let created):
                Button { reset() } label: { Label(L("new.another"), systemImage: Symbols.add) }.accessibilityIdentifier("new.another")
                Spacer()
                Button(L("new.goToSite")) { finish(created) }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("new.goToSite")
            case .failed:
                Button { withAnimation(.snappy) { phase = .form } } label: { Label(L("new.back"), systemImage: Symbols.back) }
                    .accessibilityIdentifier("new.back")
                Spacer()
                Button(L("common.cancel")) { dismiss() }.keyboardShortcut(.cancelAction).accessibilityIdentifier("new.cancel")
                Button(L("common.retry")) { create() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("new.retry")
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }

    // MARK: Actions

    func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.directoryURL = FileManager.default.fileExists(atPath: parent) ? URL(fileURLWithPath: parent) : URL(fileURLWithPath: NSHomeDirectory())
        panel.prompt = L("new.choosePrompt")
        if panel.runModal() == .OK, let url = panel.url { chosenParent = url.path }
    }
    func chooseExisting() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.directoryURL = Folder.ensureProjects()
        panel.prompt = L("site.chooseFolder")
        if panel.runModal() == .OK, let url = panel.url { open(url.path) }
    }
    /// Detection shows its editor once this sheet is gone (two sheets can't stack).
    func open(_ path: String) {
        dismiss()
        Task {
            try? await Task.sleep(for: .milliseconds(350))
            await store.openFolder(path)
        }
    }
    func create() {
        // The projects folder and its App, Service or Web are made the first time a project goes there.
        if chosenParent == nil { Folder.ensureProjects(parent) }
        var request: [String: Any] = ["kind": kind, "name": slug, "parent": parent, "git": git]
        switch kind {
        case "laravel": request.merge(["kit": kit, "testing": testing, "database": database, "php": chosenPhp ?? "", "frameworkVersion": kit == "none" ? chosenFramework?.cycle ?? "" : ""]) { $1 }
        case "astro", "next", "vite", "rust", "swift", "react-native": request["template"] = template
        case "django", "fastapi": request.merge(["python": chosenPython ?? "", "manager": manager, "frameworkVersion": chosenFramework?.cycle ?? ""]) { $1 }
        case "emdash": request.merge(["template": template, "platform": platform]) { $1 }
        default: break
        }
        log = []
        started = Date()
        withAnimation(.smooth(duration: 0.35)) { phase = .creating }
        Task {
            let result = await store.createProject(request)
            log = await store.stepLog("create-\(slug)")
            withAnimation(.smooth(duration: 0.35)) {
                switch result {
                case .success(var created):
                    created.seconds = Date().timeIntervalSince(started)
                    if let site = created.project, store.groups.contains(where: { $0.id == groupChoice }) { store.move(site.id, to: groupChoice) }
                    phase = .done(created)
                case .failure(let failure):
                    phase = .failed(failure.message)
                }
            }
        }
    }
    func finish(_ created: CreatedProject) {
        if let site = created.project { store.openSite(site.id) }
        dismiss()
    }
    func reset() {
        name = ""
        log = []
        withAnimation(.snappy) { phase = .form }
        nameFocused = true
    }
}

/// A created project and the next steps the engine noted.
// MARK: Pieces
