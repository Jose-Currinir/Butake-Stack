import Foundation
import Testing
@testable import ButakeStack

/// The assistant's status becomes what the Terminal shows; what it leaves out stays absent and a
/// value out of range is not shown as if it were real.
@Test func assistantStatusIsReadAsReported() throws {
    let full = Data(#"{"model":{"display_name":"Modelo QA"},"cost":{"total_cost_usd":1.5},"context_window":{"used_percentage":37.4},"rate_limits":{"five_hour":{"used_percentage":23.5,"resets_at":1900000000},"seven_day":{"used_percentage":81.2}},"extra":[1]}"#.utf8)
    let usage = try #require(AssistantUsage(statusLine: full))
    #expect(usage.model == "Modelo QA" && usage.costUSD == 1.5 && usage.contextPercent == 37.4)
    #expect(usage.session == .init(percent: 23.5, resets: Date(timeIntervalSince1970: 1_900_000_000)))
    #expect(usage.week == .init(percent: 81.2, resets: nil) && usage.peak == 81.2)

    // Before the first answer, or without a subscription: no limits, and nothing is made up.
    let early = try #require(AssistantUsage(statusLine: Data(#"{"context_window":{"used_percentage":null},"cost":{"total_cost_usd":0}}"#.utf8)))
    #expect(early.contextPercent == nil && early.session == nil && early.week == nil && early.costUSD == 0)
    let odd = try #require(AssistantUsage(statusLine: Data(#"{"context_window":{"used_percentage":"40"},"rate_limits":{"five_hour":{"used_percentage":250},"seven_day":{"used_percentage":true}}}"#.utf8)))
    #expect(odd.isEmpty)
    #expect(AssistantUsage(statusLine: Data("half a wri".utf8)) == nil && AssistantUsage(statusLine: Data()) == nil)
}

/// A session's report lives in a private folder, tells the assistant to copy its status there for
/// that launch only, and leaves nothing when it ends.
@Test func assistantReportIsPrivateAndTemporary() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("stack-usage-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: folder) }
    let report = try #require(AssistantUsageReport.make(id: UUID(), in: folder))
    #expect(report.arguments == ["--settings", report.settings.path] && report.read() == nil)
    let settings = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: report.settings)) as? [String: Any])
    let line = try #require(settings["statusLine"] as? [String: Any])
    #expect(settings.count == 1 && line["type"] as? String == "command" && line["command"] as? String == "/bin/cat > '\(report.status.path)'")
    for url in [folder, report.settings, report.status] {
        let mode = try #require(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
        #expect(mode & 0o077 == 0)
    }
    try Data(#"{"context_window":{"used_percentage":12}}"#.utf8).write(to: report.status)
    #expect(report.read()?.contextPercent == 12)
    report.remove()
    #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    // A folder whose path would break the command's quoting gets no report.
    #expect(AssistantUsageReport.make(id: UUID(), in: folder.appendingPathComponent("it's")) == nil)
}

/// A status line of the user's own is left alone; only that key's presence is looked at.
@Test func ownStatusLineIsRespected() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("stack-usage-home-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: home) }
    try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
    #expect(!AssistantUsageReport.userHasStatusLine(home: home.path))
    let file = home.appendingPathComponent(".claude/settings.json")
    try Data(#"{"model":"qa"}"#.utf8).write(to: file)
    #expect(!AssistantUsageReport.userHasStatusLine(home: home.path))
    try Data(#"{"statusLine":{"type":"command","command":"true"}}"#.utf8).write(to: file)
    #expect(AssistantUsageReport.userHasStatusLine(home: home.path))
}

/// Only the assistants have consumption commands; only one reports a status Stack can read.
@Test func assistantsOfferTheirOwnCommands() {
    #expect(AssistantUsageSource.of("claude-code")?.commands.map(\.id) == ["/usage", "/context"])
    #expect(AssistantUsageSource.of("claude-code")?.reportsStatus == true && AssistantUsageSource.of("codex")?.reportsStatus == false)
    #expect(AssistantUsageSource.of(LocalProgram.shellID) == nil && AssistantUsageSource.of(nil) == nil)
}
