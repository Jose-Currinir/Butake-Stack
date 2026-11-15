import Foundation
import Testing
@testable import ButakeStack

/// A made-up project of Stack, linked or not to Google Cloud.
private func project(_ link: String = "") throws -> Project {
    let json = """
    {"id": "tienda", "name": "Tienda", "path": "/qa/tienda", "domains": ["tienda.test"], "https": false, "kind": "kmp",
     "runtime": {}, "docroot": ".", "services": [], "databases": [], "processes": [], "enabled": false\(link)}
    """
    return try JSONDecoder().decode(Project.self, from: Data(json.utf8))
}

/// The fake gcloud of the engine's tests, copied to a temporary folder with its own configuration
/// (two made-up accounts, the first one active). It refuses to run without CLOUDSDK_CONFIG.
private func fakeGcloud() throws -> (folder: URL, program: String, config: URL) {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("stack-gcp-\(UUID().uuidString)")
    let config = folder.appendingPathComponent("config")
    try FileManager.default.createDirectory(at: config.appendingPathComponent("configurations"), withIntermediateDirectories: true)
    let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../engine/src/gcp/testdata/gcloud")
    let program = folder.appendingPathComponent("gcloud")
    try FileManager.default.copyItem(at: source, to: program)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: program.path)
    try "qa@ejemplo.test\notra@ejemplo.test\n".write(to: config.appendingPathComponent("accounts"), atomically: true, encoding: .utf8)
    try "default".write(to: config.appendingPathComponent("active_config"), atomically: true, encoding: .utf8)
    try "[core]\naccount = qa@ejemplo.test\nproject = agenda-de-prueba\n"
        .write(to: config.appendingPathComponent("configurations/config_default"), atomically: true, encoding: .utf8)
    return (folder, program.path, config)
}

private func activeConfiguration(_ config: URL) throws -> [String] {
    try [String(contentsOf: config.appendingPathComponent("active_config"), encoding: .utf8),
         String(contentsOf: config.appendingPathComponent("configurations/config_default"), encoding: .utf8)]
}

/// What the engine sends decodes as the tool reads it, and a project keeps its link when the app
/// saves it again (the engine refuses records with unknown fields, so a lost field would unlink it).
@Test func gcpStateDecodesAndProjectsKeepTheirLink() throws {
    let json = """
    {"cli": {"installed": true, "path": "/qa/bin/gcloud"},
     "accounts": [{"account": "qa@ejemplo.test", "kind": "user", "active": true},
                  {"account": "despliegue@tienda-ficticia.iam.gserviceaccount.com", "kind": "service", "active": false}],
     "links": [{"id": "tienda", "name": "Tienda", "account": "qa@ejemplo.test", "project": "tienda-ficticia"}]}
    """
    let state = try JSONDecoder().decode(GCPState.self, from: Data(json.utf8))
    #expect(state.accounts.map(\.kind) == [.user, .service] && state.accounts[0].active && state.links[0].project == "tienda-ficticia")
    #expect(state.accounts[0].matches("EJEMPLO") && !state.accounts[0].matches("nada"))

    let linked = try project(#", "gcp": {"account": "qa@ejemplo.test", "project": "tienda-ficticia"}"#)
    #expect(linked.gcp == GCPLink(account: "qa@ejemplo.test", project: "tienda-ficticia"))
    let saved = try JSONSerialization.jsonObject(with: JSONEncoder().encode(linked)) as? [String: Any]
    #expect((saved?["gcp"] as? [String: String]) == ["account": "qa@ejemplo.test", "project": "tienda-ficticia"])
    #expect(try project().gcp == nil)

    for good in ["tienda-ficticia", "proyecto-qa-123", "ejemplo.cl:tienda-qa"] { #expect(GCPLink.validProject(good), "\(good)") }
    for bad in ["", "corto", "Tienda-Qa", "1tienda", "tienda-", "--account=x", "tienda qa", ":tienda-qa", String(repeating: "a", count: 31)] {
        #expect(!GCPLink.validProject(bad), "\(bad)")
    }
}

/// The pages of Google's consoles open on the project, as the account (never a service account,
/// which cannot sign in to a browser).
@Test func gcpConsolePagesNameTheProjectAndTheAccount() throws {
    let dashboard = try #require(GCPConsolePage.dashboard.url(project: "tienda-ficticia", account: "qa@ejemplo.test"))
    #expect(dashboard.absoluteString == "https://console.cloud.google.com/home/dashboard?project=tienda-ficticia&authuser=qa@ejemplo.test")
    #expect(GCPConsolePage.credentials.url(project: "tienda-ficticia", account: nil)?.absoluteString
            == "https://console.cloud.google.com/apis/credentials?project=tienda-ficticia")
    #expect(GCPConsolePage.billing.url(project: "tienda-ficticia", account: "x@tienda-ficticia.iam.gserviceaccount.com")?.absoluteString
            == "https://console.cloud.google.com/billing/linkedaccount?project=tienda-ficticia")
    #expect(GCPConsolePage.firebase.url(project: "tienda-ficticia", account: "qa@ejemplo.test")?.absoluteString
            == "https://console.firebase.google.com/project/tienda-ficticia/overview?authuser=qa@ejemplo.test")
}

/// A console opened from a linked project gets the account and project the engine resolved
/// (siteShellEnvironment: the link, or the project's own value written by hand), checked in a real
/// session; nothing else of the project's environment, and none of them without a link.
@MainActor @Test func consolesOfALinkedProjectGetItsAccountAndProject() async throws {
    let resolved = ["PATH": "/qa/runtimes/node/22/bin:/usr/bin", "CLOUDSDK_CORE_ACCOUNT": "qa@ejemplo.test",
                    "CLOUDSDK_CORE_PROJECT": "tienda-ficticia", "GOOGLE_CLOUD_PROJECT": "escrito-a-mano", "SECRET": "x"]
    let launch = LocalConsoles.launch(.shell, directory: "/qa/tienda", project: "tienda", projectEnvironment: resolved)
    for line in ["CLOUDSDK_CORE_ACCOUNT=qa@ejemplo.test", "CLOUDSDK_CORE_PROJECT=tienda-ficticia", "GOOGLE_CLOUD_PROJECT=escrito-a-mano"] {
        #expect(launch.environment.contains(line), "\(line)")
    }
    #expect(!launch.environment.contains { $0.hasPrefix("SECRET=") })
    let plain = LocalConsoles.launch(.shell, directory: "/qa/tienda", project: "tienda", projectEnvironment: ["PATH": "/usr/bin"])
    #expect(!plain.environment.contains { line in GCPLink.variables.contains { line.hasPrefix($0 + "=") } })

    // The session really starts with them: a program of the session writes its environment.
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("stack-gcp-console-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let run = LocalLaunch(program: "qa", executable: "/bin/sh", arguments: ["-c", "env > env.txt"], directory: folder.path,
                          environment: launch.environment)
    let session = TerminalSession(kind: .local(run), title: "qa")
    await session.start()
    let file = folder.appendingPathComponent("env.txt")
    for _ in 0..<100 where (try? String(contentsOf: file, encoding: .utf8))?.contains("GOOGLE_CLOUD_PROJECT") != true {
        try await Task.sleep(for: .milliseconds(50))
    }
    let written = try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map(String.init)
    #expect(written.contains("CLOUDSDK_CORE_ACCOUNT=qa@ejemplo.test") && written.contains("CLOUDSDK_CORE_PROJECT=tienda-ficticia")
            && written.contains("GOOGLE_CLOUD_PROJECT=escrito-a-mano"))
    session.terminate()
    await session.ending?.value
}

/// «Iniciar sesión…» runs `gcloud auth login --no-activate` by itself, with no account or project
/// of a project: run against the fake gcloud, the account is added and gcloud's active
/// configuration stays as it was.
@MainActor @Test func signInNeverChangesTheActiveConfiguration() throws {
    let fake = try fakeGcloud()
    defer { try? FileManager.default.removeItem(at: fake.folder) }
    let launch = GCPConsole.signInLaunch(gcloud: fake.program, account: nil,
                                         inherited: ["CLOUDSDK_CONFIG": fake.config.path, "CLOUDSDK_CORE_ACCOUNT": "otra@ejemplo.test"])
    #expect(launch.executable == fake.program && launch.arguments == ["auth", "login", "--no-activate"])
    #expect(launch.environment.contains("CLOUDSDK_CONFIG=\(fake.config.path)"))
    #expect(!launch.environment.contains { line in GCPLink.variables.contains { line.hasPrefix($0 + "=") } })
    #expect(launch.environment.first { $0.hasPrefix("PATH=") }?.hasPrefix("PATH=\(fake.folder.path):") == true)
    #expect(GCPConsole.signInLaunch(gcloud: fake.program, account: "otra@ejemplo.test", inherited: [:]).arguments
            == ["auth", "login", "--no-activate", "otra@ejemplo.test"])

    let before = try activeConfiguration(fake.config)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: launch.executable)
    process.arguments = launch.arguments
    process.environment = Dictionary(launch.environment.compactMap { line -> (String, String)? in
        guard let equals = line.firstIndex(of: "=") else { return nil }
        return (String(line[..<equals]), String(line[line.index(after: equals)...]))
    }, uniquingKeysWith: { _, last in last })
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
    let accounts = try String(contentsOf: fake.config.appendingPathComponent("accounts"), encoding: .utf8)
    #expect(accounts.contains("nueva@ejemplo.test"))
    #expect(try activeConfiguration(fake.config) == before)
}
