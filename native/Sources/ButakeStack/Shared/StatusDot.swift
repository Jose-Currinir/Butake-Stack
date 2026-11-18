import SwiftUI

/// A state as a small dot. Color alone never says it (docs/estandar-ui.md): the dot always carries
/// the state as its accessibility label, and with System Settings › Accessibility › Display ›
/// Differentiate without color on it becomes a symbol whose shape says the state too.
struct StatusDot: View {
    let color: Color
    /// The shape that stands for the state when color isn't enough.
    let symbol: String
    let label: String
    var size: CGFloat = 6
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiate

    var body: some View {
        Group {
            if differentiate || QAAccessibility.differentiateWithoutColor {
                Image(systemName: symbol).resizable().scaledToFit().foregroundStyle(color).frame(width: size + 4, height: size + 4)
            } else {
                Circle().fill(color).frame(width: size, height: size)
            }
        }
        .help(label)
        .accessibilityLabel(label)
    }
}

extension ProcessPhase {
    /// The dot's shape when color isn't enough: each phase differs in shape, not only in hue.
    var markSymbol: String {
        switch self {
        case .running: Symbols.success
        case .starting, .stopping: "circle.dotted"
        case .crashed: Symbols.error
        case .stopped: "circle"
        }
    }
}
