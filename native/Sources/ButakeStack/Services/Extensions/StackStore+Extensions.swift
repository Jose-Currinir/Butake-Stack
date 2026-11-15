import Foundation

/// Extensions of the services (engine: `runtimes/extensions`): installed in the engine, active in
/// a database, and what a project declares.
extension StackStore {
    /// The log every extension operation reports to (`installProgress`).
    static let extensionLog = "install-extension"

    func extensionCatalog(_ component: String = "postgres") async throws -> ExtensionCatalog {
        try await call(["method": "extensionCatalog", "component": component])
    }

    /// Installs or updates a catalog extension, followed by its sheet: stoppable, and it throws.
    /// Without `version`, in the PostgreSQL in use; with it, in that installed version (a restore).
    func installExtensionFollowed(_ id: String, version: String? = nil) async throws {
        var request: [String: Any] = ["method": "installExtension", "component": "postgres", "id": id, "confirmed": true]
        if let version { request["version"] = version }
        let result: InstalledExtension = try await stoppableCall(request)
        if !result.updatedDatabases.isEmpty {
            notify(String(format: L("ext.updatedIn"), result.updatedDatabases.joined(separator: ", ")))
        }
    }

    /// Removes it from the engine; refused (with the databases) while one uses it.
    func removeExtension(_ id: String) async -> Bool {
        var removed = false
        await run(L("busy.removing")) {
            let _: Bool = try await self.call(["method": "removeExtension", "component": "postgres", "id": id, "confirmed": true])
            removed = true
        }
        return removed
    }

    func databaseExtensions(_ database: String) async throws -> DatabaseExtensions {
        try await call(["method": "databaseExtensions", "database": database])
    }

    func activateExtensions(_ names: [String], in database: String) async throws {
        let _: [ActiveExtension] = try await call(["method": "activateExtension", "database": database, "names": names, "confirmed": true])
    }

    /// What deactivating `name` would take with it, to say before asking.
    func extensionDependents(_ name: String, in database: String) async throws -> [String] {
        try await call(["method": "extensionDependents", "database": database, "name": name])
    }

    func deactivateExtension(_ name: String, in database: String, cascade: Bool) async throws {
        let _: [ActiveExtension] = try await call(["method": "deactivateExtension", "database": database, "name": name,
                                                   "cascade": cascade, "confirmed": true])
    }

    func projectExtensionIssues(_ project: Project) async -> [ExtensionIssue] {
        guard project.databases.contains(where: { !$0.extensions.isEmpty }) else { return [] }
        return (try? await call(["method": "projectExtensions", "id": project.id])) ?? []
    }

    /// «Resolver»: installs what the catalog has and activates what the project declares, followed.
    func resolveProjectExtensionsFollowed(_ project: Project) async throws {
        let left: [ExtensionIssue] = try await stoppableCall(["method": "resolveProjectExtensions", "id": project.id, "confirmed": true])
        if !left.isEmpty { notify(String(format: L("ext.project.left"), left.count)) }
    }

    /// A project just turned on says at once when its databases lack an extension; its Resumen
    /// shows what and the button that resolves it.
    func checkExtensionsAfterStart(_ project: Project) async {
        let issues = await projectExtensionIssues(project)
        if !issues.isEmpty { notify(String(format: L("ext.project.toast"), project.title)) }
    }
}
