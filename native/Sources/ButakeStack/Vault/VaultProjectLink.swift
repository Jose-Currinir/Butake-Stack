import SwiftUI

/// The link between an app of the vault and a project of Stack: the suggestion offered while the app
/// is created or edited (always confirmed by the user), what the project's page lists, and the ways
/// from one to the other.
@MainActor enum VaultProjects {
    /// A project whose id, name or folder is the app's name, or the last part of its identifier
    /// ("cl.demo.tienda" → "tienda"). Nil when nothing matches.
    static func suggestion(name: String, bundleId: String?, in projects: [Project]) -> Project? {
        let last = bundleId.flatMap { $0.split(separator: ".").last.map(String.init) }
        let wanted = Set([name, last].compactMap { $0 }.map(StackStore.slug).filter { !$0.isEmpty })
        guard !wanted.isEmpty else { return nil }
        return projects.first { project in
            [project.id, project.name, URL(fileURLWithPath: project.path).lastPathComponent].map(StackStore.slug).contains(where: wanted.contains)
        }
    }

    /// What an app's link says when it points to a project of several parts (P-39): its parts
    /// inherit the link. A plain id is a project; no project id has a colon.
    static let compositePrefix = "group:"
    static func link(composite id: String) -> String { compositePrefix + id }
    static func composite(of link: String) -> String? {
        link.hasPrefix(compositePrefix) ? String(link.dropFirst(compositePrefix.count)) : nil
    }

    /// The links that reach a project: its own and the one of the project of several parts it is a
    /// part of (`composite`, nil when it is in none).
    static func links(of project: String, composite: String?) -> Set<String> {
        Set([project] + [composite.map(link(composite:))].compactMap { $0 })
    }

    /// What the vault holds for a project: the items of the apps linked to it (or to its project of
    /// several parts), by name. Only from an unlocked index (it is encrypted on disk), and only
    /// names, kinds, stages and dates.
    static func items(of project: String, composite: String? = nil, in index: VaultIndex) -> [VaultItem] {
        let apps = Set(apps(of: project, composite: composite, in: index).map(\.id))
        return index.items.filter { apps.contains($0.container) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The apps of the vault linked to a project (or to its project of several parts).
    static func apps(of project: String, composite: String? = nil, in index: VaultIndex) -> [VaultContainer] {
        let links = links(of: project, composite: composite)
        return index.containers.filter { $0.kind == .app && $0.project.map(links.contains) == true }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// «Firma» of an app open in the vault.
    static func openSigning(_ app: VaultContainer, vault: VaultSession = .shared, store: StackStore = .shared) {
        vault.openSigning(app.id)
        store.route = .tool("vault")
    }

    /// The item open in the vault, beside its app.
    static func open(_ item: VaultItem, vault: VaultSession = .shared, store: StackStore = .shared) {
        vault.selection = .container(item.container)
        vault.inspected = item.id
        store.route = .tool("vault")
    }

    /// A project's page on one of its tabs.
    static func openProject(_ id: String, tab: ProjectPage.Tab, store: StackStore = .shared) {
        ProjectPage.requestedTab = tab
        store.openSite(id)
    }
}

/// «Proyecto» in an app's General section: the linked project, a row that leads to its page with
/// its Entornos at the end; or that there is none, with the way to link one.
struct VaultProjectRow: View {
    @Bindable var vault: VaultSession
    let container: VaultContainer
    private var store: StackStore { .shared }

    var body: some View {
        if let id = container.project.flatMap(VaultProjects.composite(of:)), let group = store.composite(id) {
            // Linked to a project of several parts: its page; each of its parts inherits the link.
            Button { store.openComposite(id) } label: {
                HStack(spacing: 10) {
                    IconTile(symbol: Symbols.compositeProject, size: 24)
                    Text(L("vault.project"))
                    Spacer(minLength: 8)
                    Text(group.name).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(group.name)
                    Image(systemName: Symbols.forward).font(.uiCaption).foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(HighlightButtonStyle())
            .help(L("vault.project.openCompositeHelp"))
            .accessibilityIdentifier("vault.detail.project")
        } else if let id = container.project, let project = store.projects.first(where: { $0.id == id }) {
            HStack(spacing: 8) {
                Button { VaultProjects.openProject(id, tab: .summary) } label: {
                    HStack(spacing: 10) {
                        IconTile(symbol: Symbols.project, size: 24)
                        Text(L("vault.project"))
                        Spacer(minLength: 8)
                        Text(project.title).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(project.title)
                        Image(systemName: Symbols.forward).font(.uiCaption).foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(HighlightButtonStyle())
                .help(L("vault.project.openHelp"))
                .accessibilityIdentifier("vault.detail.project")
                Button { VaultProjects.openProject(id, tab: .envs) } label: {
                    Label(L("vault.project.openEnvironments"), systemImage: Symbols.environments).labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless).help(L("vault.project.openEnvironments"))
                .accessibilityIdentifier("vault.detail.project.environments")
            }
        } else {
            LabeledContent {
                HStack(spacing: 8) {
                    Text(L(container.project == nil ? "vault.project.none" : "vault.project.missing")).foregroundStyle(.secondary)
                    Button { vault.sheet = .editContainer(container.id) } label: { Label(L("vault.project.link"), systemImage: Symbols.link) }
                        .buttonStyle(.bordered).accessibilityIdentifier("vault.detail.project.link")
                }
            } label: {
                HStack(spacing: 10) {
                    IconTile(symbol: Symbols.project, size: 24)
                    Text(L("vault.project"))
                }
            }
        }
    }
}

extension VaultSession {
    /// Runs right after every unlock: the app finishes there the renames that wait for the vault.
    static var onUnlock: (@MainActor () -> Void)?

    /// A project renamed (P-41): the apps linked to `from` link to `to`. Only while unlocked (the
    /// index is encrypted); each change goes to the access log, without values. A link to a project
    /// of several parts (`group:<id>`) names a folder, not a project, and never changes here.
    @discardableResult func relinkProject(from: String, to: String) throws -> Int {
        _ = try requireKey()
        var candidate = index
        var changed: [UUID] = []
        for position in candidate.containers.indices where candidate.containers[position].project == from {
            candidate.containers[position].project = to
            changed.append(candidate.containers[position].id)
        }
        guard !changed.isEmpty else { return 0 }
        try persist(candidate)
        for id in changed { disk.append(VaultAccessEntry(action: .editContainer, target: id)) }
        return changed.count
    }
}
