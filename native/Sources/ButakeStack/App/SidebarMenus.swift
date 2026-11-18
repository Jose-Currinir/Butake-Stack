import SwiftUI

/// The right-click menu of a row of Herramientas or Nube: the same actions as its page and its
/// switch in Ajustes › Herramientas. Registros is not a tool that can be turned off: only «Abrir».
struct ToolMenuItems: View {
    let store: StackStore
    let id: String
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        Button { store.route = .tool(id) } label: { Label(L("common.open"), systemImage: Symbols.forward) }
            .accessibilityIdentifier("sidebar.menu.open.\(id)")
        if let plugin = store.plugins.first(where: { $0.id == id }) {
            Divider()
            Button { SettingsRouter.shared.open(.tools, tool: id) } label: { Label(L("sidebar.menu.toolSettings"), systemImage: Symbols.settings) }
                .accessibilityIdentifier("sidebar.menu.settings.\(id)")
            Button { turnOff(plugin) } label: { Label(L("sidebar.menu.turnOff"), systemImage: Symbols.stop) }
                .accessibilityIdentifier("sidebar.menu.turnOff.\(id)")
        }
    }

    /// Turns the tool off (its data stays) and lets ⌘Z turn it on again.
    private func turnOff(_ plugin: ToolInfo) {
        let store = store
        undoManager?.registerUndo(withTarget: store) { store in Task { await store.setPlugin(plugin, enabled: true) } }
        undoManager?.setActionName(String(format: L("sidebar.menu.undoTurnOff"), plugin.title))
        Task { await store.setPlugin(plugin, enabled: false) }
    }
}

/// The right-click menu of a row of Componentes: its page, or straight to one of its categories.
struct ComponentMenuItems: View {
    let store: StackStore
    let component: Component

    var body: some View {
        Button { store.route = component.lastRoute() } label: { Label(L("common.open"), systemImage: Symbols.forward) }
            .accessibilityIdentifier("sidebar.menu.open.\(component.rawValue)")
        Menu {
            ForEach(component.categories, id: \.self) { category in
                Button { store.route = component.route(category) } label: { Text(component.tech(of: category).title) }
                    .accessibilityIdentifier("sidebar.menu.category.\(component.rawValue).\(category)")
            }
        } label: { Label(L("sidebar.menu.category"), systemImage: Symbols.forward) }
            .accessibilityIdentifier("sidebar.menu.categories.\(component.rawValue)")
    }
}
