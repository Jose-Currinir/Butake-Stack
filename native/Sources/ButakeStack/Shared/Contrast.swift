import SwiftUI

/// WCAG 2.x contrast math and the text color of a state: the state's own color, darkened (light
/// themes) or lightened (dark themes) just enough to read at 4.5:1 on the tint it sits on. Icons and
/// borders keep the state's own color (3:1 is enough for them); text takes this one.
enum Contrast {
    /// Minimum for text and for non-text marks (WCAG 2.x, SC 1.4.3 and 1.4.11).
    static let text = 4.5
    static let nonText = 3.0
    /// Fill opacity of a tinted chip, and the one Increase Contrast uses.
    static let chipFill = Fill.tint
    static let strongFill = 0.22
    /// Margin over the minimum, so rounding never lands under it.
    private static let margin = 0.05

    /// Increase Contrast is on (the Mac's setting; in QA also forced by BUTAKE_QA_CONTRAST).
    static func increased(_ setting: ColorSchemeContrast) -> Bool { setting == .increased || QAAccessibility.increasedContrast }

    private typealias RGB = (r: Double, g: Double, b: Double)

    private static func rgb(_ hex: HexColor) -> RGB {
        (Double((hex.value >> 16) & 0xFF) / 255, Double((hex.value >> 8) & 0xFF) / 255, Double(hex.value & 0xFF) / 255)
    }

    private static func hex(_ rgb: RGB) -> HexColor {
        func byte(_ v: Double) -> UInt32 { UInt32((min(1, max(0, v)) * 255).rounded()) }
        return HexColor(byte(rgb.r) << 16 | byte(rgb.g) << 8 | byte(rgb.b))
    }

    private static func linear(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }

    /// Relative luminance (WCAG).
    static func luminance(_ color: HexColor) -> Double {
        let c = rgb(color)
        return 0.2126 * linear(c.r) + 0.7152 * linear(c.g) + 0.0722 * linear(c.b)
    }

    /// Contrast ratio between two opaque colors, 1 to 21.
    static func ratio(_ a: HexColor, _ b: HexColor) -> Double {
        let (la, lb) = (luminance(a), luminance(b))
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// `color` painted at `opacity` over `background`.
    static func composite(_ color: HexColor, opacity: Double, over background: HexColor) -> HexColor {
        let (c, b) = (rgb(color), rgb(background))
        return hex((c.r * opacity + b.r * (1 - opacity), c.g * opacity + b.g * (1 - opacity), c.b * opacity + b.b * (1 - opacity)))
    }

    /// `color` moved `amount` (0...1) toward black or white.
    static func shifted(_ color: HexColor, toward white: Bool, by amount: Double) -> HexColor {
        let c = rgb(color), t = white ? 1.0 : 0.0
        return hex((c.r + (t - c.r) * amount, c.g + (t - c.g) * amount, c.b + (t - c.b) * amount))
    }

    /// The color to write `color`'s text with, over any of `backgrounds` and the `color` tint at
    /// `fill` opacity: `color` itself when it already reads on all of them, else the closest shade
    /// that does.
    static func readable(_ color: HexColor, isDark: Bool, over backgrounds: [HexColor], fill: Double = chipFill) -> HexColor {
        let grounds = backgrounds.map { composite(color, opacity: fill, over: $0) }
        func reads(_ candidate: HexColor) -> Bool { grounds.allSatisfy { ratio(candidate, $0) >= text + margin } }
        if reads(color) { return color }
        for step in 1...50 {
            let candidate = shifted(color, toward: isDark, by: Double(step) / 50)
            if reads(candidate) { return candidate }
        }
        return isDark ? HexColor(0xFFFFFF) : HexColor(0x000000)
    }
}

extension HexColor {
    /// A resolved SwiftUI color (sRGB, alpha ignored: composite it first when it has some).
    init(resolved: Color.Resolved) {
        func byte(_ v: Float) -> UInt32 { UInt32((min(1, max(0, v)) * 255).rounded()) }
        self.init(byte(resolved.red) << 16 | byte(resolved.green) << 8 | byte(resolved.blue))
    }
}
