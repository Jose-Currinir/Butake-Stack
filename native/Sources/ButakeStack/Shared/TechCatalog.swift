import AppKit
import SwiftUI

/// Identity of a technology: its logo (Material Icon Theme, MIT, in Logos/) or, when the set has
/// none, an SF Symbol on the brand color the ecosystem is known for.
struct Tech: Hashable {
    let id: String
    let title: String
    var svg: String?
    /// Simple Icons (CC0) mark, drawn in the brand color.
    var simple: String?
    var symbol: String = "cube.fill"
    var color: UInt32 = 0x8E8E93

    static func of(_ id: String) -> Tech {
        switch id {
        case "laravel": Tech(id: id, title: "Laravel", simple: "laravel", color: 0xFF2D20)
        case "php": Tech(id: id, title: "PHP", simple: "php", color: 0x777BB4)
        case "node": Tech(id: id, title: "Node.js", simple: "nodedotjs", color: 0x5FA04E)
        case "static": Tech(id: id, title: L("kind.static"), svg: "html")
        case "unserved": Tech(id: id, title: L("kind.unserved"), symbol: Symbols.package, color: 0x8E8E93)
        case "web", "caddy": Tech(id: "web", title: L("panel.web"), simple: "caddy", color: 0x1F88C0)
        case "database": Tech(id: id, title: L("category.database"), svg: "database")
        case "vault": Tech(id: id, title: L("plugin.vault.title"), symbol: Symbols.vault, color: 0x5856D6)
        case "database-client": Tech(id: id, title: L("plugin.database-client.title"), symbol: "tablecells.fill", color: 0x4479A1)
        case "ssh-terminal": Tech(id: id, title: L("plugin.ssh-terminal.title"), symbol: "apple.terminal.fill", color: 0x3A3F4B)
        case "cache": Tech(id: id, title: L("category.cache"), symbol: "bolt.horizontal.fill", color: 0xE8A33D)
        case "broadcasting": Tech(id: id, title: L("category.broadcasting"), symbol: "dot.radiowaves.left.and.right", color: 0x9B5DE5)
        case "search": Tech(id: id, title: L("category.search"), symbol: Symbols.search, color: 0xFF5CAA)
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
        case "codex": Tech(id: id, title: "Codex", symbol: Symbols.ai, color: 0x1F1F1F)
        case "chatgpt": Tech(id: id, title: "ChatGPT", symbol: "bubble.left.and.bubble.right.fill", color: 0x1F1F1F)
        case "claude-code", "claude-desktop": Tech(id: id, title: id == "claude-code" ? "Claude Code" : "Claude Desktop", simple: "claude", color: 0xD97757)
        // Each provider in its own color and mark, never the generic cloud: Google Cloud's logo
        // (Material Icon Theme, MIT, in Logos/); AWS, its servers in its orange.
        case "aws": Tech(id: id, title: "AWS CLI", symbol: Symbols.server, color: 0xFF9900)
        case "gcp": Tech(id: id, title: "Google Cloud", svg: "gcp", color: 0x4285F4)
        case "ai": Tech(id: id, title: L("profile.ai"), symbol: Symbols.ai, color: 0x7D5BED)
        case "cocoapods": Tech(id: id, title: "CocoaPods", symbol: "shippingbox.fill", color: 0xEE3322)
        case "watchman": Tech(id: id, title: "Watchman", symbol: "eye.fill", color: 0x4267B2)
        case "kmp": Tech(id: id, title: "Kotlin Multiplatform", simple: "kotlin", color: 0x7F52FF)
        case "java", "jdk": Tech(id: "java", title: L("language.java.title"), simple: "openjdk", color: 0xE76F00)
        case "vue": Tech(id: id, title: "Vue", svg: "vue", color: 0x42B883)
        case "svelte": Tech(id: id, title: "Svelte", svg: "svelte", color: 0xFF3E00)
        case "livewire": Tech(id: id, title: "Livewire", symbol: "bolt.square.fill", color: 0xFB70A9)
        case "git": Tech(id: id, title: "Git", symbol: Symbols.git, color: 0xF05032)
        case "dns": Tech(id: id, title: "DNS", symbol: "point.3.connected.trianglepath.dotted", color: 0x5AA7FF)
        case "mail": Tech(id: id, title: L("mail.title"), symbol: "envelope.fill", color: 0x2F80ED)
        case "dumps": Tech(id: id, title: L("dumps.title"), symbol: "ladybug.fill", color: 0x9B51E0)
        case "logs": Tech(id: id, title: L("logs.title"), symbol: Symbols.logs, color: 0x6E6E73)
        default: Tech(id: id, title: id.capitalized, symbol: "shippingbox.fill")
        }
    }
    /// Long names with a short form for tight places (the cards of Inicio).
    static let shortForms: Set<String> = ["kmp"]
    var shortTitle: String { Self.shortForms.contains(id) ? L("tech.short.\(id)") : title }
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
                Tile(color: tech.brand, size: size) { Image(nsImage: mark).renderingMode(.template).resizable().scaledToFit() }
            } else if let image = tech.image {
                Image(nsImage: image).resizable().scaledToFit().padding(size * 0.17)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: size * 0.26, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
            } else {
                // Sized by the tile like the logos above, so it keeps their frame at any text size.
                Tile(color: tech.brand, size: size) { Image(systemName: tech.symbol).resizable().scaledToFit().fontWeight(.semibold) }
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(tech.title)
    }
}

extension Project {
    /// A project without a server shows what it is built with (Swift, Rust, Android…) when the
    /// engine knows it.
    var tech: Tech { Tech.of(isServed ? kind : technology ?? kind) }
}
