import AppKit
// Themes (Theme, ThemeStore) and the text size (TextScale, Font.ui…) shared with Butake Git.
@_exported import ButakeDesign
import SwiftUI

/// Butake palette, read from the active theme (same families as Butake Git: Butake, Drácula, custom).
@MainActor enum Brand {
    static var theme: Theme { ThemeStore.shared.theme }
    /// The Mac's accent (System Settings › Appearance) with the default theme; a theme that brings
    /// its own (Drácula, or an accent chosen in the custom theme) uses that one. Butake-Design's
    /// default palette carries a green accent: it is ignored here, the green is the brand's and the
    /// state "running / correct" (`success`), never a control's.
    static var accent: Color { customAccent ? theme.accent.color : .accentColor }
    static var customAccent: Bool {
        let store = ThemeStore.shared
        let base = store.family == .custom ? store.customBase : store.family
        return base != .butake || (store.family == .custom && store.overrides[store.variantKey]?[ThemeStore.Slot.accent.rawValue] != nil)
    }
    static var success: Color { theme.addition.color }
    static var danger: Color { theme.deletion.color }
    static var warning: Color { theme.warning.color }
    static var info: Color { theme.modified.color }
    static var special: Color { theme.renamed.color }
    // A state's color as text. `success`, `warning`, `danger` and `info` stay for icons, dots and edges
    // (3:1 is enough); a state that is written in words uses these, shaded just enough to read at
    // 4.5:1 on the state's own tint (Contrast.readable). Dark themes mostly read already: they come out equal or a little lighter.
    static var successText: Color { statusText(theme.addition) }
    static var warningText: Color { statusText(theme.warning) }
    static var dangerText: Color { statusText(theme.deletion) }
    static var infoText: Color { statusText(theme.modified) }
    /// The backgrounds a text of the theme sits on.
    static func grounds(for theme: Theme) -> [HexColor] { [backgroundColor(for: theme), surfaceColor(for: theme)] }
    static func statusText(_ color: HexColor, in theme: Theme = Brand.theme, fill: Double = Contrast.chipFill) -> Color {
        Contrast.readable(color, isDark: theme.isDark, over: grounds(for: theme), fill: fill).color
    }
    static var surface: Color { surface(for: theme) }
    /// The pages' background: nothing with a theme that uses the system's (the window's own shows),
    /// the theme's color with one that paints its own.
    static var background: Color { customBackgrounds ? background(for: theme) : .clear }
    static func color(for slot: ThemeStore.Slot) -> HexColor {
        switch slot {
        case .background: backgroundColor(for: theme)
        case .surface: surfaceColor(for: theme)
        default: ThemeStore.shared.color(for: slot)
        }
    }

    static func surface(for theme: Theme) -> Color { surfaceColor(for: theme).color }
    static func background(for theme: Theme) -> Color { backgroundColor(for: theme).color }

    static func surfaceColor(for theme: Theme) -> HexColor {
        theme.surface ?? (theme.isDark ? darkSurface : lightSurface)
    }

    static func backgroundColor(for theme: Theme) -> HexColor {
        theme.background ?? (theme.isDark ? darkBackground : lightBackground)
    }

    // Neutral, opaque surfaces give the sidebar and floating controls a consistent backdrop.
    private static let lightSurface = HexColor(0xFFFFFF)
    private static let lightBackground = HexColor(0xF5F5F7)
    private static let darkSurface = HexColor(0x28282B)
    private static let darkBackground = HexColor(0x1C1C1E)
    /// Whether the theme paints its own backgrounds (lists then hide the system background).
    static var customBackgrounds: Bool { theme.background != nil || theme.surface != nil }
    static var bar: AnyShapeStyle { customBackgrounds ? AnyShapeStyle(background) : AnyShapeStyle(.bar) }
    static var logo: NSImage? { Bundle.module.url(forResource: "ButakeLogo", withExtension: "png").flatMap(NSImage.init(contentsOf:)) }
}

extension View {
    /// Lists and forms show the theme's surface instead of the system background.
    @MainActor func themedScroll() -> some View { scrollContentBackground(Brand.customBackgrounds ? .hidden : .automatic) }
    /// Sheets and secondary windows take the theme's background and accent like the main window.
    @MainActor func themedSheet() -> some View {
        background { if Brand.customBackgrounds { Brand.background.ignoresSafeArea() } }.themedTint().scaledText()
    }
    /// Controls take the theme's accent only when it brings one; otherwise nothing is forced and
    /// they follow the Mac's.
    @MainActor @ViewBuilder func themedTint() -> some View {
        if Brand.customAccent { tint(Brand.accent) } else { self }
    }
    /// Text without an explicit font follows the size chosen with ⌘+ / ⌘−.
    @MainActor func scaledText() -> some View { font(TextScale.shared.factor == 1 ? nil : Font.uiBody) }
}

/// Floating controls follow system materials and the current accessibility settings.
private struct ChromeGlass: ViewModifier {
    let interactive: Bool
    let enabled: Bool
    private let shape = Capsule()
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        if !enabled {
            content
        } else if reduceTransparency {
            content
                .background(Brand.surface, in: shape)
                .separatorEdge(in: shape)
        } else if #available(macOS 26.0, *) {
            content.glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            content.background(.regularMaterial, in: shape)
        }
    }
}
extension View {
    func workSurface(radius: CGFloat = Radius.panel) -> some View {
        background(Brand.surface, in: RoundedRectangle(cornerRadius: radius))
            .separatorEdge(opacity: 0.65, in: RoundedRectangle(cornerRadius: radius))
    }

    func chromeGlass(interactive: Bool = false, enabled: Bool = true) -> some View {
        modifier(ChromeGlass(interactive: interactive, enabled: enabled))
    }
}

struct BrandMark: View {
    var size: CGFloat = 32
    var body: some View {
        Group { if let logo = Brand.logo { Image(nsImage: logo).resizable().scaledToFit().padding(size * 0.14) } }
            .frame(width: size, height: size)
            // The radius of TechLogo's tiles, so the mark sits in line with them.
            .background(Color.white.opacity(0.94), in: RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
            .accessibilityLabel(L("app.name"))
    }
}

/// The one tile of the app, like the icons of System Settings: a rounded square of solid color with
/// a white mark. Logos (TechLogo) and symbols (IconTile) are drawn by it at the same size and radius.
struct Tile<Mark: View>: View {
    let color: Color
    let size: CGFloat
    @ViewBuilder let mark: Mark
    @Environment(\.colorScheme) private var scheme
    /// A near-black tile (a terminal, an assistant's own black) on a dark window: its top is lighter
    /// and its edge stronger, so the tile stands out from the background instead of melting into it.
    private var blendsIn: Bool {
        guard scheme == .dark, let rgb = NSColor(color).usingColorSpace(.sRGB) else { return false }
        return 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent < 0.2
    }
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
        mark.foregroundStyle(.white)
            .padding(size * 0.2)
            .frame(width: size, height: size)
            .background(
                // Opaque: a gray tile must not fade into a gray sidebar.
                LinearGradient(colors: [color.mix(with: .white, by: blendsIn ? 0.24 : 0.12), color.mix(with: .black, by: blendsIn ? 0.05 : 0.18)],
                               startPoint: .top, endPoint: .bottom),
                in: shape
            )
            .overlay(shape.strokeBorder(.white.opacity(blendsIn ? 0.3 : 0.12)))
    }
}

/// A concept's symbol on its tile, in the concept's color (TileColor), or in a state's color when
/// the tile says a state (a problem, a check that passed).
struct IconTile: View {
    let symbol: String
    var color: Color?
    var size: CGFloat = 32
    var body: some View {
        // Sized by the tile, not by the text: a symbol that grew with the text would overflow it.
        Tile(color: color ?? TileColor.of(symbol), size: size) {
            Image(systemName: symbol).resizable().scaledToFit().fontWeight(.semibold)
        }
        .accessibilityHidden(true)
    }
}

extension ProcessPhase {
    @MainActor var color: Color {
        switch self {
        case .running: Brand.success
        case .starting, .stopping: Brand.warning
        case .crashed: Brand.danger
        case .stopped: .secondary
        }
    }
    var symbol: String {
        switch self {
        case .running: "circle.fill"
        case .starting, .stopping: "circle.dotted"
        case .crashed: Symbols.error
        case .stopped: "circle"
        }
    }
}
