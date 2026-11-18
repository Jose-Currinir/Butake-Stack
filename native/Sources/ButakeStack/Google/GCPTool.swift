import Foundation
import SwiftUI

/// The Google Cloud tool's state, shared by its list (content column), its card (detail) and the
/// «Google Cloud» row of a project. Everything goes through the engine, which only reads what
/// gcloud knows and never changes its active configuration.
@MainActor @Observable final class GCPTool {
    static let shared = GCPTool()

    /// How long the projects of an account are kept before asking gcloud again.
    static let projectsLifetime: TimeInterval = 600

    var state: GCPState?
    var loaded = false
    var loadFailed = false
    var selection: String?
    /// «Cerrar sesión…» waiting for its confirmation.
    var revoking: GCPAccount?
    /// The projects of each account, when they were read, and why the last read failed.
    var projects: [String: (read: Date, list: [GCPProject])] = [:]
    var projectErrors: [String: String] = [:]
    var loadingProjects: Set<String> = []
    @ObservationIgnored private var reads: [String: (id: UUID, task: Task<Void, Never>)] = [:]

    var accounts: [GCPAccount] { state?.accounts ?? [] }
    var selected: GCPAccount? { accounts.first { $0.account == selection } }
    var cliInstalled: Bool { state?.cli.installed ?? true }
    var cliPath: String? { state?.cli.path }
    func account(_ address: String) -> GCPAccount? { accounts.first { $0.account == address } }
    /// The Stack projects that use `account`.
    func uses(of account: String) -> [GCPProjectUse] { (state?.links ?? []).filter { $0.account == account } }

    private var store: StackStore { .shared }

    func load() async {
        do {
            let state: GCPState = try await store.call(["method": "gcpAccounts"])
            apply(state)
            loadFailed = false
        } catch {
            loadFailed = state == nil
            store.report(error)
        }
        loaded = true
    }

    private func apply(_ state: GCPState) {
        self.state = state
        if selection == nil || account(selection ?? "") == nil { selection = state.accounts.first?.account }
        // What is no longer on this Mac is not kept.
        let known = Set(state.accounts.map(\.account))
        projects = projects.filter { known.contains($0.key) }
    }

    /// The projects of `account`: from the last read when it is recent, else asked to gcloud.
    /// «Recargar» (`force`) always asks.
    func loadProjects(_ account: String, force: Bool = false) {
        if !force, let cached = projects[account], Date().timeIntervalSince(cached.read) < Self.projectsLifetime { return }
        guard !loadingProjects.contains(account) else { return }
        loadingProjects.insert(account)
        projectErrors[account] = nil
        let id = UUID()
        reads[account] = (id, Task { await read(account, run: id) })
    }

    private func read(_ account: String, run: UUID) async {
        defer {
            if reads[account]?.id == run { reads[account] = nil; loadingProjects.remove(account) }
        }
        do {
            let list: [GCPProject] = try await store.stoppableCall(["method": "gcpProjects", "account": account])
            projects[account] = (Date(), list)
        } catch where Self.cancelled(error) {
        } catch {
            projectErrors[account] = (error as? EngineFailure)?.errorDescription ?? L("error.gcp_failed")
        }
    }

    /// Leaving the tool (or the card) stops what is still being read.
    func cancelReads() {
        for read in reads.values { read.task.cancel() }
        reads = [:]
        loadingProjects = []
    }

    /// «Cerrar sesión…», confirmed: gcloud forgets the account on this Mac. The engine refuses the
    /// active account (closing it would change gcloud's configuration).
    func revoke(_ account: GCPAccount) async {
        await store.run(L("gcp.revoking")) {
            let state: GCPState = try await self.store.call(["method": "gcpRevoke", "account": account.account, "confirmed": true])
            self.projects[account.account] = nil
            self.apply(state)
            self.store.notify(String(format: L("gcp.revoked"), account.account))
        }
    }

    /// Links `project` to an account and a Google Cloud project (or unlinks it with nil). Its
    /// processes start again with the new variables.
    @discardableResult func link(_ project: Project, to link: GCPLink?) async -> Bool {
        var done = false
        await store.run(L("gcp.linking"), refresh: true) {
            var request: [String: Any] = ["method": link == nil ? "gcpUnlink" : "gcpLink", "id": project.id]
            if let link { request["account"] = link.account; request["project"] = link.project }
            let _: Project = try await self.store.call(request)
            done = true
        }
        guard done else { return false }
        if let state: GCPState = try? await store.call(["method": "gcpAccounts"]) { apply(state) }
        store.notify(L(link == nil ? "gcp.unlinked" : "gcp.linked"))
        return true
    }

    /// Links a project of several parts (or unlinks it with nil): its parts without a link of
    /// their own start again with it.
    @discardableResult func link(composite group: ProjectGroup, to link: GCPLink?) async -> Bool {
        var done = false
        await store.run(L("gcp.linking"), refresh: true) {
            var request: [String: Any] = ["method": link == nil ? "gcpUnlinkGroup" : "gcpLinkGroup", "id": group.id]
            if let link { request["account"] = link.account; request["project"] = link.project }
            let _: ProjectGroup = try await self.store.call(request)
            await self.store.refreshProjects()
            done = true
        }
        guard done else { return false }
        store.notify(L(link == nil ? "gcp.unlinked" : "gcp.linked"))
        return true
    }

    nonisolated static func cancelled(_ error: Error) -> Bool {
        error is CancellationError || (error as? EngineFailure)?.code == "gcp_cancelled"
    }
}
