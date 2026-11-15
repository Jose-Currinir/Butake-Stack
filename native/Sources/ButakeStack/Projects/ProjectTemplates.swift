import Foundation

struct CreatedProject: Decodable, Sendable {
    /// The project; nil only for a Rust command-line tool (Swift and React Native come without a server).
    var project: Project?
    var path: String
    var notes: [String]
    var seconds: TimeInterval = 0
    var name: String { project?.name ?? URL(fileURLWithPath: path).lastPathComponent }
    enum CodingKeys: String, CodingKey { case project, path, notes }
}

// MARK: Catalog

struct TemplateOption: Identifiable, Hashable {
    let id: String
    let title: String
    let detail: String
    var symbol: String? = nil
    var logo: String? = nil
}

/// Kinds of project the assistant creates, grouped as the sidebar shows them.
struct ProjectKindInfo: Identifiable {
    let id: String
    let logo: String
    let group: String
    let generator: String
    var needsPhp = false
    var needsNode = false
    var proxied = false
    var wizard = false
    /// A toolchain of the user's (`devTools` id): uv, rustup or Apple's command line tools.
    var needsTool: String? = nil
    /// Creates a project that isn't a site (an app, a library, a tool).
    var app = false

    /// Framework shown with its current version, and the generator's package.
    var framework: (name: String, package: String)? {
        switch id {
        case "laravel": ("Laravel", "laravel/framework")
        case "astro": ("Astro", "astro")
        case "emdash": ("EmDash", "emdash")
        case "next": ("Next.js", "next")
        case "vite": ("Vite", "vite")
        case "react-native": ("React", "react")
        default: nil
        }
    }
    var generatorPackage: String? {
        switch id {
        case "laravel": "laravel/laravel"
        case "astro", "emdash", "next", "vite": generator
        default: nil
        }
    }

    static let groups = ["web", "native", "crossplatform"]
    static let all: [ProjectKindInfo] = [
        ProjectKindInfo(id: "laravel", logo: "laravel", group: "web", generator: "laravel/laravel", needsPhp: true),
        ProjectKindInfo(id: "php", logo: "php", group: "web", generator: "index.php"),
        ProjectKindInfo(id: "astro", logo: "astro", group: "web", generator: "create-astro", needsNode: true, proxied: true),
        ProjectKindInfo(id: "emdash", logo: "emdash", group: "web", generator: "create-emdash", needsNode: true, proxied: true),
        ProjectKindInfo(id: "next", logo: "next", group: "web", generator: "create-next-app", needsNode: true, proxied: true),
        ProjectKindInfo(id: "vite", logo: "vite", group: "web", generator: "create-vite", needsNode: true, proxied: true),
        ProjectKindInfo(id: "node", logo: "node", group: "web", generator: "node:http", needsNode: true, proxied: true),
        ProjectKindInfo(id: "django", logo: "django", group: "web", generator: "django-admin", proxied: true),
        ProjectKindInfo(id: "fastapi", logo: "fastapi", group: "web", generator: "fastapi", proxied: true),
        ProjectKindInfo(id: "rust", logo: "rust", group: "native", generator: "cargo", proxied: true, needsTool: "rustup"),
        ProjectKindInfo(id: "swift", logo: "swift", group: "native", generator: "swift package", needsTool: "clt", app: true),
        ProjectKindInfo(id: "react-native", logo: "react-native", group: "crossplatform", generator: "create-expo-app", needsNode: true, app: true),
        ProjectKindInfo(id: "kmp", logo: "kmp", group: "crossplatform", generator: "kmp.jetbrains.com", proxied: true, wizard: true),
        ProjectKindInfo(id: "static", logo: "static", group: "web", generator: "index.html"),
    ]
    static func of(_ id: String) -> ProjectKindInfo { all.first { $0.id == id } ?? all[0] }

    static let kits: [TemplateOption] = [
        TemplateOption(id: "none", title: "Laravel", detail: L("new.kitDetail.none"), logo: "laravel"),
        TemplateOption(id: "react", title: "React", detail: L("new.kitDetail.react"), logo: "react"),
        TemplateOption(id: "vue", title: "Vue", detail: L("new.kitDetail.vue"), logo: "vue"),
        TemplateOption(id: "svelte", title: "Svelte", detail: L("new.kitDetail.svelte"), logo: "svelte"),
        TemplateOption(id: "livewire", title: "Livewire", detail: L("new.kitDetail.livewire"), logo: "livewire"),
    ]
    /// Generator templates the engine accepts, in its order (the first is the default).
    static let templates: [String: [TemplateOption]] = [
        "astro": ["minimal", "basics", "blog", "portfolio", "starlight"].map { option("astro", $0, symbols: ["minimal": "square.dashed", "basics": "square.grid.2x2", "blog": "text.book.closed", "portfolio": "photo.on.rectangle", "starlight": "books.vertical"]) },
        "emdash": ["blog", "starter", "marketing", "portfolio"].map { option("emdash", $0, symbols: ["blog": "text.book.closed", "starter": "sparkles", "marketing": "megaphone", "portfolio": "photo.on.rectangle"]) },
        "next": ["app", "api", "empty"].map { option("next", $0, symbols: ["app": "macwindow", "api": "point.3.connected.trianglepath.dotted", "empty": "square.dashed"]) },
        "rust": [
            TemplateOption(id: "web", title: L("new.template.rust.web"), detail: L("new.templateDetail.rust.web"), symbol: Symbols.network),
            TemplateOption(id: "cli", title: L("new.template.rust.cli"), detail: L("new.templateDetail.rust.cli"), symbol: Symbols.terminal),
        ],
        "swift": [
            TemplateOption(id: "executable", title: L("new.template.swift.executable"), detail: L("new.templateDetail.swift.executable"), symbol: "play.rectangle"),
            TemplateOption(id: "tool", title: L("new.template.swift.tool"), detail: L("new.templateDetail.swift.tool"), symbol: Symbols.terminal),
            TemplateOption(id: "library", title: L("new.template.swift.library"), detail: L("new.templateDetail.swift.library"), symbol: "books.vertical"),
        ],
        "react-native": [
            TemplateOption(id: "expo", title: "Expo", detail: L("new.templateDetail.rn.expo"), symbol: "hare"),
            TemplateOption(id: "blank", title: L("new.template.rn.blank"), detail: L("new.templateDetail.rn.blank"), symbol: "square.dashed"),
            TemplateOption(id: "tabs", title: L("new.template.rn.tabs"), detail: L("new.templateDetail.rn.tabs"), symbol: "rectangle.split.3x1"),
            TemplateOption(id: "cli", title: "React Native CLI", detail: L("new.templateDetail.rn.cli"), logo: "react-native"),
        ],
        "vite": [
            TemplateOption(id: "react-ts", title: "React", detail: L("new.template.vite.detail"), logo: "react"),
            TemplateOption(id: "vue-ts", title: "Vue", detail: L("new.template.vite.detail"), logo: "vue"),
            TemplateOption(id: "svelte-ts", title: "Svelte", detail: L("new.template.vite.detail"), logo: "svelte"),
            TemplateOption(id: "solid-ts", title: "Solid", detail: L("new.template.vite.detail"), symbol: "cube"),
            TemplateOption(id: "preact-ts", title: "Preact", detail: L("new.template.vite.detail"), symbol: "atom"),
            TemplateOption(id: "lit-ts", title: "Lit", detail: L("new.template.vite.detail"), symbol: "flame"),
            TemplateOption(id: "vanilla-ts", title: L("new.template.vite.vanilla-ts"), detail: L("new.template.vite.detail"), symbol: Symbols.code),
        ],
    ]
    private static func option(_ kind: String, _ id: String, symbols: [String: String]) -> TemplateOption {
        TemplateOption(id: id, title: L("new.template.\(kind).\(id)"), detail: L("new.templateDetail.\(kind).\(id)"), symbol: symbols[id])
    }
}
