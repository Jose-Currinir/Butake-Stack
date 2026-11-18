import Foundation
import Testing
@testable import ButakeStack

/// What «Clonar…» reads from the engine about an SSH address, and what it shows for it.
@Test func cloneAccessIsReadAsTheEngineWritesIt() throws {
    let missing = try JSONDecoder().decode(GitSSHAccess.self, from: Data(#"{"ssh":true,"host":"git.example.invalid","port":22,"hostKnown":false,"identities":false}"#.utf8))
    #expect(missing.blocked && missing.host == "git.example.invalid")
    let ready = try JSONDecoder().decode(GitSSHAccess.self, from: Data(#"{"ssh":true,"host":"git.example.invalid","port":7999,"hostKnown":true,"identities":true}"#.utf8))
    #expect(!ready.blocked && ready.port == 7999)
    // An HTTPS address is never held back by SSH.
    let https = try JSONDecoder().decode(GitSSHAccess.self, from: Data(#"{"ssh":false,"host":"","port":0,"hostKnown":false,"identities":false}"#.utf8))
    #expect(!https.blocked)
}

@MainActor @Test func theFingerprintsToAcceptAreShownWhole() throws {
    let seen = try JSONDecoder().decode(GitSSHFingerprints.self, from: Data(#"{"host":"git.example.invalid","port":22,"fingerprints":["(ED25519) SHA256:inventadaUno","(RSA) SHA256:inventadaDos"],"official":false}"#.utf8))
    #expect(seen.message.contains("SHA256:inventadaUno\n(RSA) SHA256:inventadaDos"))
    var official = seen
    official.official = true
    #expect(official.message != seen.message)
    for key in ["git.access.host.title", "git.access.trust.title", "git.access.key.title", "git.access.public.title", "git.access.https.title"] {
        #expect(localized(key) != nil, "\(key)")
    }
}

/// The page to register a public key is the provider's own site, over HTTPS.
@Test func publicKeysAreRegisteredOnTheProvidersSite() {
    #expect(GitHostingProvider.github.sshKeysPage.host == "github.com" && GitHostingProvider.github.sshKeysPage.scheme == "https")
    #expect(GitHostingProvider.bitbucket.sshKeysPage.host == "bitbucket.org" && GitHostingProvider.bitbucket.sshKeysPage.scheme == "https")
}

/// The account's token goes with a transfer only over HTTPS and only to its provider's own
/// origin, with the user name each provider takes with a token.
@MainActor @Test func theTokenGoesToGitOnlyForItsProviderOverHTTPS() async throws {
    let token = "ficha-inventada-para-git"
    let vault = GitHostingVault(items: MemoryKeychainItems())
    try vault.save(GitHostingAccount(provider: .bitbucket, login: "ana-qa", name: "Ana Prueba", email: "ana@example.invalid"),
                   credentials: GitHostingCredentials(email: "ana@example.invalid", token: token))
    let hosting = GitHosting(endpoints: .production, vault: vault)

    let bitbucket = try #require(await hosting.transferCredentials(for: "https://bitbucket.org/equipo/app.git"))
    #expect(bitbucket == ["origin": "https://bitbucket.org", "username": "x-bitbucket-api-token-auth", "password": token])
    // Bitbucket's own clone address carries the user: the origin is still the provider's.
    #expect(await hosting.transferCredentials(for: "https://ana-qa@bitbucket.org/equipo/app.git")?["origin"] == "https://bitbucket.org")

    // SSH, another server, a look-alike name and a provider without an account: nothing is sent.
    for remote in ["git@bitbucket.org:equipo/app.git", "ssh://git@bitbucket.org/equipo/app.git", "https://git.example.invalid/equipo/app.git",
                   "https://bitbucket.org.example.invalid/equipo/app.git", "http://bitbucket.org/equipo/app.git", "https://github.com/equipo/app.git", ""] {
        #expect(await hosting.transferCredentials(for: remote) == nil, "\(remote)")
    }
    let plain: [String: Any] = ["method": "gitClone", "url": "git@bitbucket.org:equipo/app.git"]
    #expect(await hosting.transfer(plain, remote: "git@bitbucket.org:equipo/app.git")["credentials"] == nil)
    #expect(await hosting.transfer(plain, remote: "https://bitbucket.org/equipo/app.git")["credentials"] != nil)

    // On GitHub the account's own name goes with the token.
    try vault.save(GitHostingAccount(provider: .github, login: "ana-qa", name: "", email: ""), credentials: GitHostingCredentials(email: "", token: token))
    await hosting.loadAccounts()
    #expect(await hosting.transferCredentials(for: "https://github.com/equipo/app.git")?["username"] == "ana-qa")
}
