import SwiftUI

/// A language: its versions (the global one marked), its options and the projects that use it.
/// The title lives in the window's bar; versions are managed only here.
struct LanguagePage: View {
    @Bindable var store: StackStore
    let name: String
    var scope: String { "language.\(name)" }
    var users: [Project] { store.projects.filter(usesLanguage) }

    var body: some View {
        Form {
            PartialFailureNotice(store: store, area: .runtimes).listRowBackground(Color.clear).listRowInsets(EdgeInsets())
            VersionsSection(store: store, provider: .language(name, store: store), scope: scope,
                            footer: L("language.\(name).versionsFooter"))
            LanguageOptionsSection(store: store, language: name)
            Section(L("engine.sites")) {
                if users.isEmpty {
                    Text(L("engine.noSites")).foregroundStyle(.secondary)
                }
                ForEach(users) { project in
                    ProjectLinkRow(project: project, detail: siteDetail(project)) { store.openSite(project.id) }
                        .accessibilityIdentifier("\(scope).project.\(project.id)")
                }
            }
        }
        .formStyle(.grouped).themedScroll()
        .task {
            await store.refreshRuntimes()
            if name == "php" { await store.loadLifecycle("php") }
            if ["python", "rust", "swift"].contains(name) { await store.refreshDevTools() }
        }
        // At first and again when rustup or swiftly is installed from the page: it unlocks the versions.
        .task(id: store.devTools["rustup"]?.installed == true || store.devTools["swiftly"]?.installed == true) {
            if name == "rust" { await store.loadRust() }
            if name == "swift" { await store.loadSwift(available: true) }
        }
    }
}

extension LanguagePage {
    func usesLanguage(_ project: Project) -> Bool {
        switch name {
        case "php": project.php != nil
        case "java": project.runtime["jdk"] != nil
        case "python": ["django", "fastapi"].contains(project.kind) || project.runtime["python"] != nil
        case "rust": project.kind == "rust"
        case "swift": project.kind == "swift"
        default: project.node != nil
        }
    }
    func siteDetail(_ project: Project) -> String {
        switch name {
        case "php": "PHP \(project.php ?? "")"
        case "java": "Java \(project.runtime["jdk"] ?? "")"
        case "python": project.runtime["python"].map { "Python \($0)" } ?? L("kind.\(project.kind)")
        case "rust": "Rust"
        case "swift": "Swift"
        default: "Node \(project.node ?? "")"
        }
    }
}
