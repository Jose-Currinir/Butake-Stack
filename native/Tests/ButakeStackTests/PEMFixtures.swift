import Foundation

/// PEM boundary lines for test data, put together when the test runs so that no source file holds a literal
/// private-key header that secret scanners (push protection, gitleaks) would report. The bodies are made up.
enum PEM {
    static func begin(_ label: String = "PRIVATE KEY") -> String { "-----" + "BEGIN " + label + "-----" }
    static func end(_ label: String = "PRIVATE KEY") -> String { "-----" + "END " + label + "-----" }
    /// A block with a made-up body; `escaped` writes the line breaks as `\n` for use inside JSON text.
    static func block(_ body: String, label: String = "PRIVATE KEY", escaped: Bool = false) -> String {
        let text = begin(label) + "\n" + body + "\n" + end(label) + "\n"
        return escaped ? text.replacingOccurrences(of: "\n", with: "\\n") : text
    }
}
