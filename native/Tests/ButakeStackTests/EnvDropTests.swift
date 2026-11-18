import Foundation
import Testing
@testable import ButakeStack

// A `.env` dropped on a project that already has environments: the name comes from the file, a
// taken name never replaces anything, and secrets go to the Keychain (here, memory) only.

@MainActor @Test func theNameComesFromTheFileName() {
    #expect(EnvDrop.stem(of: ".env.staging") == "staging")
    #expect(EnvDrop.stem(of: "production.env") == "production")
    #expect(EnvDrop.stem(of: ".env") == "")
    #expect(EnvDrop.stem(of: ".env.staging.local") == "staging.local")
}

@MainActor @Test func aTakenNameGetsANumberAndNeverReusesAnEnvironment() {
    let free = EnvDrop.target("staging", taken: ["local"], fallback: "Importado")
    #expect(free == EnvDrop.Target(id: "staging", name: "staging", kind: .staging))
    let taken = EnvDrop.target("staging", taken: ["local", "staging"], fallback: "Importado")
    #expect(taken == EnvDrop.Target(id: "staging-2", name: "staging 2", kind: .other))
    let again = EnvDrop.target("staging", taken: ["staging", "staging-2"], fallback: "Importado")
    #expect(again.id == "staging-3")
    let custom = EnvDrop.target("qa", taken: [], fallback: "Importado")
    #expect(custom == EnvDrop.Target(id: "qa", name: "qa", kind: .other))
    #expect(EnvDrop.target("  ", taken: [], fallback: "Importado").id == "importado")
}

@MainActor @Test func secretsGoToTheKeychainAndNeverStayInTheEntries() throws {
    let pairs = [("APP_NAME", "Tienda"), ("DB_PASSWORD", "clave-inventada-1"), ("API_KEY", "token-inventado-2")]
    let split = EnvDrop.entries(pairs, secret: [false, true, true])
    #expect(split.entries == [EnvEntry(key: "APP_NAME", value: "Tienda", secret: false),
                              EnvEntry(key: "DB_PASSWORD", value: "", secret: true),
                              EnvEntry(key: "API_KEY", value: "", secret: true)])
    #expect(!String(describing: split.entries).contains("inventad"))
    let items = MemoryKeychainItems()
    let secrets = EnvSecrets(items: items)
    try secrets.update(site: "tienda", env: "local", set: ["LOCAL_KEY": "otro"], remove: [])
    try secrets.update(site: "tienda", env: "staging-2", set: split.secrets, remove: [])
    #expect(try secrets.values(site: "tienda", env: "staging-2") == ["DB_PASSWORD": "clave-inventada-1", "API_KEY": "token-inventado-2"])
    #expect(try secrets.values(site: "tienda", env: "local") == ["LOCAL_KEY": "otro"], "the other environment is not touched")
    // Without a classification, a variable is treated as secret (safe side).
    #expect(EnvDrop.entries([("X", "1")], secret: []).entries.first?.secret == true)
}

@MainActor @Test func theDroppedFilePreviewShowsNamesOnly() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("env-drop-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent(".env.staging")
    try "APP_NAME=Tienda\nDB_PASSWORD=clave-inventada-1\n".write(to: file, atomically: true, encoding: .utf8)
    let project = Project(id: "tienda", name: "tienda", path: folder.path, domains: ["tienda.test"], https: false, kind: "static", runtime: [:],
                          docroot: ".", services: [], databases: [], processes: [], enabled: false, env: [:])
    let preview = StackStore().envDropPreview(project, url: file)
    #expect(preview?.keys == ["APP_NAME", "DB_PASSWORD"])
    #expect(preview?.proposedName == "staging")
    #expect(!String(describing: preview as Any).contains("clave-inventada"))
}
