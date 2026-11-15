import SwiftUI

/// Clickable row or card: a soft highlight on hover and when pressed, no movement and no shadow,
/// reachable with the keyboard like any button. Rows use the default radius; cards pass theirs.
struct HighlightButtonStyle: ButtonStyle {
    var radius: CGFloat = 8

    func makeBody(configuration: Configuration) -> some View {
        HighlightBody(configuration: configuration, radius: radius)
    }

    private struct HighlightBody: View {
        let configuration: Configuration
        let radius: CGFloat
        @State private var hovering = false

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
            configuration.label
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(shape)
                .overlay {
                    if hovering || configuration.isPressed {
                        shape.fill(Color.primary.opacity(configuration.isPressed ? 0.08 : 0.04)).allowsHitTesting(false)
                    }
                }
                .onHover { hovering = $0 }
        }
    }
}
