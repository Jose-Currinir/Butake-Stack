import AppKit
// Themes (Theme, ThemeStore) and the text size (TextScale, Font.ui…) shared with Butake Git.
@_exported import ButakeDesign
import SwiftUI

/// Butake palette, read from the active theme (same families as Butake Git: Butake, Drácula, custom).
@MainActor enum Brand {
    static var theme: Theme { ThemeStore.shared.theme }
    static var accent: Color { theme.accent.color }
    static var success: Color { theme.addition.color }
    static var danger: Color { theme.deletion.color }
    static var warning: Color { theme.warning.color }
    static var info: Color { theme.modified.color }
    static var special: Color { theme.renamed.color }
    static var surface: Color { theme.surface?.color ?? Color(nsColor: .textBackgroundColor) }
    static var background: Color { theme.background?.color ?? Color(nsColor: .windowBackgroundColor) }
    /// Whether the theme paints its own backgrounds (lists then hide the system background).
    static var customBackgrounds: Bool { theme.surface != nil }
    static var bar: AnyShapeStyle { customBackgrounds ? AnyShapeStyle(background) : AnyShapeStyle(.bar) }
    static var logo: NSImage? { Bundle.module.url(forResource: "ButakeLogo", withExtension: "png").flatMap(NSImage.init(contentsOf:)) }
}

extension View {
    /// Lists and forms show the theme's surface instead of the system background.
    @MainActor func themedScroll() -> some View { scrollContentBackground(Brand.customBackgrounds ? .hidden : .automatic) }
    /// Sheets and secondary windows take the theme's background and accent like the main window.
    @MainActor func themedSheet() -> some View {
        background { if Brand.customBackgrounds { Brand.background.ignoresSafeArea() } }.tint(Brand.accent).scaledText()
    }
    /// Text without an explicit font follows the size chosen with ⌘+ / ⌘−.
    @MainActor func scaledText() -> some View { font(TextScale.shared.factor == 1 ? nil : Font.ui(size: 13)) }
}

struct BrandMark: View {
    var size: CGFloat = 32
    var body: some View {
        Group { if let logo = Brand.logo { Image(nsImage: logo).resizable().scaledToFit().padding(size * 0.14) } }
            .frame(width: size, height: size)
            .background(Color.white.opacity(0.94), in: RoundedRectangle(cornerRadius: size * 0.24))
            .accessibilityLabel("Butake")
    }
}

/// SF Symbol on a soft tinted tile, the icon style used across Butake apps.
struct IconTile: View {
    let symbol: String
    var tint: Color = Brand.accent
    var size: CGFloat = 32
    var body: some View {
        Image(systemName: symbol)
            .font(.ui(size: size * 0.46, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.13), in: RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// Initial of a site on a tinted tile; the tint is stable per name so each site is recognizable.
struct SiteAvatar: View {
    let name: String
    var size: CGFloat = 34
    var tint: Color {
        let palette = Brand.theme.graph.map(\.color)
        let index = name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF } % max(palette.count, 1)
        return palette.isEmpty ? Brand.accent : palette[index]
    }
    var body: some View {
        Text(String(name.prefix(1)).uppercased())
            .font(.ui(size: size * 0.46, weight: .bold, design: .rounded))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(
                LinearGradient(colors: [tint.opacity(0.24), tint.opacity(0.10)], startPoint: .topLeading, endPoint: .bottomTrailing),
                in: RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            )
            .overlay(RoundedRectangle(cornerRadius: size * 0.26, style: .continuous).strokeBorder(tint.opacity(0.22)))
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
        case .crashed: "exclamationmark.circle.fill"
        case .stopped: "circle"
        }
    }
}

struct StateDot: View {
    let phase: ProcessPhase
    var body: some View {
        Circle().fill(phase.color).frame(width: 8, height: 8)
            .shadow(color: phase == .running ? phase.color.opacity(0.6) : .clear, radius: 3)
            .accessibilityLabel(L("state.\(phase.rawValue)"))
    }
}

/// Small colored label: state words, versions, counts.
struct Chip: View {
    let text: String
    var symbol: String?
    var tint: Color = .secondary
    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).font(.ui(size: 9, weight: .bold)) }
            Text(text).font(.ui(size: 10.5, weight: .semibold))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(tint.opacity(0.12), in: Capsule())
    }
}

/// Identity of a technology: its logo (Material Icon Theme, MIT, in Logos/) or, when the set has
/// none, an SF Symbol on the brand color the ecosystem is known for.
struct Tech: Hashable {
    let id: String
    let title: String
    var svg: String?
    /// Simple Icons (CC0) mark, drawn in the brand color.
    var simple: String?
    var symbol: String = "cube.fill"
    var color: UInt32 = 0x19D79F

    static func of(_ id: String) -> Tech {
        switch id {
        case "laravel": Tech(id: id, title: "Laravel", simple: "laravel", color: 0xFF2D20)
        case "php": Tech(id: id, title: "PHP", simple: "php", color: 0x777BB4)
        case "node": Tech(id: id, title: "Node.js", simple: "nodedotjs", color: 0x5FA04E)
        case "static": Tech(id: id, title: L("kind.static"), svg: "html")
        case "web", "caddy": Tech(id: "web", title: L("panel.web"), simple: "caddy", color: 0x1F88C0)
        case "database": Tech(id: id, title: L("category.database"), svg: "database")
        case "cache": Tech(id: id, title: L("category.cache"), symbol: "bolt.horizontal.fill", color: 0xE8A33D)
        case "broadcasting": Tech(id: id, title: L("category.broadcasting"), symbol: "dot.radiowaves.left.and.right", color: 0x9B5DE5)
        case "search": Tech(id: id, title: L("category.search"), symbol: "magnifyingglass", color: 0xFF5CAA)
        case "storage": Tech(id: id, title: L("category.storage"), symbol: "externaldrive.fill", color: 0xC72E49)
        case "mysql": Tech(id: id, title: "MySQL", simple: "mysql", color: 0x4479A1)
        case "mariadb": Tech(id: id, title: "MariaDB", simple: "mariadb", color: 0x003545)
        case "postgres": Tech(id: id, title: "PostgreSQL", simple: "postgresql", color: 0x4169E1)
        case "mongodb": Tech(id: id, title: "MongoDB", simple: "mongodb", color: 0x47A248)
        case "valkey": Tech(id: id, title: "Valkey", symbol: "key.fill", color: 0x6983FF)
        case "meilisearch": Tech(id: id, title: "Meilisearch", simple: "meilisearch", color: 0xFF5CAA)
        case "typesense": Tech(id: id, title: "Typesense", symbol: "text.magnifyingglass", color: 0xD12D88)
        case "minio": Tech(id: id, title: "MinIO", symbol: "externaldrive.fill", color: 0xC72E49)
        case "rustfs": Tech(id: id, title: "RustFS", symbol: "externaldrive.badge.checkmark", color: 0xB7410E)
        case "reverb": Tech(id: id, title: "Reverb", symbol: "dot.radiowaves.left.and.right", color: 0x9B5DE5)
        case "redis": Tech(id: id, title: "Redis", simple: "redis", color: 0xFF4438)
        case "react": Tech(id: id, title: "React", svg: "react", color: 0x61DAFB)
        case "astro": Tech(id: id, title: "Astro", simple: "astro", color: 0xBC52EE)
        case "emdash": Tech(id: id, title: "EmDash", simple: "cloudflare", color: 0xF38020)
        case "next": Tech(id: id, title: "Next.js", simple: "nextdotjs", color: 0x111111)
        case "vite": Tech(id: id, title: "Vite", svg: "vite", color: 0x646CFF)
        case "django": Tech(id: id, title: "Django", simple: "django", color: 0x0C4B33)
        case "fastapi": Tech(id: id, title: "FastAPI", simple: "fastapi", color: 0x009688)
        case "python": Tech(id: id, title: "Python", simple: "python", color: 0x3776AB)
        case "uv": Tech(id: id, title: "uv", simple: "uv", color: 0xDE5FE9)
        case "rust", "rustup": Tech(id: "rust", title: "Rust", simple: "rust", color: 0xCE422B)
        case "swift": Tech(id: id, title: "Swift", simple: "swift", color: 0xF05138)
        case "xcode", "clt": Tech(id: id, title: id == "xcode" ? "Xcode" : L("tools.clt"), simple: "apple", color: 0x1C1C1E)
        case "android", "android-sdk", "android-studio", "adb": Tech(id: id, title: "Android", simple: "android", color: 0x34A853)
        case "react-native": Tech(id: id, title: "React Native", svg: "react", color: 0x61DAFB)
        case "github", "gh": Tech(id: "github", title: "GitHub", simple: "github", color: 0x181717)
        case "cloudflared", "wrangler": Tech(id: id, title: id == "wrangler" ? "Wrangler" : "cloudflared", simple: "cloudflare", color: 0xF38020)
        case "cocoapods": Tech(id: id, title: "CocoaPods", symbol: "shippingbox.fill", color: 0xEE3322)
        case "watchman": Tech(id: id, title: "Watchman", symbol: "eye.fill", color: 0x4267B2)
        case "kmp": Tech(id: id, title: "Kotlin Multiplatform", simple: "kotlin", color: 0x7F52FF)
        case "java", "jdk": Tech(id: "java", title: "Java y Kotlin", simple: "openjdk", color: 0xE76F00)
        case "vue": Tech(id: id, title: "Vue", svg: "vue", color: 0x42B883)
        case "svelte": Tech(id: id, title: "Svelte", svg: "svelte", color: 0xFF3E00)
        case "livewire": Tech(id: id, title: "Livewire", symbol: "bolt.fill", color: 0xFB70A9)
        case "git": Tech(id: id, title: "Git", symbol: "arrow.triangle.branch", color: 0xF05032)
        case "dns": Tech(id: id, title: "DNS", symbol: "point.3.connected.trianglepath.dotted", color: 0x5AA7FF)
        default: Tech(id: id, title: id.capitalized, symbol: "shippingbox.fill")
        }
    }
    @MainActor static var cache: [String: NSImage] = [:]
    @MainActor var simpleImage: NSImage? {
        guard let simple else { return nil }
        let key = "si-" + simple
        if let cached = Tech.cache[key] { return cached }
        let url = Bundle.module.url(forResource: key, withExtension: "svg", subdirectory: "Logos")
        let image = url.flatMap(NSImage.init(contentsOf:))
        image?.isTemplate = true
        Tech.cache[key] = image
        return image
    }
    @MainActor var image: NSImage? {
        guard let svg else { return nil }
        if let cached = Tech.cache[svg] { return cached }
        let url = Bundle.module.url(forResource: svg, withExtension: "svg", subdirectory: "Logos")
        let image = url.flatMap(NSImage.init(contentsOf:))
        Tech.cache[svg] = image
        return image
    }
    var brand: Color {
        Color(red: Double((color >> 16) & 0xFF) / 255, green: Double((color >> 8) & 0xFF) / 255, blue: Double(color & 0xFF) / 255)
    }
}

/// Logo tile used for sites, services and languages.
struct TechLogo: View {
    let tech: Tech
    var size: CGFloat = 32
    var body: some View {
        Group {
            if let mark = tech.simpleImage {
                // App-icon style: white mark on the brand color, legible in light and dark.
                Image(nsImage: mark).renderingMode(.template).resizable().scaledToFit()
                    .foregroundStyle(.white).padding(size * 0.2)
                    .background(
                        LinearGradient(colors: [tech.brand.mix(with: .white, by: 0.12), tech.brand.mix(with: .black, by: 0.18)], startPoint: .top, endPoint: .bottom),
                        in: RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                    )
                    .overlay(RoundedRectangle(cornerRadius: size * 0.26, style: .continuous).strokeBorder(.white.opacity(0.12)))
            } else if let image = tech.image {
                Image(nsImage: image).resizable().scaledToFit().padding(size * 0.17)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: size * 0.26, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
            } else {
                Image(systemName: tech.symbol).font(.ui(size: size * 0.46, weight: .semibold)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(
                        LinearGradient(colors: [tech.brand, tech.brand.opacity(0.78)], startPoint: .top, endPoint: .bottom),
                        in: RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                    )
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(tech.title)
    }
}

extension Project {
    var tech: Tech { Tech.of(kind) }
}
