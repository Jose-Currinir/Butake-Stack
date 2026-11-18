import SwiftUI

/// The services in use, as compact chips that wrap onto a second line only when the row is full:
/// dot, name, version · port. A chip opens its page; its menu starts or stops it.
struct HomeServices: View {
    @Bindable var store: StackStore
    let names: [String]
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // No count of what runs here: the status bar says it once for the whole window.
            Text(L("sidebar.services")).font(.uiHeadline).foregroundStyle(.secondary)
            ChipFlow(spacing: 8) {
                ForEach(names, id: \.self) { HomeServiceChip(store: store, name: $0) }
            }
        }
        .accessibilityIdentifier("home.services")
    }
}

private struct HomeServiceChip: View {
    @Bindable var store: StackStore
    let name: String
    func open() { store.route = .service(Route.category(of: name)) }

    var body: some View {
        let tech = Tech.of(name)
        let enabled = store.engineEnabled(name)
        let phase = enabled ? store.phase("stack.\(name)") : .stopped
        let state = !enabled ? L("site.off") : phase == .running ? nil : phase == .crashed ? L("home.state.crashed") : L("state.\(phase.rawValue)")
        let detail = [state, store.engineVersion(name), store.enginePort(name).map(String.init)].compactMap { $0 }.joined(separator: " · ")
        Button(action: open) {
            HStack(spacing: 7) {
                StatusDot(color: phase.color, symbol: phase.markSymbol, label: state ?? L("state.running"))
                Text(tech.title).font(.uiCallout.weight(.medium)).lineLimit(1)
                Text(detail).font(.uiCaption).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .workSurface(radius: Radius.row)
        }
        .buttonStyle(HighlightButtonStyle(radius: Radius.row))
        .help(tech.title)
        .accessibilityIdentifier("home.service.\(name)")
        .contextMenu {
            Button { Task { await store.setEngine(name, enabled: !enabled) } } label: {
                Label(enabled ? L("palette.stop") : L("palette.start"), systemImage: enabled ? Symbols.stop : Symbols.start)
            }
            .accessibilityIdentifier("home.service.menu.toggle.\(name)")
            Button { open() } label: {
                Label(L("palette.openPage"), systemImage: Symbols.forward)
            }
            .accessibilityIdentifier("home.service.menu.open.\(name)")
        }
    }
}

/// Left to right, wrapping to a new line when the next chip does not fit.
private struct ChipFlow: Layout {
    var spacing: CGFloat
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let laid = arrange(width: bounds.width, subviews: subviews)
        for (subview, point) in zip(subviews, laid.points) {
            subview.place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified)
        }
    }
    private func arrange(width: CGFloat, subviews: Subviews) -> (points: [CGPoint], size: CGSize) {
        var points: [CGPoint] = [], x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return (points, CGSize(width: widest, height: y + rowHeight))
    }
}
