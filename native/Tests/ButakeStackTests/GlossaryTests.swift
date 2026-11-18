import Foundation
import Testing

/// The glossary of docs/estandar-ui.md («Se dice / No se dice») against the texts the interface shows:
/// a visible text that uses a discarded word fails here. Only the values of Localizable.strings are read.
struct GlossaryTests {
    /// Discarded words (the «No se dice» column) as case-insensitive patterns, with the word they replace.
    static let discarded: [(pattern: String, use: String)] = [
        (#"\bsitios?\b"#, "«proyecto» (o «página web» si es lo que un proyecto sirve)"),
        (#"\bmotor(es)?\b"#, "«servicio»"),
        (#"\bsupervisor\b|\bdaemon\b"#, "«Stack» o «servicio de fondo de Stack»"),
        (#"\bplugins?\b|\bcomplementos?\b|\bmódulos?\b"#, "«herramienta»"),
        (#"\bbroadcasting\b"#, "«tiempo real»"),
        (#"\bagente de sesión\b"#, "«Iniciar con la sesión»"),
        (#"\bencend\w*|\benciend\w*|\bapag\w*"#, "«iniciar / detener» (procesos y servicios) o «activar / desactivar» (herramientas)"),
        (#"\bb[oó]rr(?!ador)\w*"#, "«eliminar» (se pierden datos) o «quitar» (solo sale de la lista)"),
        (#"\bdesinstal\w*"#, "«desactivar» (herramientas) o «quitar»"),
        (#"\bolvid\w*"#, "«eliminar» (se pierden datos) o «quitar»"),
        (#"herramientas? de desarrollo"#, "«utilidad»"),
    ]

    /// Texts that keep a discarded word on purpose, each with its reason.
    static let exceptions: [String: String] = [
        "menu.website": "«Sitio web de Stack» es la web real del producto, no un proyecto",
        "tools.official": "el sitio web oficial de una herramienta de terceros",
        "tools.brokenHelp": "manda al sitio web oficial de una herramienta de terceros",
        "git.accounts.step1Detail": "el sitio del proveedor (GitHub, Bitbucket), no un proyecto",
        "git.pr.missing.unsupportedDetail": "el sitio del proveedor del remoto, no un proyecto",
        "new.kmpWizard": "«módulo» es el término de Gradle, no una parte opcional de la app",
        "new.kmpStep3": "«módulo» es el término de Gradle, no una parte opcional de la app",
        "env.copy": "se borra el portapapeles: no se pierde ningún dato del usuario",
        "env.copied": "se borra el portapapeles: no se pierde ningún dato del usuario",
        "vault.copy": "se borra el portapapeles: no se pierde ningún dato del usuario",
        "vault.copied": "se borra el portapapeles: no se pierde ningún dato del usuario",
        "git.more.removeRemoteDetail": "solo se quita de la lista; «olvidar» describe a Git, que no pierde nada",
        "gcp.revokeDetail": "describe lo que hace gcloud con sus credenciales, no una acción de Stack",
        "vault.link.discardHelp": "descartar una propuesta no pierde datos del usuario",
    ]

    static var strings: [String: String] {
        get throws {
            let file = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/ButakeStack/Resources/es.lproj/Localizable.strings")
            return try #require(NSDictionary(contentsOf: file) as? [String: String])
        }
    }

    static func findings(in strings: [String: String]) -> [String] {
        var found: [String] = []
        for (key, value) in strings.sorted(by: { $0.key < $1.key }) {
            for rule in discarded {
                guard let regex = try? NSRegularExpression(pattern: rule.pattern, options: [.caseInsensitive]),
                      let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
                      let range = Range(match.range, in: value) else { continue }
                found.append("\(key): «\(value[range])» → \(rule.use)")
            }
        }
        return found
    }

    @Test func noTextUsesAWordTheGlossaryDiscards() throws {
        let strings = try Self.strings
        #expect(strings.count > 1000, Comment(rawValue: "Localizable.strings was not read"))
        let unexplained = Self.findings(in: strings.filter { Self.exceptions[$0.key] == nil })
        #expect(unexplained.isEmpty, Comment(rawValue: "Textos con palabras que descarta el glosario de docs/estandar-ui.md:\n" + unexplained.joined(separator: "\n")))
    }

    /// An exception that no longer breaks a rule is dead weight: it would hide a future regression.
    @Test func everyExceptionStillHasItsWord() throws {
        let strings = try Self.strings
        for (key, reason) in Self.exceptions {
            let text = try #require(strings[key], "La excepción «\(key)» ya no existe en Localizable.strings")
            #expect(!Self.findings(in: [key: text]).isEmpty, Comment(rawValue: "La excepción «\(key)» ya no usa una palabra descartada (\(reason)): quítala de la lista"))
        }
    }

    /// The test itself: a text with the discarded word is caught, one that follows the glossary passes.
    @Test func detectsADiscardedWord() {
        #expect(Self.findings(in: ["x": "Mira el sitio"]).count == 1)
        #expect(Self.findings(in: ["x": "Apagar el motor"]).count == 2)
        #expect(Self.findings(in: ["x": "Un borrador del proyecto"]).isEmpty)
        #expect(Self.findings(in: ["x": "Iniciar el servicio"]).isEmpty)
    }
}
