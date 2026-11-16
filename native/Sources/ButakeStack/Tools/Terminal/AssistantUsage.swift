import Foundation

/// How an assistant session is doing, as the assistant itself reports it: the context it has used,
/// the plan's limits (session of 5 hours and week) and the session's estimated cost. Every value
/// is optional: the assistant leaves out what does not apply (the limits before its first answer,
/// or without a subscription), and Stack shows only what it was given, never a number of its own.
struct AssistantUsage: Equatable, Sendable {
    struct Limit: Equatable, Sendable {
        /// 0…100.
        var percent: Double
        var resets: Date?
    }
    var model: String?
    var contextPercent: Double?
    var session: Limit?
    var week: Limit?
    var costUSD: Double?

    var isEmpty: Bool { self == AssistantUsage() }

    /// The short line of the tab bar: «Contexto 37 % · 5 h 24 % · Semana 81 %», with what there is.
    var summary: String {
        [contextPercent.map { String(format: L("ssh.usage.short.context"), Self.percent($0)) },
         session.map { String(format: L("ssh.usage.short.session"), Self.percent($0.percent)) },
         week.map { String(format: L("ssh.usage.short.week"), Self.percent($0.percent)) }]
            .compactMap { $0 }.joined(separator: " · ")
    }
    /// The highest of the plan's limits, for the indicator's color.
    var peak: Double { max(session?.percent ?? 0, week?.percent ?? 0) }

    static func percent(_ value: Double) -> String { "\(Int(max(0, min(100, value)).rounded())) %" }
}

extension AssistantUsage {
    /// The status the assistant hands to its status line command (JSON). Unknown fields are
    /// ignored and a missing or malformed one is simply absent; nil when it is not that JSON.
    init?(statusLine data: Data) {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        func object(_ parent: [String: Any]?, _ key: String) -> [String: Any]? { parent?[key] as? [String: Any] }
        func number(_ parent: [String: Any]?, _ key: String) -> Double? {
            guard let value = parent?[key] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
            return value.doubleValue.isFinite ? value.doubleValue : nil
        }
        func limit(_ window: [String: Any]?) -> Limit? {
            guard let percent = number(window, "used_percentage"), (0...100).contains(percent) else { return nil }
            return Limit(percent: percent, resets: number(window, "resets_at").map { Date(timeIntervalSince1970: $0) })
        }
        let limits = object(root, "rate_limits")
        self.init(model: (object(root, "model")?["display_name"] as? String).map { String($0.prefix(60)) },
                  contextPercent: number(object(root, "context_window"), "used_percentage").flatMap { (0...100).contains($0) ? $0 : nil },
                  session: limit(object(limits, "five_hour")), week: limit(object(limits, "seven_day")),
                  costUSD: number(object(root, "cost"), "total_cost_usd").flatMap { $0 >= 0 ? $0 : nil })
    }
}

/// What a kind of assistant offers about its consumption: the commands of its own that show it
/// (sent to the session only when the user asks) and whether it reports a status Stack can read.
struct AssistantUsageSource: Sendable {
    struct Command: Identifiable, Sendable {
        /// What is typed in the session («/usage»); also its identifier.
        let id: String
        let titleKey: String
    }
    let commands: [Command]
    /// The assistant runs a status line command with its status as JSON.
    let reportsStatus: Bool

    static func of(_ program: String?) -> AssistantUsageSource? {
        switch program {
        case "claude-code":
            AssistantUsageSource(commands: [.init(id: "/usage", titleKey: "ssh.usage.command.usage"),
                                            .init(id: "/context", titleKey: "ssh.usage.command.context")], reportsStatus: true)
        case "codex":
            AssistantUsageSource(commands: [.init(id: "/status", titleKey: "ssh.usage.command.status")], reportsStatus: false)
        default: nil
        }
    }
}

/// The report of one session: two files of Stack's own in a private temporary folder, gone when
/// the session ends. `settings` adds, for that launch only, a status line command that copies the
/// assistant's status into `status`; nothing is written in the assistant's own folder, and no
/// credential, conversation nor token is read: only that status (percentages, model and cost).
struct AssistantUsageReport: Equatable, Sendable {
    let settings: URL
    let status: URL

    /// The arguments that make the assistant load `settings` (after the program's own).
    var arguments: [String] { ["--settings", settings.path] }

    /// The settings of the launch: the status goes to the file through `cat`, whose path is fixed
    /// and quoted (a folder with a quote in its name gets no report, see `make`).
    static func settingsJSON(status: URL) -> Data {
        let value: [String: Any] = ["statusLine": ["type": "command", "command": "/bin/cat > '\(status.path)'"]]
        return (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) ?? Data()
    }

    /// Creates the files of a session in `folder` (0700, files 0600); nil when it cannot.
    static func make(id: UUID, in folder: URL = defaultFolder) -> AssistantUsageReport? {
        guard !folder.path.contains("'") else { return nil }
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            // What a session that could not clean up left behind (the app was killed): gone after a day.
            for old in (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
                if let date = (try? old.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                   date < Date.now.addingTimeInterval(-86_400) { try? manager.removeItem(at: old) }
            }
            let report = AssistantUsageReport(settings: folder.appendingPathComponent("\(id.uuidString).settings.json"),
                                              status: folder.appendingPathComponent("\(id.uuidString).status.json"))
            for (url, data) in [(report.settings, settingsJSON(status: report.status)), (report.status, Data())] {
                guard manager.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) else { return nil }
            }
            return report
        } catch { return nil }
    }
    static var defaultFolder: URL { FileManager.default.temporaryDirectory.appendingPathComponent("cl.butake.stack.usage", isDirectory: true) }

    /// What the assistant last reported; nil while it has reported nothing (or mid-write).
    func read() -> AssistantUsage? {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: status.path))?[.size] as? Int, size > 0, size <= 262_144,
              let data = try? Data(contentsOf: status) else { return nil }
        return AssistantUsage(statusLine: data)
    }
    func remove() {
        for url in [settings, status] { try? FileManager.default.removeItem(at: url) }
    }

    /// Whether the user set a status line of their own for the assistant: then Stack does not
    /// replace it, and offers only the assistant's commands. Only that key's presence is read.
    static func userHasStatusLine(home: String = NSHomeDirectory()) -> Bool {
        let file = URL(fileURLWithPath: home).appendingPathComponent(".claude/settings.json")
        guard let size = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int, size <= 1_048_576,
              let data = try? Data(contentsOf: file), let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
        return root["statusLine"] != nil
    }
}
