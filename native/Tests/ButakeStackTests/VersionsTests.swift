import Foundation
import Testing
@testable import ButakeStack

/// The one list of versions: what counts as an update and what the catalog marks as installed.
@MainActor @Test func versionsOfferOnlyNewerBuildsOfTheSameLine() {
    let provider = VersionProvider(
        id: "node", title: "Node.js", logo: "node",
        installed: [InstalledVersion(id: "24.11.0", version: "24.11.0", line: "24"),
                    InstalledVersion(id: "22.20.0", version: "22.20.0", line: "22")],
        catalog: [CatalogVersion(id: "25.1.0", version: "25.1.0", line: "25"),
                  CatalogVersion(id: "24.22.3", version: "24.22.3", line: "24"),
                  CatalogVersion(id: "22.20.0", version: "22.20.0", line: "22")],
        source: "",
        load: { _ in }, install: FollowedInstall(log: "install-node", tool: "node") { _ in })
    #expect(provider.update(for: provider.installed[0])?.version == "24.22.3")
    #expect(provider.update(for: provider.installed[1]) == nil)
    #expect(provider.installed(provider.catalog[2]))
    #expect(!provider.installed(provider.catalog[0]))
    // Numeric, not textual: 3.13.10 is newer than 3.13.9; a channel is never "newer".
    #expect(VersionProvider.newer("3.13.10", than: "3.13.9"))
    #expect(!VersionProvider.newer("stable", than: "beta"))
}

/// P-29: a PostgreSQL without its extensions is told apart, and the environments' «pass to the
/// processes» option is on unless the engine says otherwise, and survives a save.
@Test func postgresExtensionsAndPassToProcessesDecode() throws {
    let old = try JSONDecoder().decode(ToolManifest.self, from: Data(#"{"tool":"postgres","version":"16.15","url":"","sha256":"","extensions":false}"#.utf8))
    let new = try JSONDecoder().decode(ToolManifest.self, from: Data(#"{"tool":"postgres","version":"16.16","url":"","sha256":"","openssl":"3.5.9","extensions":true}"#.utf8))
    #expect(old.extensions == false && new.extensions == true && new.openssl == "3.5.9")
    var site = try JSONDecoder().decode(ProjectEnvironments.self, from: Data(#"{"active":null,"environments":[]}"#.utf8))
    #expect(site.passes)
    site.passToProcesses = false
    let saved = try JSONSerialization.jsonObject(with: JSONEncoder().encode(site)) as? [String: Any]
    #expect(saved?["passToProcesses"] as? Bool == false)
}
