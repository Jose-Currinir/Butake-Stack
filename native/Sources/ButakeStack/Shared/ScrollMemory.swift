import SwiftUI

/// Where each page was scrolled to, so Atrás and Adelante bring the reader back to the same height.
/// In memory only: a new launch starts at the top. The oldest entries go past `limit`.
@MainActor final class ScrollMemory {
    static let shared = ScrollMemory()
    static let limit = 50
    private var offsets: [String: CGFloat] = [:]
    private var order: [String] = []

    func offset(_ key: String) -> CGFloat? { offsets[key] }

    func set(_ key: String, _ value: CGFloat) {
        let value = max(value, 0)
        if offsets[key] == nil { order.append(key) } else if let at = order.firstIndex(of: key) { order.append(order.remove(at: at)) }
        offsets[key] = value
        while order.count > Self.limit { offsets[order.removeFirst()] = nil }
    }

    func forget(_ key: String) {
        offsets[key] = nil
        order.removeAll { $0 == key }
    }
}

extension View {
    /// Remembers the scroll height of the scroll view under `key` and restores it when the page
    /// comes back. `enabled: false` leaves the view as it is (a log that follows its end).
    func rememberScroll(_ key: String, enabled: Bool = true) -> some View {
        modifier(RememberScroll(key: key, enabled: enabled))
    }
}

private struct RememberScroll: ViewModifier {
    let key: String
    let enabled: Bool
    @State private var position = ScrollPosition()
    /// The height still to restore: it waits until the content is tall enough to reach it.
    @State private var target: CGFloat?

    struct Metrics: Equatable { var offset: CGFloat; var content: CGFloat; var container: CGFloat }

    func body(content: Content) -> some View {
        content
            .scrollPosition($position)
            .onScrollGeometryChange(for: Metrics.self) {
                Metrics(offset: $0.contentOffset.y, content: $0.contentSize.height, container: $0.containerSize.height)
            } action: { _, now in
                guard enabled else { return }
                if let goal = target {
                    if now.content - now.container >= goal { position.scrollTo(y: goal); target = nil }
                    return
                }
                ScrollMemory.shared.set(key, now.offset)
            }
            .task(id: key) {
                guard enabled, let saved = ScrollMemory.shared.offset(key), saved > 0 else { return }
                target = saved
                // Content that never grows tall enough must not block remembering new positions.
                try? await Task.sleep(for: .seconds(1.5))
                target = nil
            }
    }
}
