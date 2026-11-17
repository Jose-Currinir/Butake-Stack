import Foundation
import Testing
@testable import ButakeStack

// Environments: what is read from a .env and what a save sends to the Keychain.

@Test func dotEnvReadsQuotesExportsAndComments() {
    let text = """
    # comentario
    export A=1
    B="x y" # nota
    C='literal $x'
    D=valor # nota
    E="a\\"b"
    1 MAL=x
    F=uno
    F=dos

    """
    #expect(DotEnv.parse(text).map { "\($0.0)=\($0.1)" } == ["A=1", "B=x y", "C=literal $x", "D=valor", "E=a\"b", "F=dos"])
}

@MainActor @Test func theKeychainChangesUseTheTrimmedKeyTheEntriesKeep() {
    func row(_ key: String, _ value: String, secret: Bool, new: String? = nil) -> EnvironmentsView.Row {
        EnvironmentsView.Row(key: key, value: value, secret: secret, newSecret: new, original: nil)
    }
    let rows = [row("API_KEY ", "", secret: true, new: "s3"), row("PLANO", "x", secret: false), row(" TOKEN", "viejo", secret: true)]
    let stored = [EnvEntry(key: "API_KEY", value: "", secret: true), EnvEntry(key: "TOKEN", value: "", secret: true),
                  EnvEntry(key: "ANTES", value: "", secret: true)]
    let changes = EnvironmentsView.secretChanges(rows, current: stored, stored: ["API_KEY", "TOKEN", "ANTES"])
    #expect(changes.set == ["API_KEY": "s3", "TOKEN": "viejo"])
    // Only ANTES stopped being a secret: the ones kept under a padded key are not deleted.
    #expect(changes.remove == ["ANTES"])
}
