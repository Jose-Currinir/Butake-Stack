import SwiftUI

/// Inicio, only while a project that is on needs something (P-42): «Necesita atención» with each
/// cause in a line and its fix (or the way to the project's page). A service that a project uses
/// and is off, a port two projects take, a command that cannot run.
struct HomeAttention: View {
    @Bindable var store: StackStore
    var body: some View {
        let entries = store.attentionOn
        VStack(alignment: .leading, spacing: 10) {
            SectionHeading(title: L("attention.title"))
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(entries.enumerated()), id: \.element.project.id) { index, entry in
                    if index > 0 { Divider().padding(.leading, 56) }
                    HomeAttentionRow(store: store, project: entry.project, items: entry.items)
                }
            }
            .workSurface(radius: 16)
        }
        .accessibilityIdentifier("home.attention")
    }
}

private struct HomeAttentionRow: View {
    @Bindable var store: StackStore
    let project: Project
    let items: [ProjectAttention]
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            TechLogo(tech: project.tech, size: 32).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(project.title).font(.uiHeadline)
                ForEach(items) { item in
                    Label { Text(store.attentionText(item)).frame(maxWidth: .infinity, alignment: .leading) } icon: {
                        Image(systemName: Symbols.warning).foregroundStyle(Brand.warning)
                    }
                    .font(.uiCallout).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                if let item = items.first(where: { $0.fix != nil }), let fix = item.fix {
                    Button { Task { await store.applyFix(item, of: project) } } label: {
                        Label(store.fixTitle(fix), systemImage: Symbols.start)
                    }
                    .buttonStyle(.bordered).disabled(store.busy != nil)
                    .accessibilityIdentifier("home.attention.fix.\(project.id)")
                }
                Button { store.openSite(project.id) } label: { Label(L("palette.openPage"), systemImage: Symbols.forward) }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("home.attention.open.\(project.id)")
            }
        }
        .padding(14)
    }
}
