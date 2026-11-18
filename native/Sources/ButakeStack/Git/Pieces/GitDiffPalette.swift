import AppKit
import SwiftUI

/// Colors of the Git pieces for one theme. Green and red mean only added and removed lines; every
/// colored text (the +/− marks, the line counts, the kind of change) is darkened or lightened until it
/// reads with WCAG AA contrast (4.5:1) on the surface and on the tinted rows it sits on.
struct GitDiffPalette: @unchecked Sendable {
    let isDark: Bool
    let surface: NSColor
    let text: NSColor
    let addition: NSColor
    let deletion: NSColor
    let modified: NSColor
    let moved: NSColor
    let warning: NSColor
    /// Row tints of added and removed lines, and the stronger tint of the changed words in them.
    let additionRow: NSColor
    let deletionRow: NSColor
    let addedWord: NSColor
    let removedWord: NSColor
    let hunkRow: NSColor
    let metadataRow: NSColor
    let fileHeaderRow: NSColor

    static let minimumContrast = 4.5

    /// The palette of the active theme.
    @MainActor static var current: GitDiffPalette { GitDiffPalette(theme: Brand.theme) }

    @MainActor init(theme: Theme) {
        let surfaceHex = theme.surface ?? HexColor(Brand.surface(for: theme))
        isDark = theme.isDark
        surface = surfaceHex.ns
        text = theme.text?.ns ?? (theme.isDark ? NSColor(white: 0.93, alpha: 1) : NSColor(white: 0.1, alpha: 1))
        let addition = theme.addition.ns, deletion = theme.deletion.ns
        additionRow = addition.withAlphaComponent(theme.isDark ? 0.16 : 0.14)
        deletionRow = deletion.withAlphaComponent(theme.isDark ? 0.18 : 0.11)
        addedWord = addition.withAlphaComponent(theme.isDark ? 0.34 : 0.28)
        removedWord = deletion.withAlphaComponent(0.28)
        hunkRow = theme.modified.ns.withAlphaComponent(0.07)
        metadataRow = (theme.isDark ? NSColor.white : NSColor.black).withAlphaComponent(0.06)
        fileHeaderRow = (theme.isDark ? NSColor.white : NSColor.black).withAlphaComponent(theme.isDark ? 0.14 : 0.09)
        // Each mark is read on its own row's tint, the darkest place it can land.
        let surface = surfaceHex.ns
        self.addition = Self.legible(addition, on: Self.blend(additionRow, over: surface))
        self.deletion = Self.legible(deletion, on: Self.blend(deletionRow, over: surface))
        modified = Self.legible(theme.modified.ns, on: surface)
        moved = Self.legible(theme.renamed.ns, on: surface)
        warning = Self.legible(theme.warning.ns, on: surface)
    }

    // MARK: Contrast

    /// Relative luminance (WCAG 2.x) of an opaque sRGB color.
    static func luminance(_ color: NSColor) -> Double {
        guard let rgb = color.usingColorSpace(.sRGB) else { return 0 }
        func channel(_ value: CGFloat) -> Double {
            let v = Double(value)
            return v <= 0.040_45 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(rgb.redComponent) + 0.7152 * channel(rgb.greenComponent) + 0.0722 * channel(rgb.blueComponent)
    }

    /// Contrast ratio between two opaque colors, from 1 to 21.
    static func contrast(_ first: NSColor, _ second: NSColor) -> Double {
        let a = luminance(first), b = luminance(second)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// A translucent tint painted over an opaque background.
    static func blend(_ tint: NSColor, over background: NSColor) -> NSColor {
        guard let top = tint.usingColorSpace(.sRGB), let bottom = background.usingColorSpace(.sRGB) else { return background }
        let alpha = top.alphaComponent
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a * alpha + b * (1 - alpha) }
        return NSColor(srgbRed: mix(top.redComponent, bottom.redComponent), green: mix(top.greenComponent, bottom.greenComponent),
                       blue: mix(top.blueComponent, bottom.blueComponent), alpha: 1)
    }

    /// The color itself when it already reads on `background`; otherwise mixed toward black (light
    /// backgrounds) or white (dark ones) in small steps until it does.
    static func legible(_ color: NSColor, on background: NSColor, minimum: Double = minimumContrast) -> NSColor {
        guard let base = color.usingColorSpace(.sRGB) else { return color }
        let target: NSColor = luminance(background) > 0.18 ? .black : .white
        var step: CGFloat = 0
        var candidate = base
        while contrast(candidate, background) < minimum && step < 1 {
            step += 0.04
            candidate = base.blended(withFraction: min(step, 1), of: target)?.usingColorSpace(.sRGB) ?? base
        }
        return candidate
    }
}
