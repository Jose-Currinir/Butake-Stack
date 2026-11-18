import SwiftUI

/// The version of a language this project runs on, as a menu in its summary: the installed versions,
/// «Instalar otra versión…» (the language's own picker, in a sheet) and «Ver en Lenguajes». Changing
/// it writes the project's version file and can be undone with ⌘Z.
struct ProjectVersionRow: View {
    @Bindable var store: StackStore
    let project: Project
    /// php, node, jdk or python: the key of `Project.runtime`.
    let key: String
    @Environment(\.undoManager) private var undoManager
    @State private var installing = false

    var tech: Tech { .of(key) }
    /// The name of the language page and of its version provider.
    var language: String { Self.language(of: key) }
    var current: String { project.runtime[key] ?? "" }

    static func language(of key: String) -> String { key == "jdk" ? "java" : key }

    /// What is installed for the language, oldest first, plus the version the project already has.
    var choices: [String] { Self.choices(key: key, installed: installed, current: project.runtime[key]) }
    private var installed: [String] {
        switch key {
        case "php": store.phpRuntimes.filter(\.installed).map(\.series)
        case "python": store.pythonRuntimes.map(\.line)
        default: (store.installedTools[key] ?? []).map { String($0.version.split(separator: ".").first ?? "") }
        }
    }

    /// Distinct versions in numeric order; the current one is always there, installed or not.
    static func choices(key: String, installed: [String], current: String?) -> [String] {
        Array(Set(installed + [current].compactMap { $0 }.filter { !$0.isEmpty }))
            .sorted { $0.compare($1, options: .numeric) == .orderedAscending }
    }

    var body: some View {
        LabeledContent {
            Menu {
                // Inside a menu a picker shows its choice with a check.
                Picker(String(format: L("project.version.label"), tech.title), selection: Binding(get: { current }, set: change(to:))) {
                    ForEach(choices, id: \.self) { version in
                        Text(version).tag(version).accessibilityIdentifier("project.language.\(key).\(version)")
                    }
                }
                .pickerStyle(.inline).labelsHidden()
                Divider()
                Button { installing = true } label: { Label(L("engine.otherVersion"), systemImage: Symbols.install) }
                    .accessibilityIdentifier("project.language.\(key).install")
                Button { store.route = .language(language) } label: { Label(L("project.version.seeLanguages"), systemImage: Symbols.forward) }
                    .accessibilityIdentifier("project.language.\(key).open")
            } label: {
                Text(current).monospacedDigit()
            }
            .fixedSize()
            .disabled(store.busy != nil)
            .help(String(format: L("project.version.help"), tech.title))
            .accessibilityLabel(String(format: L("project.version.label"), tech.title))
            .accessibilityValue(current)
            .accessibilityIdentifier("project.language.\(key).menu")
        } label: {
            HStack(spacing: 10) {
                TechLogo(tech: tech, size: 24)
                Text(tech.title)
            }
        }
        .contextMenu {
            Button { store.route = .language(language) } label: { Label(L("project.version.seeLanguages"), systemImage: Symbols.forward) }
        }
        .accessibilityIdentifier("project.language.\(key)")
        .sheet(isPresented: $installing) {
            VersionPickerSheet(store: store, provider: .language(language, store: store), scope: "project.\(language)").themedSheet()
        }
    }

    private func change(to version: String) {
        guard version != current else { return }
        let previous = current
        Task { @MainActor in
            if await Self.apply(version, replacing: previous, key: key, of: project, store: store, undoManager: undoManager) {
                store.notify(String(format: L("project.version.changed"), tech.title, version))
            }
        }
    }

    /// Writes the version in the project's own file (the engine does), brings Python's `.venv` along
    /// and registers the way back: ⌘Z returns to `previous`, and that undo is itself undoable.
    @MainActor static func apply(_ version: String, replacing previous: String, key: String, of project: Project,
                                 store: StackStore, undoManager: UndoManager?) async -> Bool {
        var done = false
        await store.run(L("busy.saving"), refresh: true) {
            try await store.setSiteVersion(project.id, key, version)
            done = true
        }
        guard done else { return false }
        if key == "python", ["django", "fastapi"].contains(project.kind) {
            await store.preparePython(project.id, recreate: true)
        }
        if let undoManager, !previous.isEmpty {
            undoManager.registerUndo(withTarget: store) { store in
                Task { @MainActor in
                    _ = await apply(previous, replacing: version, key: key, of: project, store: store, undoManager: undoManager)
                }
            }
            undoManager.setActionName(String(format: L("project.version.undo"), Tech.of(key).title))
        }
        return true
    }
}
