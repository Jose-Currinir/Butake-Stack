import Foundation
import Testing
@testable import ButakeStack

/// The list the engine sends (engine/src/aws/profiles.rs) decodes as the app reads it. Built by hand:
/// the engine is not asked here, because without a temporary home it would read the Mac's own files.
@Test func awsProfilesDecodeAndDraftsCarryNoSecret() throws {
    let json = """
    {"cli": {"installed": true, "path": "/tmp/home/.local/bin/aws"}, "configPath": "/tmp/config", "credentialsPath": "/tmp/credentials",
     "helperAvailable": true, "ssoSessions": [{"name": "acme", "startUrl": "https://acme.awsapps.com/start", "region": "us-east-1"}],
     "profiles": [
      {"name": "acme-dev", "isDefault": false, "kind": "sso", "region": "sa-east-1", "output": null, "account": "111122223333",
       "keySuffix": null, "keyFile": null, "temporary": false, "ssoSession": "acme", "ssoStartUrl": "https://acme.awsapps.com/start",
       "ssoRegion": "us-east-1", "roleName": "Desarrollo", "session": {"expiresAt": 1893456000, "valid": true}, "roleArn": null,
       "sourceProfile": null, "credentialSource": null, "helper": null, "duplicated": false,
       "projects": [{"project": "tienda", "projectName": "Tienda", "environment": "local", "environmentName": "Local", "production": false}]},
      {"name": "seguro", "isDefault": true, "kind": "process", "region": null, "output": null, "account": null, "keySuffix": null,
       "keyFile": null, "temporary": false, "ssoSession": null, "ssoStartUrl": null, "ssoRegion": null, "roleName": null,
       "session": null, "roleArn": null, "sourceProfile": null, "credentialSource": null, "helper": "missing", "duplicated": false, "projects": []}
     ]}
    """
    let state = try JSONDecoder().decode(AWSState.self, from: Data(json.utf8))
    try #require(state.profiles.count == 2)
    let dev = state.profiles[0]
    #expect(dev.kind == .sso && dev.session?.valid == true && dev.projects.first?.environmentName == "Local")
    #expect(dev.matches("1111") && dev.matches("ACME") && !dev.matches("nada"))
    let safe = state.profiles[1]
    #expect(safe.inKeychain && safe.needsRepair && safe.hasKeys && safe.isDefault)

    let draft = AWSDraft(dev)
    #expect(draft.accountId == "111122223333" && draft.roleName == "Desarrollo" && draft.ssoSession == "acme")
    #expect(Set(draft.json.keys) == ["name", "kind", "region", "output", "ssoSession", "ssoStartUrl", "ssoRegion", "accountId",
                                     "roleName", "roleArn", "sourceProfile"])
    #expect(AWSDraft.validName("acme-prod_2.x") && !AWSDraft.validName("--debug") && !AWSDraft.validName("con espacio")
            && !AWSDraft.validName("") && !AWSDraft.validName("ñandú"))
}

/// The «Sesión única» row: a valid session offers «Renovar sesión…», an expired or missing one
/// «Iniciar sesión…», and while the browser is waited for only «Cancelar».
@Test func awsSessionRowFollowsTheSessionAndTheWait() {
    let valid = AWSProfile.Session(expiresAt: 1_893_456_000, valid: true)
    let expired = AWSProfile.Session(expiresAt: 1_600_000_000, valid: false)
    #expect(AWSSessionMode.of(valid, waiting: false, endingSessions: false) == .renew)
    #expect(AWSSessionMode.of(expired, waiting: false, endingSessions: false) == .signIn)
    #expect(AWSSessionMode.of(nil, waiting: false, endingSessions: false) == .signIn)
    #expect(AWSSessionMode.of(valid, waiting: true, endingSessions: false) == .waiting)
    #expect(AWSSessionMode.of(nil, waiting: true, endingSessions: true) == .waiting)
    #expect(AWSSessionMode.of(valid, waiting: false, endingSessions: true) == .endingSessions)
    // A stop by the app is not an error to show.
    #expect(AWSTool.cancelled(CancellationError()))
    #expect(AWSTool.cancelled(EngineFailure(code: "aws_cancelled", messageKey: "error.aws_cancelled")))
    #expect(!AWSTool.cancelled(EngineFailure(code: "aws_login_timeout", messageKey: "error.aws_login_timeout")))
}

/// Cancelling a stoppable call ends its engine process; the call throws `CancellationError`.
@Test func stoppableCallsEndTheirEngineWhenCancelled() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("bst-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    // A fake engine that notes its pid and waits; SIGTERM ends it.
    let fake = folder.appendingPathComponent("engine")
    let pidFile = folder.appendingPathComponent("pid")
    try "#!/bin/sh\necho $$ > '\(pidFile.path)'\nexec /bin/sleep 30\n".write(to: fake, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
    let engine = StackEngine(executable: fake)
    let call = Task { () -> Bool in
        do {
            let _: AWSIdentity = try await engine.stoppableCall(json: Data("{}".utf8))
            return false
        } catch { return error is CancellationError }
    }
    var pid: Int32?
    for _ in 0..<100 where pid == nil {
        try await Task.sleep(for: .milliseconds(30))
        pid = (try? String(contentsOf: pidFile, encoding: .utf8)).flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }
    let running = try #require(pid)
    call.cancel()
    #expect(await call.value)
    #expect(kill(running, 0) != 0)
}
