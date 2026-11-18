import AppKit
import Observation
import OSLog
import UserNotifications

/// What is worth a macOS notice: a link that opens the page of the matter, and the words.
struct SystemNotice: Equatable {
    var id: String
    var title: String
    var body: String
    /// A `butakestack://` link; tapping the notice opens it.
    var link: String
}

/// What a read of the app shows, reduced to what decides a notice.
struct NoticeFacts: Equatable {
    /// Processes of the supervisor that crashed now, by id.
    var crashed: Set<String> = []
    /// The version of an update that is ready to install, if any.
    var updateVersion: String?
}

/// Decides which notices are due, once per episode. Pure: it knows nothing of macOS.
///
/// - An episode is noticed at most once: a process that crashed until it runs again, an update until
///   a newer version comes.
/// - Whatever is seen is consumed, whether or not it is noticed: a crash seen with the window in
///   front is not announced later when the app goes to the background.
/// - Only a notice that is on, with the window in the background, is posted.
struct NoticePlanner: Equatable {
    enum Kind: Equatable {
        case processDown(String)
        case updateReady(String)
    }

    private(set) var crashedSeen: Set<String> = []
    private(set) var updateSeen: String?

    init(updateSeen: String? = nil) { self.updateSeen = updateSeen }

    mutating func due(_ facts: NoticeFacts, enabled: Bool, inBackground: Bool) -> [Kind] {
        var due: [Kind] = []
        let started = facts.crashed.subtracting(crashedSeen)
        // A process that runs again ends its episode: the next crash is a new one.
        crashedSeen = facts.crashed
        if let version = facts.updateVersion, version != updateSeen {
            updateSeen = version
            if enabled && inBackground { due.append(.updateReady(version)) }
        }
        if enabled && inBackground { due += started.sorted().map(Kind.processDown) }
        return due
    }

    /// A finished install is its own episode; it is due when the notice is on and the window is behind.
    static func installDue(enabled: Bool, inBackground: Bool) -> Bool { enabled && inBackground }
}

/// The macOS side of the notices, so the rest can be tested with a double.
@MainActor protocol NoticeCenter: AnyObject {
    func requestAuthorization() async -> Bool
    func post(_ notice: SystemNotice) async
}

/// The real center. It exists only in an installed app bundle: a test run or a bare binary has none
/// and `UNUserNotificationCenter.current()` would stop it, so there nothing is ever posted.
@MainActor final class LiveNoticeCenter: NoticeCenter {
    static var available: Bool { Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil }

    func requestAuthorization() async -> Bool {
        guard Self.available else { return false }
        return (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert])) ?? false
    }

    func post(_ notice: SystemNotice) async {
        guard Self.available else { return }
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.body = notice.body
        content.userInfo = ["link": notice.link]
        content.interruptionLevel = .active
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: notice.id, content: content, trigger: nil))
    }
}

/// macOS notices for what happens while Stack is behind: an update ready, a project's process that
/// crashed, an install that finished. Off until the user turns them on in Ajustes › General; the
/// permission is asked for only then.
@MainActor @Observable final class SystemNotices: NSObject, UNUserNotificationCenterDelegate {
    static let shared = SystemNotices()
    private static let log = Logger(subsystem: "cl.butake.stack.native", category: "notices")
    static let enabledKey = "systemNotices"
    static let updateKey = "systemNotices.lastUpdate"

    /// The notices are on. Off by default; `setEnabled` is the only way to turn them on.
    private(set) var enabled: Bool
    /// macOS did not give the permission: the switch stays off and Ajustes says where to allow it.
    private(set) var denied = false

    @ObservationIgnored private let center: NoticeCenter
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var planner: NoticePlanner
    @ObservationIgnored private var inBackground: () -> Bool
    @ObservationIgnored private weak var store: StackStore?

    init(center: NoticeCenter = LiveNoticeCenter(), defaults: UserDefaults = .standard,
         inBackground: @escaping () -> Bool = { !NSApp.isActive }) {
        self.center = center
        self.defaults = defaults
        self.inBackground = inBackground
        enabled = defaults.bool(forKey: Self.enabledKey)
        planner = NoticePlanner(updateSeen: defaults.string(forKey: Self.updateKey))
        super.init()
    }

    /// Turning on asks macOS for permission; if it is not given the switch goes back off.
    func setEnabled(_ on: Bool) async {
        guard on else {
            enabled = false
            defaults.set(false, forKey: Self.enabledKey)
            return
        }
        let allowed = await center.requestAuthorization()
        enabled = allowed
        denied = !allowed
        defaults.set(allowed, forKey: Self.enabledKey)
    }

    // MARK: Reading the app

    /// Starts following the supervisor's processes and the updates.
    func start(store: StackStore) {
        guard self.store == nil else { return }
        self.store = store
        if LiveNoticeCenter.available { UNUserNotificationCenter.current().delegate = self }
        track()
    }

    private func track() {
        guard let store else { return }
        let facts = withObservationTracking {
            Self.facts(store: store, updates: UpdateService.shared)
        } onChange: { [weak self] in
            Task { @MainActor in self?.track() }
        }
        evaluate(facts, projects: store.projects, title: { store.processTitle($0) })
    }

    static func facts(store: StackStore, updates: UpdateService) -> NoticeFacts {
        NoticeFacts(crashed: Set(store.status?.processes.filter { $0.status.state == "crashed" }.map(\.id) ?? []),
                    updateVersion: updates.phase == .available && updates.updateAvailable ? updates.latest?.version : nil)
    }

    /// Posts what is due for these facts.
    func evaluate(_ facts: NoticeFacts, projects: [Project], title: (String) -> String) {
        let due = planner.due(facts, enabled: enabled, inBackground: inBackground())
        if let version = planner.updateSeen { defaults.set(version, forKey: Self.updateKey) }
        for kind in due {
            switch kind {
            case .updateReady(let version):
                deliver(Self.updateNotice(version: version))
            case .processDown(let id):
                deliver(Self.processNotice(id: id, name: title(id), projects: projects))
            }
        }
    }

    /// An install that finished (`InstallMonitor`).
    func installFinished(tool: String) {
        guard NoticePlanner.installDue(enabled: enabled, inBackground: inBackground()) else { return }
        deliver(Self.installNotice(name: Tech.of(tool).title))
    }

    private func deliver(_ notice: SystemNotice) {
        Task { await center.post(notice) }
    }

    // MARK: The notices

    static func updateNotice(version: String) -> SystemNotice {
        SystemNotice(id: "update-\(version)", title: L("settings.notices.update.title"),
                     body: String(format: L("settings.notices.update.body"), version), link: "butakestack://general")
    }

    static func processNotice(id: String, name: String, projects: [Project]) -> SystemNotice {
        // A project's process opens the project; one of Stack's own opens its log.
        let owner = projects.first { id.hasPrefix($0.id + ".") }
        let link = owner.map { "butakestack://site/\($0.id)" } ?? "butakestack://tool/logs?source=\(id.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? id)"
        return SystemNotice(id: "down-\(id)", title: String(format: L("settings.notices.process.title"), name),
                            body: L("settings.notices.process.body"), link: link)
    }

    static func installNotice(name: String) -> SystemNotice {
        SystemNotice(id: "install-\(name)-\(Int(Date().timeIntervalSince1970))", title: L("settings.notices.install.title"),
                     body: String(format: L("settings.notices.install.body"), name), link: "butakestack://home")
    }

    // MARK: Tapping a notice

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let link = response.notification.request.content.userInfo["link"] as? String
        completionHandler()
        Task { @MainActor in Self.open(link) }
    }

    /// Opens the page of the notice: only a valid link of Stack, through the same door as any link.
    static func open(_ link: String?) {
        guard let link, let url = URL(string: link), case .success = DeepLink.parse(url) else { return }
        NSWorkspace.shared.open(url)
    }
}
