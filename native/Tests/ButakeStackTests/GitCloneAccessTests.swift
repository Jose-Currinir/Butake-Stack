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
