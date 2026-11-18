import AppKit
import SwiftUI

/// The one place that animates (docs/estandar-ui.md): `withAnimation`, `.animation` and
/// `.transition` are never written elsewhere (`lint-ui.sh`, counter `raw-animation`). With
/// System Settings › Accessibility › Display › Reduce motion on, nothing moves: a change is
/// instant and a view that enters or leaves fades.
enum Motion {
    /// The Mac's Reduce motion setting, read now (for code that isn't a view).
    @MainActor static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || QAAccessibility.reduceMotion }

    /// `withAnimation`, without animation under Reduce motion.
    @MainActor @discardableResult
    static func run<Result>(_ animation: Animation = .snappy, _ body: () throws -> Result) rethrows -> Result {
        try withAnimation(reduced ? nil : animation, body)
    }
}

extension View {
    /// `.animation(_:value:)` that doesn't animate under Reduce motion.
    func animated<Value: Equatable>(_ animation: Animation = .snappy, value: Value) -> some View {
        modifier(MotionAnimation(animation: animation, value: value))
    }

    /// `.transition(_:)` that becomes a fade under Reduce motion.
    func transitioned(_ transition: AnyTransition) -> some View {
        modifier(MotionTransition(transition: transition))
    }
}

private struct MotionAnimation<Value: Equatable>: ViewModifier {
    let animation: Animation
    let value: Value
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(reduceMotion || QAAccessibility.reduceMotion ? nil : animation, value: value)
    }
}

private struct MotionTransition: ViewModifier {
    let transition: AnyTransition
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.transition(reduceMotion || QAAccessibility.reduceMotion ? .opacity : transition)
    }
}
