import Foundation

/// The subfolder of the projects folder a new project goes to: `App`, `Service` or `Web`. Stack
/// suggests one by the kind of project; the user can always choose another.
enum ProjectPlace: String, CaseIterable, Identifiable, Sendable {
    case app, service, web

    var id: String { rawValue }
    /// The folder on disk, the same in every language.
    var folder: String {
        switch self {
        case .app: "App"
        case .service: "Service"
        case .web: "Web"
        }
    }
    var title: String { L("place.\(rawValue)") }
    var symbol: String {
        switch self {
        case .app: Symbols.placeApp
        case .service: Symbols.placeService
        case .web: Symbols.placeWeb
        }
    }

    /// Where a project of `kind` (those of «Nuevo proyecto» and those the engine detects) goes:
    /// sites and web frameworks to Web; native and multiplatform apps to App; services and APIs
    /// without a web interface of their own, libraries and command line tools to Service. Nil
    /// for a kind nobody classified yet (a test fails while one exists).
    static func suggested(kind: String, template: String = "") -> ProjectPlace? {
        switch kind {
        case "laravel", "php", "astro", "emdash", "next", "vite", "static", "django", "proxy": .web
        // A Swift package that is a command or a library is not an app.
        case "swift": ["tool", "library"].contains(template) ? .service : .app
        case "react-native", "kmp": .app
        // A project without a server (P-42): a library, a tool or a template.
        case "rust", "node", "fastapi", Project.unserved: .service
        default: nil
        }
    }
}
