import AppKit
import Foundation
import OSLog

/// The text of a problem report (E-04): Stack's version, macOS, the last failures of the session and the
/// last errors of Stack's own log, with the secrets taken out. It is only text: the user reads it, copies
/// it or saves it. Nothing here touches the network or opens a mail app.
enum ProblemReport {
    static let hidden = "‹oculto›"

    // MARK: Secrets out

    /// Rules in order. Each hides a value and keeps what names it, so the report still says what failed.
    private static let rules: [(pattern: String, template: String)] = [
        // Keys and certificates.
        ("-----BEGIN [A-Z ]+-----[\\s\\S]*?(-----END [A-Z ]+-----|$)", hidden),
        // «scheme://user:password@host»: the whole login goes.
        ("([A-Za-z][A-Za-z0-9+.-]*://)[^\\s/@]*@", "$1\(hidden)@"),
        // Authorization headers.
        ("(?i)\\b(bearer|basic)\\s+[A-Za-z0-9._~+/=-]{8,}", "$1 \(hidden)"),
        // Tokens by the shape their makers give them.
        ("\\b(gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|glpat-[A-Za-z0-9_-]{16,}|xox[abprs]-[A-Za-z0-9-]{10,}"
         + "|sk-[A-Za-z0-9_-]{16,}|AKIA[0-9A-Z]{16}|ASIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{30,}|ATBB[A-Za-z0-9]{20,}|ATATT[A-Za-z0-9_=-]{20,}"
         + "|eyJ[A-Za-z0-9_-]{10,}\\.[A-Za-z0-9_-]{10,}\\.[A-Za-z0-9_-]*)", hidden),
        // `--password hunter2`, `--token=abc`.
        ("(?i)(--?(?:password|passwd|pass|token|secret|api-key|apikey)[ =])\\S+", "$1\(hidden)"),
        // `.env` lines: NAME=value, whatever the name.
        ("(?m)^(\\s*(?:export\\s+)?[A-Z][A-Z0-9_]*)=.*$", "$1=\(hidden)"),
        // The same inside a sentence (`env: PORT=3000 API_URL=…`): an UPPER_CASE name with a value.
        ("(?<![A-Za-z0-9_])([A-Z][A-Z0-9_]{2,})=(\"[^\"]*\"|'[^']*'|[^\\s,;]+)", "$1=\(hidden)"),
        // `password: x`, `"token": "x"`, `DB_PASSWORD=x`, `contraseña = x`: a name that says secret, then its value.
        ("(?i)((?:[\"']?[A-Za-z0-9_.-]*(?:pass(?:word|wd)?|pwd|secret|token|api[_-]?key|private[_-]?key|credential|auth|contrase[ñn]a|ficha|clave)"
         + "[A-Za-z0-9_.-]*[\"']?)\\s*[:=]\\s*)(\"[^\"]*\"|'[^']*'|[^\\s,;&}]+)", "$1\(hidden)"),
        // Long opaque strings with lower case, upper case and digits: a key nobody named. (Hex hashes stay.)
        ("\\b(?=[A-Za-z0-9_-]*[a-z])(?=[A-Za-z0-9_-]*[A-Z])(?=[A-Za-z0-9_-]*[0-9])[A-Za-z0-9_-]{32,}\\b", hidden),
    ]

    /// `text` without secrets and without the home folder's name (`/Users/ana/Stack` → `~/Stack`).
    static func redact(_ text: String, home: String = NSHomeDirectory()) -> String {
        var result = text
        if home.count > 1 { result = result.replacingOccurrences(of: home, with: "~") }
        for (pattern, template) in rules {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            result = expression.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: template)
        }
        // Another account's folder, or the same one by another spelling.
        if let users = try? NSRegularExpression(pattern: "/Users/[^/\\s:\"']+") {
            result = users.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "~")
        }
        return result
    }

    // MARK: Facts

    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        return (info?["CFBundleVersion"] as? String).map { "\(version) (\($0))" } ?? version
    }

    static var macOSVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    private static func stamp(_ date: Date) -> String { date.formatted(.iso8601) }

    // MARK: Texts

    /// What «Copiar detalles» puts on the clipboard for one failure.
    static func details(of failure: ActionFailure, version: String = appVersion, macOS: String = macOSVersion,
                        date: Date = Date(), home: String = NSHomeDirectory()) -> String {
        var lines = ["\(L("error.report.what")): \(failure.title)", "\(L("error.report.message")): \(failure.message)"]
        if let code = failure.code { lines.append("\(L("error.report.code")): \(code)") }
        if let technical = failure.technical, !technical.isEmpty { lines.append("\(L("error.report.technical")): \(technical)") }
        lines += ["Stack: \(version)", "\(macOS)", "\(L("error.report.time")): \(stamp(date))"]
        return redact(lines.joined(separator: "\n"), home: home)
    }

    /// The whole report the sheet shows. `log` are lines of Stack's own log already read.
    static func build(note: String, failures: [FailureRecord], log: [String], version: String = appVersion, macOS: String = macOSVersion,
                      date: Date = Date(), home: String = NSHomeDirectory()) -> String {
        var out = ["\(L("error.report.header"))", "Stack: \(version)", "\(macOS)", "\(L("error.report.time")): \(stamp(date))"]
        if !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out += ["", "\(L("error.report.note")):", note] }
        out += ["", "\(L("error.report.failures")):"]
        if failures.isEmpty { out.append("— \(L("error.report.none"))") }
        for item in failures.suffix(10) {
            var line = "- \(stamp(item.date)) \(item.title): \(item.message)"
            if let code = item.code { line += " [\(code)]" }
            if let technical = item.technical, !technical.isEmpty { line += " (\(technical))" }
            out.append(line)
        }
        out += ["", "\(L("error.report.log")):"]
        if log.isEmpty { out.append("— \(L("error.report.none"))") }
        out += log.suffix(30).map { "  \($0)" }
        return redact(out.joined(separator: "\n"), home: home)
    }

    /// The last errors Stack's own app wrote to the system log in this run (never other apps', never projects').
    static func recentLog(limit: Int = 30) -> [String] {
        guard let store = try? OSLogStore(scope: .currentProcessIdentifier),
              let entries = try? store.getEntries(at: store.position(date: Date().addingTimeInterval(-3600)),
                                                  matching: NSPredicate(format: "subsystem == %@", "cl.butake.stack.native")) else { return [] }
        let lines = entries.compactMap { $0 as? OSLogEntryLog }.filter { $0.level == .error || $0.level == .fault }
            .map { "\(stamp($0.date)) [\($0.category)] \($0.composedMessage)" }
        return Array(lines.suffix(limit))
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
