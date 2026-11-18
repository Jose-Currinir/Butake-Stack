import Foundation

/// What the projects Stack already knows ask for: the kinds of work «¿Con qué trabajas?» marks, and
/// the projects behind each one, so the assistant can say why.
struct ProfileSuggestion: Equatable, Identifiable {
    /// A `WorkProfile` id.
    let profile: String
    /// The titles of the projects that ask for it, in the list's order.
    let projects: [String]
    var id: String { profile }
}

enum ProfileDetection {
    /// The profile each kind of project asks for. A kind with no entry (a static site, a proxy)
    /// needs nothing the assistant installs.
    static let profileOfKind: [String: String] = [
        "laravel": "laravel", "php": "laravel",
        "node": "web", "vite": "web", "astro": "web", "emdash": "web", "next": "web",
        "django": "python", "fastapi": "python", "python": "python",
        "swift": "swift", "rust": "rust", "kmp": "kmp", "react-native": "react-native",
        "android": "android",
    ]

    /// One suggestion per profile, in the order of `WorkProfile.all`. A project without a server is
    /// read by what it is built with (`technology`), like the rest of the UI.
    static func suggestions(for projects: [Project]) -> [ProfileSuggestion] {
        var byProfile: [String: [String]] = [:]
        for project in projects where !project.isMissing {
            let kind = project.isServed ? project.kind : project.technology ?? project.kind
            if let profile = profileOfKind[kind] { byProfile[profile, default: []].append(project.title) }
        }
        return WorkProfile.all.compactMap { profile in
            byProfile[profile.id].map { ProfileSuggestion(profile: profile.id, projects: $0) }
        }
    }

    /// The marked profiles after adding the suggested ones; what was marked stays.
    static func marked(_ chosen: Set<String>, adding suggestions: [ProfileSuggestion]) -> Set<String> {
        chosen.union(suggestions.map(\.profile))
    }
}
