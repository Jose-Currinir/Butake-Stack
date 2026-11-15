import AppKit

/// Stack's folders: its data in Application Support and the default place of new projects.
enum Folder {
    /// Folder names in `~/Library/Application Support`: the current one and the one of the name
    /// the product had before, which keeps working until the user moves the data.
    static let dataName = "Stack"
    static let oldDataName = "Butake Stack"

    /// Where the data lives, resolved exactly like the engine (`Store::resolve` in core/store.rs):
    /// `BUTAKE_STACK_HOME` (tests and QA); else the new folder once it holds Stack's data; else the
    /// old folder while it has not been moved (never touched here); else the new one.
    static func resolveData(home: String, environment: [String: String]) -> (path: String, old: Bool) {
        if let isolated = environment["BUTAKE_STACK_HOME"] { return (isolated, false) }
        let support = home + "/Library/Application Support/"
        let new = support + dataName, old = support + oldDataName
        var isDirectory: ObjCBool = false
        let files = FileManager.default
        let holdsData = files.fileExists(atPath: new + "/stack.json")
            || (files.fileExists(atPath: new + "/projects", isDirectory: &isDirectory) && isDirectory.boolValue)
        if !holdsData && files.fileExists(atPath: old, isDirectory: &isDirectory) && isDirectory.boolValue { return (old, true) }
        return (new, false)
    }
    private static var resolved: (path: String, old: Bool) {
        resolveData(home: NSHomeDirectory(), environment: ProcessInfo.processInfo.environment)
    }
    /// Stack's own folder (an isolated store under QA).
    static var base: String { resolved.path }
    static var baseURL: URL { URL(fileURLWithPath: base) }
    /// Whether the data is still in the folder of the old name (Ajustes › Avanzado offers to move it).
    static var usesOldData: Bool { resolved.old }
    static func open(_ relative: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: base + "/" + relative))
    }

    // MARK: Projects

    static let projectsKey = "projects.folder"
    static func defaultProjects(home: String = NSHomeDirectory()) -> String { home + "/Stack/Projects" }
    /// `~/Stack/Projects` unless the user chose another folder in Ajustes › Avanzado.
    static func projects(home: String = NSHomeDirectory(), defaults: UserDefaults = .standard) -> String {
        let chosen = defaults.string(forKey: projectsKey) ?? ""
        return chosen.hasPrefix("/") ? chosen : defaultProjects(home: home)
    }
    static var projects: String { projects() }
    /// Keeps the user's choice; choosing the default again forgets it.
    static func setProjects(_ path: String, home: String = NSHomeDirectory(), defaults: UserDefaults = .standard) {
        let path = URL(fileURLWithPath: path).standardizedFileURL.path
        if path == defaultProjects(home: home) { defaults.removeObject(forKey: projectsKey) } else { defaults.set(path, forKey: projectsKey) }
    }

    /// Ajustes › Avanzado: new projects go to `App`, `Service` or `Web` inside the projects folder
    /// (on unless the user turned it off).
    static let sortsKey = "projects.sortByPlace"
    static func sortsByPlace(defaults: UserDefaults = .standard) -> Bool { defaults.object(forKey: sortsKey) as? Bool ?? true }
    /// Where a new project of `place` goes: its subfolder, or the projects folder itself when
    /// sorting is off. Nothing is created here (see `ensureProjects`).
    static func newProjects(in place: ProjectPlace, home: String = NSHomeDirectory(), defaults: UserDefaults = .standard) -> String {
        let root = projects(home: home, defaults: defaults)
        return sortsByPlace(defaults: defaults) ? (root as NSString).appendingPathComponent(place.folder) : root
    }

    /// The projects folder, created the first time an action of the user needs it (never at launch).
    @discardableResult static func ensureProjects(_ path: String = projects) -> URL {
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    static func revealProjects() {
        NSWorkspace.shared.open(ensureProjects())
    }
}
