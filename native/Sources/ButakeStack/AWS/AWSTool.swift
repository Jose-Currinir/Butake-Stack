import Foundation
import SwiftUI

/// The AWS tool's state, shared by its list (content column) and its card (detail). Every change
/// goes through the engine, which backs the file up and writes only the lines it changes.
@MainActor @Observable final class AWSTool {
    static let shared = AWSTool()

    enum Sheet: Identifiable, Hashable {
        case new
        case edit(AWSProfile)
        case duplicate(AWSProfile)
        case makeDefault(AWSProfile)
        var id: String {
            switch self {
            case .new: "new"
            case .edit(let p): "edit.\(p.name)"
            case .duplicate(let p): "duplicate.\(p.name)"
            case .makeDefault(let p): "default.\(p.name)"
            }
        }
    }

    var state: AWSState?
    var loaded = false
    var loadFailed = false
    var selection: String?
    var sheet: Sheet?
    var deleting: AWSProfile?
    var repairing: AWSProfile?
    var signingOut = false
    /// «Comprobar» results and errors, only for this run of the app.
    var identities: [String: AWSIdentity] = [:]
    var checkErrors: [String: String] = [:]
    var checking: Set<String> = []
    var signingIn: Set<String> = []
    /// When each wait for the browser started, and why the last one did not end in a session.
    var signInStarted: [String: Date] = [:]
    var signInErrors: [String: String] = [:]
    /// «Cerrar sesión» running (it ends every single sign-on session of the Mac).
    var endingSessions = false
    /// The runs of AWS CLI that wait (sign-in, «Comprobar», sign-out): cancelling one stops its
    /// engine and AWS CLI with it.
    @ObservationIgnored private var waits: [String: (id: UUID, task: Task<Void, Never>)] = [:]

    var profiles: [AWSProfile] { state?.profiles ?? [] }
    var selected: AWSProfile? { profiles.first { $0.name == selection } }
    var cliInstalled: Bool { state?.cli.installed ?? true }
    /// How long the engine waits for the browser before giving up.
    var signInLimit: TimeInterval { TimeInterval(state?.cli.signInLimit ?? 300) }
    func profile(_ name: String) -> AWSProfile? { profiles.first { $0.name == name } }

    private var store: StackStore { .shared }

    func load() async {
        do {
            let state: AWSState = try await store.call(["method": "awsProfiles"])
            apply(state)
            loadFailed = false
        } catch {
            loadFailed = state == nil
            store.report(error)
        }
        loaded = true
    }

    private func apply(_ state: AWSState) {
        self.state = state
        if selection == nil || profile(selection ?? "") == nil { selection = state.profiles.first?.name }
    }

    /// A change confirmed by the user: the engine answers with the whole list again.
    @discardableResult private func change(_ label: String, _ request: [String: Any]) async -> Bool {
        var done = false
        await store.run(label) {
            var request = request
            request["confirmed"] = true
            let state: AWSState = try await self.store.call(request)
            self.apply(state)
            done = true
        }
        return done
    }

    func create(_ draft: AWSDraft, keys: (id: String, secret: String)?, keychain: Bool) async -> Bool {
        var request: [String: Any] = ["method": "awsCreateProfile", "profile": draft.json, "storage": keychain ? "keychain" : "file"]
        if let keys { request["keys"] = ["accessKeyId": keys.id, "secretAccessKey": keys.secret] }
        guard await change(L("aws.saving"), request) else { return false }
        selection = draft.name
        store.notify(String(format: L("aws.created"), draft.name))
        return true
    }

    func update(_ original: AWSProfile, _ draft: AWSDraft) async -> Bool {
        guard await change(L("aws.saving"), ["method": "awsUpdateProfile", "name": original.name, "profile": draft.json]) else { return false }
        if draft.name != original.name {
            identities[draft.name] = identities.removeValue(forKey: original.name)
            selection = draft.name
        }
        return true
    }

    func duplicate(_ profile: AWSProfile, as name: String) async -> Bool {
        guard await change(L("aws.saving"), ["method": "awsDuplicateProfile", "name": profile.name, "newName": name]) else { return false }
        selection = name
        return true
    }

    func makeDefault(_ profile: AWSProfile, previous: String?) async -> Bool {
        var request: [String: Any] = ["method": "awsSetDefault", "name": profile.name]
        if let previous { request["previous"] = previous }
        guard await change(L("aws.saving"), request) else { return false }
        identities = [:]
        checkErrors = [:]
        selection = "default"
        return true
    }

    func delete(_ profile: AWSProfile) async {
        if await change(L("aws.deleting"), ["method": "awsDeleteProfile", "name": profile.name]) {
            identities[profile.name] = nil
            store.notify(String(format: L("aws.deleted"), profile.name))
        }
    }

    func repair(_ profile: AWSProfile) async {
        if await change(L("aws.saving"), ["method": "awsRepairHelper", "name": profile.name]) {
            store.notify(L("aws.repaired"))
        }
    }

    /// «Comprobar»: asks AWS who the profile is. Nothing is kept on disk.
    func startCheck(_ profile: AWSProfile) {
        let name = profile.name
        guard !checking.contains(name) else { return }
        checking.insert(name)
        let id = UUID()
        waits["check.\(name)"] = (id, Task { await check(name, run: id) })
    }

    func cancelCheck(_ name: String) {
        waits.removeValue(forKey: "check.\(name)")?.task.cancel()
        checking.remove(name)
    }

    private func check(_ name: String, run: UUID) async {
        defer { finish("check.\(name)", run) { self.checking.remove(name) } }
        do {
            let identity: AWSIdentity = try await store.stoppableCall(["method": "awsCheck", "name": name])
            identities[name] = identity
            checkErrors[name] = nil
        } catch where Self.cancelled(error) {
        } catch {
            identities[name] = nil
            checkErrors[name] = (error as? EngineFailure)?.errorDescription ?? L("error.aws_check_failed")
        }
    }

    /// «Iniciar sesión…» or «Renovar sesión…»: AWS CLI opens the browser and the engine waits for
    /// the user there, at most `signInLimit`. The row offers «Cancelar» meanwhile.
    func startSignIn(_ profile: AWSProfile) {
        let name = profile.name
        guard !signingIn.contains(name) else { return }
        signingIn.insert(name)
        signInStarted[name] = Date()
        signInErrors[name] = nil
        let id = UUID()
        waits["signIn.\(name)"] = (id, Task { await signIn(name, run: id) })
    }

    /// Stops the wait: the engine ends AWS CLI and the row is as it was.
    func cancelSignIn(_ name: String) {
        waits.removeValue(forKey: "signIn.\(name)")?.task.cancel()
        signingIn.remove(name)
        signInStarted[name] = nil
    }

    private func signIn(_ name: String, run: UUID) async {
        defer { finish("signIn.\(name)", run) { self.signingIn.remove(name); self.signInStarted[name] = nil } }
        do {
            let state: AWSState = try await store.stoppableCall(["method": "awsSsoLogin", "name": name])
            apply(state)
            checkErrors[name] = nil
        } catch where Self.cancelled(error) {
        } catch {
            signInErrors[name] = (error as? EngineFailure)?.errorDescription ?? L("error.aws_login_timeout")
        }
    }

    func startSignOut() {
        guard !endingSessions else { return }
        endingSessions = true
        let id = UUID()
        waits["signOut"] = (id, Task { await signOut(run: id) })
    }

    func cancelSignOut() {
        waits.removeValue(forKey: "signOut")?.task.cancel()
        endingSessions = false
    }

    private func signOut(run: UUID) async {
        defer { finish("signOut", run) { self.endingSessions = false } }
        do {
            let state: AWSState = try await store.stoppableCall(["method": "awsSsoLogout", "confirmed": true])
            apply(state)
            identities = identities.filter { name, _ in profile(name)?.kind != .sso }
        } catch where Self.cancelled(error) {
        } catch { store.report(error) }
    }

    /// Everything that waits on a profile stops (its card closed or another profile chosen).
    func cancelWaits(for name: String) {
        cancelSignIn(name)
        cancelCheck(name)
    }

    /// Leaving the tool stops every wait.
    func cancelAll() {
        for wait in waits.values { wait.task.cancel() }
        waits = [:]
        checking = []
        signingIn = []
        signInStarted = [:]
        endingSessions = false
    }

    /// A finished run clears its state; one already cancelled (or replaced by a newer run) does not.
    private func finish(_ key: String, _ run: UUID, _ clear: () -> Void) {
        guard waits[key]?.id == run else { return }
        waits[key] = nil
        clear()
    }

    nonisolated static func cancelled(_ error: Error) -> Bool {
        error is CancellationError || (error as? EngineFailure)?.code == "aws_cancelled"
    }
}
