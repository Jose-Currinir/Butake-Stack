import Foundation
import Testing
@testable import ButakeStack

/// `databases[]` of a project keeps the plain names older records have and carries the extensions
/// a database needs, and saving it gives the engine the same shape back (P-43).
@Test func projectDatabasesKeepBothShapes() throws {
    let json = #"["app", {"name": "geo", "extensions": ["postgis", "vector"]}]"#
    let databases = try JSONDecoder().decode([ProjectDatabase].self, from: Data(json.utf8))
    #expect(databases == [ProjectDatabase(name: "app"), ProjectDatabase(name: "geo", extensions: ["postgis", "vector"])])
    let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(databases)) as? [Any]
    #expect(encoded?.first as? String == "app")
    #expect((encoded?.last as? [String: Any])?["extensions"] as? [String] == ["postgis", "vector"])
}

/// What the engine answers about extensions reads as the app expects it.
@Test func extensionAnswersDecode() throws {
    let catalog = #"""
    {"component": "postgres", "version": "18.7", "extensions": [
      {"component": "postgres", "id": "postgis", "name": "PostGIS", "kind": "catalog", "version": "3.7.0",
       "license": "GPL-2.0", "homepage": "https://postgis.net", "sqlNames": ["postgis", "postgis_topology"],
       "downloads": [{"id": "postgis", "name": "PostGIS", "version": "3.7.0", "license": "GPL-2.0", "role": "extension",
                      "url": "https://download.osgeo.org/postgis/source/postgis-3.7.0.tar.gz", "sha256": "ab", "size": 10}],
       "downloadSize": 10, "installed": "3.7.0", "supported": true, "removable": true, "elsewhere": [], "note": "postgisWithout"},
      {"component": "postgres", "id": "citext", "name": "citext", "kind": "bundled", "version": "18.7", "sqlNames": ["citext"],
       "downloads": [], "downloadSize": 0, "installed": "18.7", "supported": true, "removable": false, "elsewhere": []}]}
    """#
    let decoded = try JSONDecoder().decode(ExtensionCatalog.self, from: Data(catalog.utf8))
    #expect(decoded.catalog.map(\.id) == ["postgis"])
    #expect(decoded.bundled.map(\.id) == ["citext"])
    #expect(decoded.activatable == ["citext", "postgis", "postgis_topology"])
    #expect(decoded.catalog.first?.downloads.first?.host == "download.osgeo.org")
    let issues = try JSONDecoder().decode([ExtensionIssue].self, from: Data(#"""
    [{"database": "geo", "extension": "postgis", "problem": "notInstalled", "catalog": "postgis"},
     {"database": "geo", "extension": "nada", "problem": "unknown"}]
    """#.utf8))
    #expect(issues.map(\.fixable) == [true, false])
}

/// Every text the extension screens compose at run time exists.
@MainActor @Test func extensionTextsExist() async throws {
    var keys = ExtensionIssue.problems.map { "ext.problem.\($0)" }
    keys += ["bundled", "catalog", "builtin"].map { "ext.kind.\($0)" }
    keys += ["extension", "library", "buildTool"].map { "ext.role.\($0)" }
    keys += ["postgisWithout", "xdebugSwitch"].map { "ext.note.\($0)" }
    keys.append("db.tab.extensions")
    for tool in ["extension-postgis", "extension-pgvector"] {
        let steps: [String] = try await StackEngine().call(["method": "installSteps", "tool": tool])
        #expect(!steps.isEmpty, "\(tool) has no steps")
        keys += steps.map { "progress.step.\($0)" }
    }
    keys.append("progress.step.activate")
    let missing = keys.filter { localized($0) == nil }
    #expect(missing.isEmpty, "Missing texts: \(missing.joined(separator: ", "))")
}
