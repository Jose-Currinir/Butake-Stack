import SwiftUI

/// A language: its versions (the global one marked), its options and the projects that use it.
/// Its header (`DetailHeader`) says which one it is, the global version and how many are installed, and
/// holds «Instalar versión…»; versions are managed only here.
struct LanguagePage: View {
    @Bindable var store: StackStore
    let name: String
    var scope: String { "language.\(name)" }
    var users: [Project] { store.projects.filter(usesLanguage) }
    @State private var installRequest = false
    /// From this width the sections go in two columns: versions at the left, the rest at the right.
    static let twoColumnsFrom: CGFloat = 1100

    var body: some View {
        let provider = VersionProvider.language(name, store: store)
        VStack(spacing: 0) {
            header(provider)
            Divider()
            GeometryReader { geometry in
                if geometry.size.width >= Self.twoColumnsFrom {
                    HStack(alignment: .top, spacing: 0) {
                        form { versions(provider) }
                        form { rest }
                    }
                } else {
                    form { versions(provider); rest }
                }
            }
        }
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
    private func header(_ provider: VersionProvider) -> some View {
        DetailHeader(title: Tech.of(name).title) {
            TechLogo(tech: .of(name), size: DetailHeaderLogo.size)
        } subtitle: {
            Text(summary(provider)).accessibilityIdentifier("\(scope).summary")
        } actions: {
            // Rust and Swift need their installer first: its row in the versions stands in for the button.
            if provider.requirement == nil {
                Button { installRequest = true } label: { Label(L("runtimes.installVersion"), systemImage: Symbols.install) }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.busy != nil)
                    .accessibilityIdentifier("\(scope).versions.install")
            }
        }
    }

    /// «Global 8.4.27 · 2 versiones instaladas», or «Sin instalar».
    func summary(_ provider: VersionProvider) -> String {
        let installed = provider.installed
        guard !installed.isEmpty else { return L("language.notInstalled") }
        var parts: [String] = []
        if let global = installed.first(where: \.global) { parts.append(String(format: L("language.globalVersion"), global.version)) }
        parts.append(String(format: L("language.installedCount"), installed.count))
        return parts.joined(separator: " · ")
    }

    private func form<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        Form {
            content()
        }
        .formStyle(.grouped).themedScroll()
    }

    @ViewBuilder private func versions(_ provider: VersionProvider) -> some View {
        PartialFailureNotice(store: store, area: .runtimes).listRowBackground(Color.clear).listRowInsets(EdgeInsets())
        VersionsSection(store: store, provider: provider, scope: scope,
                        footer: L("language.\(name).versionsFooter"), installRequest: $installRequest)
    }

    @ViewBuilder private var rest: some View {
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
