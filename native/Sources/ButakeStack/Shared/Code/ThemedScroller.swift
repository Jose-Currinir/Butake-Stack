import AppKit
import SwiftUI

/// Scroll bars of the diff and the editor in the theme's colors. A theme that paints its own
/// backgrounds gets a knob tinted with the accent and no gray track; with the system backgrounds the
/// standard scroller is drawn untouched. The AppKit views of the code editor and of the Git pieces use it.
final class ThemedScroller: NSScroller {
    override class var isCompatibleWithOverlayScrollers: Bool { self == ThemedScroller.self }
    private var themed: Bool { Brand.customBackgrounds }
    private var vertical: Bool { bounds.height >= bounds.width }

    override func drawKnob() {
        guard themed else { super.drawKnob(); return }
        let knob = rect(for: .knob).insetBy(dx: vertical ? 3 : 2, dy: vertical ? 2 : 3)
        guard knob.width > 0, knob.height > 0 else { return }
        let radius = min(knob.width, knob.height) / 2
        NSColor(Brand.accent).withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: knob, xRadius: radius, yRadius: radius).fill()
    }

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {
        // No track with a theme of its own: the knob floats over the theme's background.
        guard themed else { super.drawKnobSlot(in: slotRect, highlight: flag); return }
    }

    /// Both scrollers of a scroll view, themed.
    static func install(on scroll: NSScrollView) {
        scroll.verticalScroller = ThemedScroller()
        scroll.horizontalScroller = ThemedScroller()
    }
}
