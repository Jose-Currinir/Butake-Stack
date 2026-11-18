import AppKit
import Foundation

/// A project's fixed public address on a domain of the user's own (P-35).
struct FixedAddress: Decodable, Sendable, Hashable {
    let hostname: String
    let zone: String
    /// Two or more levels under the zone: Cloudflare's universal certificate does not cover it.
    let advancedCertificate: Bool
    var url: URL? { URL(string: "https://\(hostname)") }
    /// What to add as an authorized JavaScript origin in a Google OAuth client (and similar).
    var origin: String { "https://\(hostname)" }
}

/// `tunnelStatus`: whether `cloudflared` is there, the connection with Cloudflare (only whether it
/// exists), the last zone used and each project's fixed address. Never a credential.
struct TunnelState: Decodable, Sendable, Hashable {
    let installed: Bool
    let connected: Bool
    /// Where the connection lives, to explain how to revoke it.
    let certificate: String
    let zone: String?
    let addresses: [String: FixedAddress]
}

/// The daemon's side: whether the connection is being made, and the fixed addresses shared now.
struct PublicStatus: Decodable, Sendable, Hashable {
    struct Share: Decodable, Sendable, Hashable {
        let id: String
        let hostname: String?
        /// Cloudflare accepted the tunnel: the address answers.
        let ready: Bool
    }
    let login: Bool
    let shares: [Share]
}

/// A DNS record Stack cannot delete: the name it was for and its zone.
struct LeftoverRecord: Identifiable, Hashable {
    let hostname: String
    let zone: String
    var id: String { hostname }
    /// The zone's DNS records in Cloudflare's dashboard.
    var dashboard: URL? { URL(string: "https://dash.cloudflare.com/?to=/:account/\(zone)/dns/records") }
}

/// What the engine answers after configuring, changing or removing a fixed address.
struct TunnelChange: Decodable, Sendable {
    let hostname: String
    /// The name the tunnel had before a change (its DNS record stays).
    let previous: String?
    let zone: String?
    /// Projects that name this one with `{public:<id>}`: their `.env` was written again or marked
    /// out of date.
    let portDependents: [PortDependent]?
    /// The record Stack could not delete: the previous name after a change, the name after removing.
    func leftover(removed: Bool) -> LeftoverRecord? {
        guard let zone, let name = removed ? hostname : previous else { return nil }
        return LeftoverRecord(hostname: name, zone: zone)
    }
}

extension StackStore {
    /// Shared on the internet, temporarily or on its fixed address: the sidebar marks it.
    func isPublic(_ project: Project) -> Bool {
        share(project) != nil || publicShare(project) != nil
    }
    func publicShare(_ project: Project) -> PublicStatus.Share? {
        status?.public?.shares.first { $0.id == project.id }
    }
    var connectingCloudflare: Bool { status?.public?.login == true }

    func tunnelState() async -> TunnelState? {
        try? await call(["method": "tunnelStatus"])
    }
    /// `cloudflared tunnel login` in the daemon: the browser opens and the user authorizes a zone.
    func connectCloudflare(_ on: Bool) async {
        await run(on ? L("share.fixed.busy.connect") : L("share.fixed.busy.cancel")) {
            let _: Bool = try await self.call(["method": "tunnelConnect", "on": on])
        }
        await refreshStatus()
    }
    /// Creates the tunnel and its DNS record (`zone` given), or points the tunnel at a new name.
    /// Nil when it failed (the error is shown and the sheet stays open).
    func saveFixedAddress(_ project: Project, hostname: String, zone: String?) async -> TunnelChange? {
        var done: TunnelChange?
        await run(L("share.fixed.busy.configure")) {
            var request: [String: Any] = ["method": zone == nil ? "tunnelChange" : "tunnelConfigure", "id": project.id,
                                          "hostname": hostname, "actor": self.actor]
            if let zone { request["zone"] = zone }
            done = try await self.call(request)
        }
        await followAddressChange(done)
        return done
    }
    /// Deletes the tunnel and its credentials in this Mac; the DNS record stays (returned to say so).
    func removeFixedAddress(_ project: Project) async -> TunnelChange? {
        var done: TunnelChange?
        await run(L("share.fixed.busy.remove")) {
            done = try await self.call(["method": "tunnelRemove", "id": project.id, "confirmed": true, "actor": self.actor])
        }
        await followAddressChange(done)
        return done
    }
    /// The projects that name the address read their environments again; the ones whose processes
    /// run are told to restart them (never done without asking).
    private func followAddressChange(_ change: TunnelChange?) async {
        await refreshStatus()
        let dependents = change?.portDependents ?? []
        for dependent in dependents { await loadEnvs(dependent.id) }
        let live = dependents.compactMap { d in projects.first { $0.id == d.id } }.filter { !liveProcessIDs($0).isEmpty }
        if !live.isEmpty { notify(String(format: L("share.fixed.dependents"), live.map(\.title).joined(separator: ", "))) }
    }
    func setFixedShared(_ project: Project, _ on: Bool) async {
        await run(on ? L("share.busy.start") : L("share.busy.stop")) {
            let _: Bool = try await self.call(["method": "tunnelShare", "id": project.id, "on": on, "confirmed": on])
        }
        await refreshStatus()
    }
    /// The credentials page of Google Cloud, in the project's own Google project when it has one.
    static func googleCredentialsURL(project: String?) -> URL? {
        var parts = URLComponents(string: "https://console.cloud.google.com/apis/credentials")
        if let project, !project.isEmpty { parts?.queryItems = [URLQueryItem(name: "project", value: project)] }
        return parts?.url
    }
    func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        notify(L("share.copied"))
    }
}
