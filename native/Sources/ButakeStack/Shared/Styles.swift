import SwiftUI

/// Clickable row or card: a soft highlight on hover and when pressed, no movement and no shadow,
/// and a ring in the accent while the keyboard has it. Rows use the default radius; cards pass theirs.
struct HighlightButtonStyle: ButtonStyle {
    var radius: CGFloat = 8

    func makeBody(configuration: Configuration) -> some View {
        HighlightBody(configuration: configuration, radius: radius)
    }

    private struct HighlightBody: View {
        let configuration: Configuration
        let radius: CGFloat
        @State private var hovering = false
        @Environment(\.isFocused) private var focused
        @Environment(\.colorSchemeContrast) private var contrast

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
            // Increase Contrast: the highlight is clearly stronger.
            let more = Contrast.increased(contrast)
            configuration.label
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(shape)
                .overlay {
                    if hovering || configuration.isPressed {
                        shape.fill(Color.primary.opacity(configuration.isPressed ? (more ? 0.16 : 0.08) : (more ? 0.1 : 0.04)))
                            .allowsHitTesting(false)
                    }
                }
                // The keyboard's place: a 2 pt accent ring on the row's own shape.
                .overlay {
                    if focused { shape.strokeBorder(Color.accentColor, lineWidth: 2).allowsHitTesting(false) }
                }
                .onHover { hovering = $0 }
        }
    }
}

/// A tinted fill and, optionally, an edge in the same tint. With Increase Contrast the fill is
/// stronger and the edge is always there, in the full tint.
private struct TintedFill<S: InsettableShape>: ViewModifier {
    let tint: Color
    let fill: Double
    let edge: Double?
    let shape: S
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let more = Contrast.increased(contrast)
        content
            .background(tint.opacity(more ? Contrast.strongFill : fill), in: shape)
            .overlay {
                if more || edge != nil {
                    shape.strokeBorder(tint.opacity(more ? 1 : edge ?? 0)).allowsHitTesting(false)
                }
            }
    }
}

/// The hairline of a surface: the system separator, which with Increase Contrast is replaced by
/// the text color at half strength.
private struct SeparatorEdge<S: InsettableShape>: ViewModifier {
    let opacity: Double
    let shape: S
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content.overlay {
            shape.strokeBorder(Contrast.increased(contrast) ? Color.primary.opacity(0.5) : Color(nsColor: .separatorColor).opacity(opacity))
                .allowsHitTesting(false)
        }
    }
}

extension View {
    /// A tint's fill (`fill` opacity) and edge (`edge` opacity, none when nil) in `shape`, stronger
    /// with Increase Contrast.
    func tintedFill<S: InsettableShape>(_ tint: Color, fill: Double, edge: Double? = nil, in shape: S) -> some View {
        modifier(TintedFill(tint: tint, fill: fill, edge: edge, shape: shape))
    }

    /// The hairline around a surface, stronger with Increase Contrast.
    func separatorEdge<S: InsettableShape>(opacity: Double = 1, in shape: S) -> some View {
        modifier(SeparatorEdge(opacity: opacity, shape: shape))
    }
}
