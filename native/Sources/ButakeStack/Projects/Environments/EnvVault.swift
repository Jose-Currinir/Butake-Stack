import AppKit
import LocalAuthentication

/// Local authentication and the clipboard for Entornos' secrets, which live in the Keychain (R1, see
/// `EnvSecrets`). Revealing, copying and activating Production first ask for Touch ID or the Mac's
/// password (R3, R4). See `.compliance/docs/21719-gestor-entornos-requisitos.md`.
@MainActor enum EnvVault {
    // MARK: Local authentication
    /// The app's own grace period after an explicit prompt (reveal and copy only). macOS's reuse of a
    /// recent unlock (`touchIDAuthenticationAllowableReuseDuration`) is NOT used: with it, a recent
    /// Touch ID unlock of the Mac approved prompts silently, which defeats R3 and R4.
    private static var lastAuthentication: Date?
    /// `fresh`: always prompt (Production); otherwise a prompt answered in the last 60 s counts.
    static func authenticate(_ reason: String, fresh: Bool = false) async -> Bool {
        if !fresh, let last = lastAuthentication, Date().timeIntervalSince(last) < 60 { return true }
        let context = LAContext()
        context.touchIDAuthenticationAllowableReuseDuration = 0
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return false }
        let ok: Bool
        do { ok = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) } catch { ok = false }
        context.invalidate()
        if ok && !fresh { lastAuthentication = Date() }
        return ok
    }

    /// Copies a secret as concealed content and clears it after 60 seconds if it is still there (R3).
    static func copy(_ value: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.declareTypes([.string, NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")], owner: nil)
        pasteboard.setString(value, forType: .string)
        pasteboard.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        let count = pasteboard.changeCount
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(60))
            if NSPasteboard.general.changeCount == count { NSPasteboard.general.clearContents() }
        }
    }
}

/// Reads a `.env` file into ordered key/value pairs (comments and blank lines dropped).
enum DotEnv {
    static func parse(_ text: String) -> [(String, String)] {
        var out: [(String, String)] = []
        for raw in text.components(separatedBy: .newlines) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)) }
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\""), let end = closingQuote(value, "\"") {
                value = String(value[value.index(after: value.startIndex)..<end])
                    .replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\$", with: "$")
                    .replacingOccurrences(of: "\\\\", with: "\\")
            } else if value.hasPrefix("'"), let end = value.dropFirst().firstIndex(of: "'") {
                value = String(value[value.index(after: value.startIndex)..<end])
            } else if let hash = value.range(of: " #") {
                value = value[..<hash.lowerBound].trimmingCharacters(in: .whitespaces)
            }
            guard !key.isEmpty, key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." }) else { continue }
            out.removeAll { $0.0 == key }
            out.append((key, value))
        }
        return out
    }
    private static func closingQuote(_ value: String, _ quote: Character) -> String.Index? {
        var index = value.index(after: value.startIndex)
        var escaped = false
        while index < value.endIndex {
            let c = value[index]
            if c == quote && !escaped { return index }
            escaped = c == "\\" && !escaped
            index = value.index(after: index)
        }
        return nil
    }
}
