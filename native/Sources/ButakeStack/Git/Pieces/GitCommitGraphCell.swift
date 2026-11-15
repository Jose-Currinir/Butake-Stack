import SwiftUI

/// The graph of one history row: lanes from above, the commit's node and the lines to its parents.
/// Rows of the same height drawn one under another join into the whole graph.
struct GitCommitGraphCell: View {
    let row: GitGraphRow
    var selected = false
    /// Lanes of the whole graph (`GitCommitGraph.width`), so every row of a list is equally wide.
    var lanes: Int?
    /// Width of one lane; narrower when the graph has many (`laneWidth(lanes:)`).
    var laneWidth: CGFloat = Self.lane
    /// Width of one lane while the graph is narrow.
    nonisolated static let lane: CGFloat = 18
    /// Narrowest lane: the lines stay apart and the nodes don't touch.
    nonisolated static let narrowLane: CGFloat = 10
    /// Most room the graph takes before its lanes get narrower, so the message keeps the rest.
    nonisolated static let widest: CGFloat = 96

    /// Width of the column that holds a graph of `lanes` lanes of `lane` points.
    nonisolated static func width(lanes: Int, lane: CGFloat = lane) -> CGFloat { CGFloat(max(lanes, 1)) * lane + 12 }

    /// The lane that keeps a graph of `lanes` lanes within `widest` (never under `narrowLane`).
    nonisolated static func laneWidth(lanes: Int) -> CGFloat {
        let fitting = (widest - 12) / CGFloat(max(lanes, 1))
        return min(lane, max(narrowLane, fitting.rounded(.down)))
    }

    var body: some View {
        let colors = Brand.theme.graph.map(\.color)
        Canvas { context, size in
            let center = size.height / 2
            func x(_ lane: Int) -> CGFloat { CGFloat(lane) * laneWidth + laneWidth / 2 - 1 }
            func color(_ lane: Int) -> Color { colors.isEmpty ? .secondary : colors[lane % colors.count] }
            let style = StrokeStyle(lineWidth: 2, lineCap: .butt)
            for lane in row.incoming {
                var path = Path()
                path.move(to: CGPoint(x: x(lane), y: -0.5))
                path.addLine(to: CGPoint(x: x(lane), y: center))
                context.stroke(path, with: .color(color(lane).opacity(0.85)), style: style)
            }
            for segment in row.outgoing {
                var path = Path()
                path.move(to: CGPoint(x: x(segment.from), y: center))
                if segment.from == segment.to {
                    path.addLine(to: CGPoint(x: x(segment.to), y: size.height + 0.5))
                } else {
                    path.addCurve(to: CGPoint(x: x(segment.to), y: size.height + 0.5),
                                  control1: CGPoint(x: x(segment.from), y: size.height * 0.85), control2: CGPoint(x: x(segment.to), y: size.height * 0.7))
                }
                context.stroke(path, with: .color(color(segment.to).opacity(0.85)), style: style)
            }
            let radius: CGFloat = (selected ? 5.5 : 4) * min(1, laneWidth / Self.lane + 0.15)
            let node = CGRect(x: x(row.column) - radius, y: center - radius, width: radius * 2, height: radius * 2)
            if selected { context.fill(Path(ellipseIn: node.insetBy(dx: -4, dy: -4)), with: .color(color(row.column).opacity(0.25))) }
            context.fill(Path(ellipseIn: node), with: .color(color(row.column)))
            if selected { context.stroke(Path(ellipseIn: node.insetBy(dx: 1.6, dy: 1.6)), with: .color(.white.opacity(0.9)), lineWidth: 1.2) }
        }
        .frame(width: Self.width(lanes: lanes ?? row.laneCount, lane: laneWidth))
        .accessibilityHidden(true)
    }
}
