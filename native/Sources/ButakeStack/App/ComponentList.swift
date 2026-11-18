import SwiftUI

/// The content column of a row of Componentes (Servicios, Lenguajes, Utilidades): its categories,
/// each with its state, and the category's page as the detail. Selecting one is going to its route,
/// so links, Ir, the palette and the search land on the same row.
struct ComponentList: View {
    @Bindable var store: StackStore
    let component: Component

    var body: some View {
        List(selection: Binding(get: { store.route }, set: { if let route = $0 { store.route = route } })) {
            ForEach(component.categories, id: \.self) { category in
                ComponentCategoryRow(store: store, component: component, category: category)
                    .tag(component.route(category))
                    .accessibilityIdentifier("components.\(component.rawValue).\(category)")
            }
        }
        .listStyle(.sidebar)
        .themedScroll()
        .accessibilityIdentifier("components.\(component.rawValue).list")
    }
}

/// A category: its tile, its name, what it holds and, for a service type with something installed,
/// its state (as the sidebar showed it before).
private struct ComponentCategoryRow: View {
    let store: StackStore
    let component: Component
    let category: String

    var body: some View {
        let tech = component.tech(of: category)
        let members = component.members(of: category)
        HStack(spacing: 8) {
            TechLogo(tech: tech, size: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(tech.title).font(.uiBody).lineLimit(1)
                if !members.isEmpty {
                    Text(members.joined(separator: ", ")).font(.uiCaption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                }
            }
            Spacer(minLength: 4)
            // Only what is installed shows a state; the rest has nothing to report.
            if component == .services, store.categoryInstalled(category) {
                StatusRing(phase: store.categoryPhase(category), size: 10)
            }
        }
        .padding(.vertical, 2)
        .help(members.joined(separator: ", "))
    }
}
