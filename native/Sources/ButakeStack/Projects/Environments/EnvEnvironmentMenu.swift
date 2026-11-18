import SwiftUI

/// The environment itself (activate, duplicate, rename, delete) as a menu next to the selector and
/// as the selector's context menu. What can be taken back registers its undo; deleting, which also
/// removes the Keychain items, keeps its confirmation.
extension EnvironmentsView {
    var environmentMenu: some View {
        Menu { environmentActions } label: { Label(L("env.actions"), systemImage: Symbols.more) }
            .menuStyle(.borderlessButton).labelStyle(.iconOnly).fixedSize()
            .help(L("env.actions")).accessibilityIdentifier("env.actions")
    }

    @ViewBuilder var environmentActions: some View {
        if let current {
            Button {
                if current.kind == .production { confirmProduction = true } else { Task { await activate(current) } }
            } label: { Label(String(format: L("env.activate"), current.title), systemImage: Symbols.active) }
                .disabled(store.busy != nil || state?.site.active == current.id && !dirty)
                .accessibilityIdentifier("env.menu.activate")
            Button { Task { await duplicate(current) } } label: { Label(L("env.duplicate"), systemImage: Symbols.copy) }
                .disabled(store.busy != nil || dirty).accessibilityIdentifier("env.menu.duplicate")
            Button { renaming = true } label: { Label(L("env.rename"), systemImage: Symbols.edit) }
                .disabled(current.kind != .other).help(current.kind == .other ? "" : L("env.renameStandard"))
                .accessibilityIdentifier("env.menu.rename")
            Divider()
            Button(role: .destructive) { confirmDelete = true } label: { Label(L("env.delete"), systemImage: Symbols.delete) }
                .disabled(state?.site.active == current.id).accessibilityIdentifier("env.menu.delete")
        }
    }

    /// Selects an environment that just appeared; unsaved edits ask first.
    func adopt(_ id: String) {
        if !dirty || confirmDiscard() { selected = id; load() }
    }

    /// The selected environment is gone (deleted, or an undo removed it): show another one.
    func reconcileSelection() {
        if let selected, !environments.contains(where: { $0.id == selected }) { load() }
    }

    /// A file dropped: «Local» when there is nothing yet, else a preview to confirm a new environment.
    func dropEnv(_ url: URL) {
        if environments.isEmpty {
            Task { if await store.importEnvFile(project, from: url) { selected = "local"; load() } }
        } else if let preview = store.envDropPreview(project, url: url) {
            dropPreview = preview
        }
    }

    func duplicate(_ source: EnvEnvironment) async {
        let taken = Set(environments.map(\.id))
        let target = EnvDrop.target(String(format: L("env.copyName"), source.title), taken: taken, fallback: source.title)
        guard let id = await store.createEnvironment(project, name: target.name, kind: target.kind, from: source.id) else { return }
        adopt(id)
        let project = project, store = store
        store.undoable(String(format: L("env.undo.duplicate"), source.title), undo: {
            await store.deleteEnvironment(project, id)
        }, redo: {
            _ = await store.createEnvironment(project, name: target.name, kind: target.kind, from: source.id)
        })
    }

    /// Activation can be undone by activating the one that was active, except around Production,
    /// which always asks for its own confirmation.
    func undoActivation(from previous: EnvEnvironment?, to env: EnvEnvironment) {
        guard let previous, previous.kind != .production, env.kind != .production else { return }
        let project = project, store = store
        store.undoable(String(format: L("env.undo.activate"), env.title), undo: {
            await store.activateEnvironment(project, previous, restart: false)
        }, redo: {
            await store.activateEnvironment(project, env, restart: false)
        })
    }
}

extension StackStore {
    /// Changes the name of a custom environment (its id, and so its Keychain item, stay). False, with
    /// a message, when another environment already has that name.
    func renameEnvironment(_ project: Project, _ id: String, to name: String) async -> Bool {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard var site = envs[project.id]?.site, let index = site.environments.firstIndex(where: { $0.id == id }),
              site.environments[index].kind == .other else { return false }
        guard !name.isEmpty, !site.environments.contains(where: { $0.id != id && $0.title.caseInsensitiveCompare(name) == .orderedSame }) else {
            errorMessage = L("env.nameTaken")
            return false
        }
        let old = site.environments[index].name
        guard old != name else { return true }
        site.environments[index].name = name
        guard await saveEnvs(project.id, site) else { return false }
        undoable(String(format: L("env.undo.rename"), old), undo: {
            _ = await self.renameEnvironment(project, id, to: old)
        }, redo: {
            _ = await self.renameEnvironment(project, id, to: name)
        })
        return true
    }
}
