import SwiftUI

/// Ring that fills with the state. It only animates when the state changes: a menu bar app must
/// not keep the GPU busy with endless pulses.
struct StatusRing: View {
    let phase: ProcessPhase
    var size: CGFloat = 12
    var body: some View {
        ZStack {
            Circle().stroke(phase.color.opacity(0.25), lineWidth: size * 0.18)
            Circle().trim(from: 0, to: phase == .running ? 1 : (phase == .starting ? 0.6 : 0.0001))
                .stroke(phase.color, style: StrokeStyle(lineWidth: size * 0.18, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if phase == .running {
                Circle().fill(phase.color).frame(width: size * 0.4, height: size * 0.4).transitioned(.scale.combined(with: .opacity))
            }
        }
        .frame(width: size, height: size)
        .animated(.snappy, value: phase)
        .accessibilityLabel(L("state.\(phase.rawValue)"))
    }
}
