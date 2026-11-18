import AppKit
import Foundation
import ServiceManagement
import Testing
@testable import ButakeStack

// MARK: Reconnecting (E-06, M-14, M-18)

private let t0 = Date(timeIntervalSince1970: 1_000_000)

@Test func aMissingAnswerReadsAsReconnectingForFiveSecondsThenStopped() {
    var live = DaemonLiveness()
    live.observe(up: true, at: t0)
    #expect(live.phase(at: t0) == .running)
    live.observe(up: false, at: t0.addingTimeInterval(1))
    #expect(live.phase(at: t0.addingTimeInterval(2)) == .reconnecting)
    #expect(live.phase(at: t0.addingTimeInterval(5.9)) == .reconnecting)
    #expect(live.phase(at: t0.addingTimeInterval(6)) == .stopped)
    // A second failed read does not restart the grace.
    live.observe(up: false, at: t0.addingTimeInterval(4))
    #expect(live.phase(at: t0.addingTimeInterval(6.5)) == .stopped)
    // An answer ends it; the next loss starts a new one.
    live.observe(up: true, at: t0.addingTimeInterval(10))
    #expect(live.phase(at: t0.addingTimeInterval(10)) == .running)
    live.observe(up: false, at: t0.addingTimeInterval(11))
    #expect(live.phase(at: t0.addingTimeInterval(12)) == .reconnecting)
}

@Test func aSupervisorNeverSeenIsStoppedAtOnce() {
    var live = DaemonLiveness()
    live.observe(up: false, at: t0)
    #expect(live.phase(at: t0) == .stopped)
    #expect(live.remaining(at: t0) == nil)
}

@Test func aReadThatCrossedASleepStartsTheGraceAgain() {
    var live = DaemonLiveness()
    live.observe(up: true, at: t0)
    live.observe(up: false, at: t0.addingTimeInterval(1))
    // The Mac was asleep for a long time and wakes: the failed read does not count.
    live.wake(at: t0.addingTimeInterval(600))
    #expect(live.phase(at: t0.addingTimeInterval(602)) == .reconnecting)
    #expect(live.phase(at: t0.addingTimeInterval(606)) == .stopped)
    // A wake long before the loss changes nothing.
    var other = DaemonLiveness()
    other.observe(up: true, at: t0)
    other.wake(at: t0.addingTimeInterval(1))
    other.observe(up: false, at: t0.addingTimeInterval(100))
    #expect(other.phase(at: t0.addingTimeInterval(106)) == .stopped)
}

/// A store whose setup is complete (Caddy and the session agent), so its state is the supervisor's.
@MainActor private func readyStore() throws -> StackStore {
    let store = StackStore()
    let caddy = try JSONDecoder().decode(ToolManifest.self, from: Data(#"{"tool":"caddy","version":"2","url":"u","sha256":"s"}"#.utf8))
    store.installedTools["caddy"] = [caddy]
    store.agent = try JSONDecoder().decode(AgentStatus.self, from: Data(#"{"installed":true,"loaded":true}"#.utf8))
    return store
}

@MainActor @Test func theStatusBarSaysReconnectingBeforeStopped() throws {
    let store = try readyStore()
    store.daemonRunning = false
    #expect(store.stackState == .stopped)
    store.daemonReconnecting = true
    #expect(store.stackState == .reconnecting)
    #expect(!StackState.reconnecting.needsAction)
    #expect(StackState.reconnecting.title == L("stackState.reconnecting"))
    store.daemonRunning = true
    store.daemonReconnecting = false
    #expect(store.stackState != .reconnecting)
}

@MainActor @Test func lostStatusStartsTheGraceInTheStore() throws {
    let store = try readyStore()
    store.applyStatus(nil, at: t0)
    #expect(store.stackState == .stopped)
    store.liveness.observe(up: true, at: t0)
    store.applyStatus(nil, at: Date())
    #expect(store.daemonReconnecting)
    #expect(store.stackState == .reconnecting)
}

// MARK: Links (M-05)

private func link(_ text: String) -> Result<DeepLink.Target, DeepLink.Failure> {
    DeepLink.parse(URL(string: text)!)
}

@Test func theLinksOfEachDestinationAreRead() {
    #expect(link("butakestack://home") == .success(.home))
    #expect(link("butakestack://setup") == .success(.setup))
    #expect(link("butakestack://welcome") == .success(.setup))
    #expect(link("butakestack://site/mi-tienda") == .success(.site("mi-tienda")))
    #expect(link("butakestack://project/rename?id=a&newId=b") == .success(.renameProject(id: "a", newId: "b")))
    #expect(link("butakestack://project/rename?id=a") == .success(.renameProject(id: "a", newId: nil)))
    #expect(link("butakestack://open?path=/Users/ana/demo") == .success(.openFolder("/Users/ana/demo")))
    #expect(link("butakestack://git") == .success(.git(path: nil)))
    #expect(link("butakestack://git/open?path=/Users/ana/demo") == .success(.git(path: "/Users/ana/demo")))
    #expect(link("butakestack://git?path=/Users/ana/demo") == .success(.git(path: "/Users/ana/demo")))
    #expect(link("butakestack://service/cache") == .success(.service("cache")))
    #expect(link("butakestack://general") == .success(.settingsGeneral))
    #expect(link("butakestack://plugins") == .success(.settingsTools))
    #expect(link("butakestack://ssh/host-1") == .success(.ssh("host-1")))
    #expect(link("butakestack://db/main") == .success(.database("main")))
    #expect(link("butakestack://vault") == .success(.vault(paths: nil)))
    if case .success(.tool("logs", let items)) = link("butakestack://tool/logs?origin=web") { #expect(items.count == 1) } else { Issue.record("logs") }
    if case .success(.vault(let paths)) = link("butakestack://vault/import?path=/a&path=/b") { #expect(paths?.count == 2) } else { Issue.record("vault") }
}

@Test func anInvalidLinkIsTurnedDownWithItsReason() {
    #expect(link("butakestack://nada") == .failure(.unknownDestination("nada")))
    #expect(link("butakestack://") == .failure(.unknownDestination("")))
    #expect(link("https://example.com") == .failure(.notStack))
    #expect(link("butakestack://home?x=1") == .failure(.unknownKey("x")))
    #expect(link("butakestack://home/extra") == .failure(.unknownPath("/extra")))
    #expect(link("butakestack://site") == .failure(.unknownPath("/")))
    #expect(link("butakestack://site/a/b") == .failure(.unknownPath("/a/b")))
    #expect(link("butakestack://site/a?extra=1") == .failure(.unknownKey("extra")))
    #expect(link("butakestack://project/rename?id=a&id=b") == .failure(.duplicateKey("id")))
    #expect(link("butakestack://project/rename") == .failure(.missingKey("id")))
    #expect(link("butakestack://project/other?id=a") == .failure(.unknownPath("/other")))
    #expect(link("butakestack://open") == .failure(.missingKey("path")))
    #expect(link("butakestack://open?path=relativo") == .failure(.badValue("path")))
    #expect(link("butakestack://open?path=/a/../b") == .failure(.badValue("path")))
    #expect(link("butakestack://open?path=/a&path=/b") == .failure(.duplicateKey("path")))
    #expect(link("butakestack://tool/logs?origin=nope") == .failure(.badValue("origin")))
    #expect(link("butakestack://tool/aws?source=x") == .failure(.unknownKey("source")))
    #expect(link("butakestack://vault/other") == .failure(.unknownPath("/other")))
    #expect(link("butakestack://vault/import?folder=/a") == .failure(.unknownKey("folder")))
    #expect(link("butakestack://site/%00") == .failure(.badValue("path")))
}

@Test func aLongLinkIsTurnedDownBeforeItIsRead() {
    let long = "butakestack://site/" + String(repeating: "a", count: DeepLink.maximumLength)
    #expect(link(long) == .failure(.tooLong))
    let value = "butakestack://site/" + String(repeating: "a", count: DeepLink.maximumValue + 1)
    #expect(link(value) == .failure(.badValue("path")))
}

@Test func everyFailureHasAReadableMessage() {
    let failures: [DeepLink.Failure] = [.tooLong, .notStack, .unknownDestination("x"), .unknownPath("/x"), .unknownKey("x"),
                                        .duplicateKey("x"), .missingKey("x"), .badValue("x")]
    for failure in failures {
        #expect(failure.message.hasPrefix("Enlace no válido: "), "\(failure)")
        #expect(!failure.message.contains("error.link"), "\(failure)")
    }
}

@MainActor @Test func anInvalidLinkDoesNotNavigateAndSaysWhy() {
    let store = StackStore()
    store.route = .service("cache")
    store.handle(URL(string: "butakestack://nada")!)
    #expect(store.route == .service("cache"))
    #expect(store.errorMessage == DeepLink.Failure.unknownDestination("nada").message)
    store.errorMessage = nil
    store.handle(URL(string: "butakestack://service/cache?extra=1")!)
    #expect(store.route == .service("cache"))
    #expect(store.errorMessage?.contains("extra") == true)
    store.errorMessage = nil
    store.handle(URL(string: "butakestack://site/no-existe")!)
    #expect(store.errorMessage?.contains("no-existe") == true)
    store.errorMessage = nil
    store.handle(URL(string: "butakestack://home")!)
    #expect(store.route == .home)
    #expect(store.errorMessage == nil)
}

// MARK: Reopening (M-06) and starting with the session (M-17)

@Test func openingStackAgainShowsTheWindowOnlyWhenNoneIsVisible() {
    #expect(ReopenRule.showsMainWindow(hasVisibleWindows: false))
    #expect(!ReopenRule.showsMainWindow(hasVisibleWindows: true))
    #expect(ReopenRule.link.scheme == "butakestack")
    #expect(DeepLink.parse(ReopenRule.link) == .success(.home))
}

@MainActor @Test func theAppRegistersAtLoginWithTheAgentAndLeavesWhenItGoes() {
    #expect(LoginItem.action(agentOn: true, status: .notRegistered) == .register)
    #expect(LoginItem.action(agentOn: true, status: .enabled) == .nothing)
    #expect(LoginItem.action(agentOn: true, status: .requiresApproval) == .nothing)
    #expect(LoginItem.action(agentOn: false, status: .enabled) == .unregister)
    #expect(LoginItem.action(agentOn: false, status: .notRegistered) == .nothing)
}

// MARK: Menu bar icon (M-02)

@MainActor @Test func theMenuBarIconShowsADotUnlessEverythingRuns() {
    for state in StackState.allCases {
        #expect(MenuBarIcon.showsDot(for: state) == (state != .running), "\(state)")
    }
    #expect(MenuBarIcon.description(for: .running) == L("app.name"))
    #expect(MenuBarIcon.description(for: .stopped).hasSuffix(StackState.stopped.title))
    #expect(MenuBarIcon.image(for: .stopped).accessibilityDescription == MenuBarIcon.description(for: .stopped))
    #expect(MenuBarIcon.image(for: .stopped).isTemplate)
    #expect(MenuBarIcon.image(for: .running).isTemplate)
}

/// Opaque pixels in the corner where the dot goes, for the plain icon and for the one with a dot.
@MainActor @Test func theDotIsAShapeNotAColor() throws {
    func corner(_ state: StackState) throws -> Int {
        let image = MenuBarIcon.image(for: state)
        let tiff = try #require(image.tiffRepresentation)
        let rep = try #require(NSBitmapImageRep(data: tiff))
        var count = 0
        let scale = Double(rep.pixelsWide) / 18
        for x in Int(11 * scale)..<rep.pixelsWide { for y in 0..<Int(7 * scale) where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 { count += 1 } }
        return count
    }
    // BUTAKE_QA_ICON_DIR: writes both icons, black on white and enlarged, for the review's screenshot.
    if let dir = ProcessInfo.processInfo.environment["BUTAKE_QA_ICON_DIR"] {
        let sheet = NSImage(size: NSSize(width: 360, height: 180), flipped: false) { rect in
            NSColor.white.setFill(); rect.fill()
            for (index, state) in [StackState.running, .stopped].enumerated() {
                MenuBarIcon.image(for: state).draw(in: NSRect(x: 20 + index * 170, y: 20, width: 140, height: 140))
            }
            return true
        }
        if let tiff = sheet.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("icono-punto.png"))
        }
    }
    #expect(try corner(.stopped) != corner(.running))
    #expect(try corner(.stopped) > 0)
}

// MARK: Notices (E-01, M-01, M-16)

private func sampleProject(_ id: String) -> Project {
    Project(id: id, name: id, path: "/tmp/\(id)", domains: ["\(id).test"], https: false, kind: "static",
            runtime: [:], docroot: ".", services: [], databases: [], processes: [], enabled: true)
}

@MainActor private final class FakeCenter: NoticeCenter {
    var allow = true
    var asked = 0
    var posted: [SystemNotice] = []
    func requestAuthorization() async -> Bool { asked += 1; return allow }
    func post(_ notice: SystemNotice) async { posted.append(notice) }
}

@MainActor private func notices(center: FakeCenter, background: Bool = true, seen: String? = nil) -> SystemNotices {
    let defaults = UserDefaults(suiteName: "notices-\(UUID().uuidString)")!
    if let seen { defaults.set(seen, forKey: SystemNotices.updateKey) }
    return SystemNotices(center: center, defaults: defaults, inBackground: { background })
}

private func settle() async { for _ in 0..<5 { await Task.yield() } }

@Test func theNoticesStartOffAndAreDueOncePerEpisode() {
    var planner = NoticePlanner()
    let down = NoticeFacts(crashed: ["site.web"], updateVersion: "1.2.0")
    #expect(planner.due(down, enabled: true, inBackground: true) == [.updateReady("1.2.0"), .processDown("site.web")])
    // The same facts again: nothing.
    #expect(planner.due(down, enabled: true, inBackground: true).isEmpty)
    // The process runs again and crashes again: a new episode.
    #expect(planner.due(NoticeFacts(updateVersion: "1.2.0"), enabled: true, inBackground: true).isEmpty)
    #expect(planner.due(down, enabled: true, inBackground: true) == [.processDown("site.web")])
    // A newer update is a new episode.
    #expect(planner.due(NoticeFacts(crashed: ["site.web"], updateVersion: "1.3.0"), enabled: true, inBackground: true) == [.updateReady("1.3.0")])
}

@Test func nothingIsDueWhenOffOrWithTheWindowInFront() {
    var off = NoticePlanner()
    #expect(off.due(NoticeFacts(crashed: ["a.b"], updateVersion: "2.0"), enabled: false, inBackground: true).isEmpty)
    var front = NoticePlanner()
    #expect(front.due(NoticeFacts(crashed: ["a.b"], updateVersion: "2.0"), enabled: true, inBackground: false).isEmpty)
    // What was seen is consumed: going to the background later does not announce it.
    #expect(front.due(NoticeFacts(crashed: ["a.b"], updateVersion: "2.0"), enabled: true, inBackground: true).isEmpty)
    #expect(!NoticePlanner.installDue(enabled: true, inBackground: false))
    #expect(!NoticePlanner.installDue(enabled: false, inBackground: true))
    #expect(NoticePlanner.installDue(enabled: true, inBackground: true))
}

@MainActor @Test func macOSIsAskedOnlyWhenTheSwitchIsTurnedOn() async {
    let center = FakeCenter()
    let service = notices(center: center)
    #expect(!service.enabled)
    #expect(center.asked == 0)
    await service.setEnabled(true)
    #expect(service.enabled)
    #expect(center.asked == 1)
    await service.setEnabled(false)
    #expect(!service.enabled)
}

@MainActor @Test func aRefusedPermissionLeavesTheSwitchOff() async {
    let center = FakeCenter()
    center.allow = false
    let service = notices(center: center)
    await service.setEnabled(true)
    #expect(!service.enabled)
    #expect(service.denied)
}

@MainActor @Test func aCrashedProcessIsNoticedOnceAndOpensItsProject() async {
    let center = FakeCenter()
    let service = notices(center: center)
    await service.setEnabled(true)
    let project = sampleProject("tienda")
    let facts = NoticeFacts(crashed: ["tienda.queue"])
    service.evaluate(facts, projects: [project], title: { _ in "Cola" })
    service.evaluate(facts, projects: [project], title: { _ in "Cola" })
    await settle()
    #expect(center.posted.count == 1)
    #expect(center.posted.first?.link == "butakestack://site/tienda")
    #expect(center.posted.first?.title == String(format: L("settings.notices.process.title"), "Cola"))
}

@MainActor @Test func nothingIsPostedOffOrWithTheWindowInFront() async {
    let off = FakeCenter()
    let silent = notices(center: off)
    silent.evaluate(NoticeFacts(crashed: ["a.b"], updateVersion: "9.9"), projects: [], title: { $0 })
    silent.installFinished(tool: "node")
    await settle()
    #expect(off.posted.isEmpty)

    let front = FakeCenter()
    let watching = notices(center: front, background: false)
    await watching.setEnabled(true)
    watching.evaluate(NoticeFacts(crashed: ["a.b"], updateVersion: "9.9"), projects: [], title: { $0 })
    watching.installFinished(tool: "node")
    await settle()
    #expect(front.posted.isEmpty)
}

@MainActor @Test func anUpdateIsNoticedOncePerVersionEvenAfterARestart() async {
    let center = FakeCenter()
    let defaults = UserDefaults(suiteName: "notices-\(UUID().uuidString)")!
    let first = SystemNotices(center: center, defaults: defaults, inBackground: { true })
    await first.setEnabled(true)
    first.evaluate(NoticeFacts(updateVersion: "3.1.0"), projects: [], title: { $0 })
    await settle()
    #expect(center.posted.map(\.link) == ["butakestack://general"])
    let second = SystemNotices(center: center, defaults: defaults, inBackground: { true })
    second.evaluate(NoticeFacts(updateVersion: "3.1.0"), projects: [], title: { $0 })
    await settle()
    #expect(center.posted.count == 1)
}

@MainActor @Test func aStackProcessOpensItsLogAndEveryNoticeLinkIsValid() {
    let own = SystemNotices.processNotice(id: "stack.caddy", name: "Caddy", projects: [])
    #expect(own.link == "butakestack://tool/logs?source=stack.caddy")
    let all = [own, SystemNotices.updateNotice(version: "1.0"), SystemNotices.installNotice(name: "Node.js"),
               SystemNotices.processNotice(id: "tienda.web", name: "Web", projects: [sampleProject("tienda")])]
    for notice in all {
        #expect((try? DeepLink.parse(URL(string: notice.link)!).get()) != nil, "\(notice.link)")
        #expect(!notice.title.isEmpty && !notice.body.isEmpty)
    }
}

/// One missed reading after the service was seen: the cards keep their last state during the grace
/// (no «Detenido» everywhere for a second), and lose it only when the grace ends.
@MainActor @Test func aMissedReadingKeepsTheLastStateOnScreen() throws {
    let store = try readyStore()
    let t0 = Date()
    let running = StackStatus(listeners: [:], processes: [])
    store.applyStatus(running, at: t0)
    #expect(store.daemonRunning && store.status != nil)
    store.applyStatus(nil, at: t0.addingTimeInterval(1))
    #expect(store.daemonReconnecting && store.daemonRunning && store.status != nil)
    store.applyStatus(nil, at: t0.addingTimeInterval(30))
    #expect(!store.daemonReconnecting && !store.daemonRunning && store.status == nil)
}
