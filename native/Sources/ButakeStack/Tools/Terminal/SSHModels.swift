import AppKit
import Foundation

// MARK: - Terminal SSH

struct SSHForward: Codable, Identifiable, Hashable, Sendable {
    var id: String = ""
    var name: String = ""
    /// local (-L), remote (-R) or dynamic (-D, SOCKS).
    var kind: String = "local"
    var listenPort: Int = 0
    var targetHost: String = ""
    var targetPort: Int = 0
    var autostart: Bool = false
    /// Started again by Stack when it drops.
    var keepAlive: Bool = false

    /// "127.0.0.1:15432 → db.interna:5432"
    var route: String {
        switch kind {
        case "remote": String(format: L("ssh.forward.remoteRoute"), listenPort, targetHost, targetPort)
        case "dynamic": String(format: L("ssh.forward.dynamicRoute"), listenPort)
        default: String(format: L("ssh.forward.localRoute"), listenPort, targetHost, targetPort)
        }
    }
    var title: String { name.isEmpty ? L("ssh.forward.kind.\(kind)") : name }
}

struct SSHHost: Codable, Identifiable, Hashable, Sendable {
    var id: String = ""
    var name: String = ""
    var description: String = ""
    var group: String = ""
    var tags: [String] = []
    var host: String = ""
    var port: Int = 22
    var user: String = ""
    var key: String?
    var identity: String?
    /// Another saved host to go through (ProxyJump).
    var jump: String?
    var forwards: [SSHForward] = []

    var address: String { port == 22 ? "\(user)@\(host)" : "\(user)@\(host):\(port)" }
    func matches(_ text: String) -> Bool {
        text.isEmpty || ([name, host, user, group, description] + tags).contains { $0.localizedCaseInsensitiveContains(text) }
    }
}

struct SSHOverview: Codable, Sendable {
    struct Active: Codable, Hashable, Sendable { var host: String; var forward: String; var since: Int }
    /// A forward whose ssh exited on its own (kept-alive ones say when they try again).
    struct Down: Codable, Hashable, Sendable { var host: String; var forward: String; var failures: Int; var retryAt: Int; var error: String; var keepAlive: Bool }
    var hosts: [SSHHost]
    var active: [Active]
    var down: [Down]?
}

struct SSHHostState: Codable, Sendable {
    var state: String
    var fingerprints: [String]
    /// Whose keys these are: the host itself, or its jump host while that one is not known yet.
    var host: String?
}

/// State of the SSH terminal: saved hosts, the selected one, forwards that run and the host key
/// round trip (compare fingerprints, trust, continue).
@MainActor @Observable final class SSHTerminal {
    static let shared = SSHTerminal()
    let store = StackStore.shared

    var hosts: [SSHHost] = []
    var active: [SSHOverview.Active] = []
    var down: [SSHOverview.Down] = []
    /// The host chosen; another one chosen anywhere (saved, imported, a link) takes over the
    /// detail from a program of «Este Mac».
    var selection: String? {
        didSet { if selection != oldValue, selection != nil { SSHWorkspace.shared.localSelection = nil } }
    }
    var editing: SSHHost?
    /// A host the user asked to delete: it waits for the confirmation.
    var deleting: SSHHost?
    var loaded = false
    var hostStates: [String: SSHHostState] = [:]
    var checking: Set<String> = []
    var busyForwards: Set<String> = []
    /// An unknown server: its fingerprints and what to do once the user trusts them.
    var trustRequest: TrustRequest?
    struct TrustRequest: Identifiable {
        let id = UUID()
        /// Whose keys are compared (the target, or its jump host first).
        let host: SSHHost
        let fingerprints: [String]
        let then: Next
        /// The host the action is for (differs from `host` while its jump is verified).
        var target: SSHHost?
        enum Next { case open, external, sftp, forward(String), none }
    }
    @ObservationIgnored private var keepAliveTask: Task<Void, Never>?

    var groups: [String] {
        Array(Set(hosts.map(\.group))).sorted { a, b in
            a.isEmpty ? false : b.isEmpty ? true : a.localizedCaseInsensitiveCompare(b) == .orderedAscending
        }
    }
    var tags: [String] {
        Array(Set(hosts.flatMap(\.tags))).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
    func host(_ id: String?) -> SSHHost? { hosts.first { $0.id == id } }
    func since(_ host: SSHHost, _ forward: SSHForward) -> Date? {
        active.first { $0.host == host.id && $0.forward == forward.id }.map { Date(timeIntervalSince1970: TimeInterval($0.since)) }
    }
    func dropped(_ host: SSHHost, _ forward: SSHForward) -> SSHOverview.Down? {
        down.first { $0.host == host.id && $0.forward == forward.id }
    }
    func activeCount(_ host: SSHHost) -> Int { active.filter { $0.host == host.id }.count }
    /// Hosts that go through this one.
    func jumpers(of host: SSHHost) -> [SSHHost] { hosts.filter { $0.jump == host.id } }

    func load() async {
        do {
            let overview: SSHOverview = try await store.call(["method": "sshHosts"])
            hosts = overview.hosts
            active = overview.active
            down = overview.down ?? []
            // The first host as the sidebar shows them (groups by name, "no group" last).
            if selection == nil || host(selection) == nil { selection = groups.lazy.compactMap { group in self.hosts.first { $0.group == group } }.first?.id }
        } catch { store.report(error) }
        loaded = true
    }

    func encode(_ host: SSHHost) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(host))) as? [String: Any] ?? [:]
    }

    func save(_ host: SSHHost) async -> Bool {
        do {
            let saved: SSHHost = try await store.call(["method": "sshSaveHost", "host": encode(host)])
            await load()
            selection = saved.id
            hostStates[saved.id] = nil
            store.notify(String(format: L("ssh.saved"), saved.name))
            return true
        } catch { store.report(error); return false }
    }

    func delete(_ host: SSHHost) async {
        do {
            let _: Bool = try await store.call(["method": "sshDeleteHost", "id": host.id])
            if selection == host.id { selection = nil }
            await load()
        } catch { store.report(error) }
    }

    /// Compares the server's keys with the known ones; nil if the server cannot be reached.
    @discardableResult
    func check(_ host: SSHHost, quiet: Bool = false) async -> SSHHostState? {
        checking.insert(host.id)
        defer { checking.remove(host.id) }
        if let jump = self.host(host.jump), !(await SSHKeyring.shared.ensureAgent(jump.key, interactive: !quiet)) {
            if !quiet { return nil }
        }
        do {
            let state: SSHHostState = try await store.call(["method": "sshHostCheck", "id": host.id])
            hostStates[host.id] = state
            if let other = state.host, other != host.id { hostStates[other] = state }
            return state
        } catch {
            // Automatic checks only say it in the card; the user asked for the others.
            hostStates[host.id] = SSHHostState(state: "unreachable", fingerprints: [], host: host.id)
            if !quiet { store.report(error) }
            return nil
        }
    }

    /// Runs `next` once the host (and its jump) are known. A host already verified in this
    /// session is not scanned again: ssh itself refuses a changed key (StrictHostKeyChecking).
    private func verified(_ host: SSHHost, then next: TrustRequest.Next, rescan: Bool = false) async -> Bool {
        if !rescan, hostStates[host.id]?.state == "known", hostStates[host.id]?.host == host.id { return true }
        guard let state = await check(host) else { return false }
        switch state.state {
        case "known" where state.host == nil || state.host == host.id: return true
        case "known", "unknown":
            let owner = self.host(state.host) ?? host
            trustRequest = TrustRequest(host: owner, fingerprints: state.fingerprints, then: next, target: host)
        default: store.errorMessage = L("error.ssh_host_changed")
        }
        return false
    }

    /// Keys a host needs in the agent: its own (when protected) and its jump's.
    private func agentReady(_ host: SSHHost, interactive: Bool = true) async -> Bool {
        if let jump = self.host(host.jump), !(await SSHKeyring.shared.ensureAgent(jump.key, interactive: interactive)) { return false }
        return await SSHKeyring.shared.ensureAgent(host.key, interactive: interactive)
    }

    /// Opens a session in Stack's own terminal.
    func open(_ host: SSHHost) async {
        guard await verified(host, then: .open) else { return }
        // A protected key without the agent still works: ssh then asks for it in the terminal.
        _ = await agentReady(host)
        SSHWorkspace.shared.openTerminal(.ssh(host.id), title: host.name)
    }
    /// The secondary way: a window of Terminal.app.
    func openExternal(_ host: SSHHost) async {
        guard await verified(host, then: .external) else { return }
        _ = await agentReady(host)
        do {
            let _: Bool = try await store.call(["method": "sshOpen", "id": host.id])
            store.notify(String(format: L("ssh.opened"), host.name))
        } catch { store.report(error) }
    }
    func openFiles(_ host: SSHHost, path: String = "") async {
        guard await verified(host, then: .sftp), await agentReady(host) else { return }
        SSHWorkspace.shared.openSFTP(host, path: path)
    }

    /// After ssh or sftp refused the server's key: compare again and offer to trust.
    func recheckAfterFailure(_ id: String, then next: TrustRequest.Next = .open) async {
        guard let host = host(id) else { return }
        hostStates[id] = nil
        _ = await verified(host, then: next, rescan: true)
    }

    func trust(_ request: TrustRequest) async {
        do {
            let _: Bool = try await store.call(["method": "sshTrust", "id": request.host.id, "fingerprints": request.fingerprints, "confirmed": true])
            trustRequest = nil
            hostStates[request.host.id] = SSHHostState(state: "known", fingerprints: request.fingerprints, host: request.host.id)
            let target = request.target ?? request.host
            if target.id != request.host.id { hostStates[target.id] = nil }
            switch request.then {
            case .open: await open(target)
            case .external: await openExternal(target)
            case .sftp: await openFiles(target)
            case .forward(let id): if let forward = target.forwards.first(where: { $0.id == id }) { await start(target, forward) }
            case .none: if target.id != request.host.id { await check(target, quiet: true) }
            }
        } catch { store.report(error) }
    }

    func start(_ host: SSHHost, _ forward: SSHForward) async {
        let key = "\(host.id)/\(forward.id)"
        busyForwards.insert(key)
        defer { busyForwards.remove(key) }
        guard await verified(host, then: .forward(forward.id)), await agentReady(host) else { return }
        do {
            let _: Int = try await store.call(["method": "sshForwardStart", "id": host.id, "forward": forward.id])
            await load()
        } catch let failure as EngineFailure where failure.code == "ssh_host_unknown" || failure.code == "ssh_host_changed" {
            await recheckAfterFailure(host.id, then: .forward(forward.id))
        } catch { store.report(error) }
    }

    func stop(_ host: SSHHost, _ forward: SSHForward) async {
        do {
            let _: Bool = try await store.call(["method": "sshForwardStop", "id": host.id, "forward": forward.id])
            await load()
        } catch { store.report(error) }
    }

    /// Starts the forwards marked to open with the host.
    func startAll(_ host: SSHHost) async {
        for forward in host.forwards where forward.autostart && since(host, forward) == nil {
            await start(host, forward)
            if trustRequest != nil { return }
        }
    }

    /// Kept-alive forwards that dropped are started again every so often (the engine spaces the
    /// attempts out). Protected keys are loaded again from the Keychain, never asked for here.
    func startKeepAlive() {
        guard keepAliveTask == nil else { return }
        keepAliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                guard let self, self.store.pluginEnabled("ssh-terminal") else { continue }
                await self.heal()
            }
        }
    }
    func heal() async {
        if !loaded { await load() }
        let now = Int(Date.now.timeIntervalSince1970)
        let waiting = down.filter { $0.keepAlive && $0.retryAt <= now }
        guard !waiting.isEmpty else { return }
        for id in Set(waiting.map(\.host)) { if let host = host(id) { _ = await agentReady(host, interactive: false) } }
        struct Healed: Codable { var restarted: [SSHOverview.Down.Restarted] }
        if let _: Healed = try? await store.call(["method": "sshHeal"]) { await load() }
    }

    func copyCommand(_ host: SSHHost) async {
        do {
            let line: String = try await store.call(["method": "sshCommand", "id": host.id])
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(line, forType: .string)
            store.notify(L("ssh.commandCopied"))
        } catch { store.report(error) }
    }
}

extension SSHOverview.Down {
    struct Restarted: Codable, Sendable { var host: String; var forward: String }
}
