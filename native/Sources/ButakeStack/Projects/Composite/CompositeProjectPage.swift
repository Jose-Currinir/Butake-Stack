import SwiftUI

/// The page of a project of several parts (P-39): its parts with their state and start order,
/// what each one uses of another, the Git of all its repositories, and the vault's apps and the
/// Google Cloud link its parts inherit. Its head is the project's (`DetailHeader`) with «Detener todo»
/// and «Iniciar todo».
struct CompositeProjectPage: View {
    @Bindable var store: StackStore
    let group: ProjectGroup

    private var parts: [Project] { store.projects(in: group) }

    var body: some View {
        let parts = parts
        VStack(spacing: 0) {
            header(parts)
            Divider()
            form(parts)
        }
    }

    private func form(_ parts: [Project]) -> some View {
        Form {
            CompositePartsSection(store: store, group: group, parts: parts)
            let dependencies = PartDependency.among(parts)
            if !dependencies.isEmpty {
                Section(L("composite.dependencies")) {
                    ForEach(dependencies) { DependencyRow(store: store, dependency: $0) }
                }
            }
            if store.pluginEnabled("git") {
                CompositeGitSection(store: store, group: group)
            } else {
                Section(L("composite.git")) {
                    LabeledContent {
                        Button { SettingsRouter.shared.open(.tools, tool: "git") } label: { Label(L("composite.git.enable"), systemImage: Symbols.settings) }
                            .buttonStyle(.bordered).accessibilityIdentifier("composite.git.enable")
                    } label: {
                        HStack(spacing: 10) {
                            IconTile(symbol: Symbols.git, size: 24)
                            Text(L("composite.git.off")).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            ProjectCredentialsSection(store: store, composite: group)
            if store.pluginEnabled("gcp") { GCPCompositeSection(group: group) }
        }
        .formStyle(.grouped).themedScroll()
    }

    private func header(_ parts: [Project]) -> some View {
        let working = store.compositeWorking == group.id
        return DetailHeader(title: group.name) {
            IconTile(symbol: Symbols.compositeProject, size: DetailHeaderLogo.size).accessibilityHidden(true)
        } subtitle: {
            Text(String(format: L(group.sites.count == 1 ? "composite.partsCount.one" : "composite.partsCount"), group.sites.count))
        } actions: {
            if working { ProgressView().controlSize(.small).accessibilityIdentifier("composite.working") }
            Button(L("composite.stopAll")) { Task { await store.stopAll(group) } }
                .help(L("composite.stopAllHelp"))
                .disabled(store.compositeWorking != nil || !parts.contains(where: \.enabled))
                .accessibilityIdentifier("composite.stopAll")
            Button(L("composite.startAll")) { Task { await store.startAll(group) } }
                .buttonStyle(.borderedProminent)
                .help(L(group.ordered ? "composite.startAllOrderedHelp" : "composite.startAllHelp"))
                .disabled(store.compositeWorking != nil || parts.filter { !$0.isMissing }.allSatisfy(\.enabled))
                .accessibilityIdentifier("composite.startAll")
        }
    }
}

/// «Partes»: each part with its address and state, a way to its page, and its place in the start
/// order when the parts start one after another.
private struct CompositePartsSection: View {
    @Bindable var store: StackStore
    let group: ProjectGroup
    let parts: [Project]

    var body: some View {
        Section {
            if parts.isEmpty {
                Text(L("composite.parts.empty")).foregroundStyle(.secondary).accessibilityIdentifier("composite.parts.empty")
            }
            ForEach(Array(parts.enumerated()), id: \.element.id) { index, part in
                PartRow(store: store, part: part, position: group.ordered ? index + 1 : nil) {
                    if group.ordered {
                        Button { store.moveStart(part.id, in: group.id, by: -1) } label: { Label(L("composite.parts.earlier"), systemImage: Symbols.gitMoveUp).labelStyle(.iconOnly) }
                            .buttonStyle(.borderless).disabled(index == 0)
                            .help(L("composite.parts.earlier")).accessibilityIdentifier("composite.part.earlier.\(part.id)")
                        Button { store.moveStart(part.id, in: group.id, by: 1) } label: { Label(L("composite.parts.later"), systemImage: Symbols.gitMoveDown).labelStyle(.iconOnly) }
                            .buttonStyle(.borderless).disabled(index == parts.count - 1)
                            .help(L("composite.parts.later")).accessibilityIdentifier("composite.part.later.\(part.id)")
                    }
                }
            }
            if parts.count > 1 {
                Toggle(isOn: Binding(get: { group.ordered }, set: { store.setOrdered(group.id, $0) })) {
                    Text(L("composite.parts.ordered"))
                    Text(L("composite.parts.orderedDetail"))
                }
                .accessibilityIdentifier("composite.parts.ordered")
            }
        } header: {
            Text(L("composite.parts"))
        }
    }
}

/// A part: its tile, name and address; its state; the order buttons; and «Abrir».
private struct PartRow<Order: View>: View {
    let store: StackStore
    let part: Project
    /// Its place in the start order, while the parts start in order.
    let position: Int?
    @ViewBuilder let order: Order

    var body: some View {
        let phase = store.sitePhase(part)
        LabeledContent {
            HStack(spacing: 8) {
                StatusRing(phase: phase, size: 10).accessibilityHidden(true)
                Text(part.isMissing ? L("missing.title") : part.enabled ? L("state.\(phase.rawValue)") : L("site.off"))
                    .foregroundStyle(.secondary).lineLimit(1)
                order
                Button { store.openSite(part.id) } label: { Label(String(format: L("composite.parts.open"), part.title), systemImage: Symbols.forward).labelStyle(.iconOnly) }
                    .buttonStyle(.borderless)
                    .help(String(format: L("composite.parts.open"), part.title))
                    .accessibilityIdentifier("composite.part.open.\(part.id)")
            }
        } label: {
            HStack(spacing: 10) {
                TechLogo(tech: part.tech, size: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(position.map { String(format: L("composite.parts.position"), $0, part.title) } ?? part.title).lineLimit(1)
                    Text(part.url?.absoluteString ?? part.path).font(.uiCaption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).help(part.url?.absoluteString ?? part.path)
                }
            }
        }
        .accessibilityIdentifier("composite.part.\(part.id)")
    }
}

/// «Web usa el puerto de App y servidor».
private struct DependencyRow: View {
    let store: StackStore
    let dependency: PartDependency
    private func title(_ id: String) -> String { store.projects.first { $0.id == id }?.title ?? id }
    var body: some View {
        HStack(spacing: 10) {
            IconTile(symbol: Symbols.dependency, size: 24)
            Text(String(format: L("composite.dependency.\(dependency.kind.rawValue)"), title(dependency.from), title(dependency.to)))
        }
        .accessibilityIdentifier("composite.dependency.\(dependency.id)")
    }
}
