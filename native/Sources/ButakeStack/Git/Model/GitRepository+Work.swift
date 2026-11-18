import SwiftUI

/// Every change to the repository goes through here, one at a time: an action of the engine with
/// its progress in the primary button, «Cancelar» for network transfers, the error translated, a
/// toast when it is done and a refresh afterwards.
///
/// ```swift
/// // A new action of a later wave (G-3, G-4):
/// await repository.perform(.revert, value: commit.hash)   // add the case to GitAction first
/// ```
extension GitRepository {
    /// Runs `action` and refreshes. Returns whether it worked; a failure is already on screen (an
    /// alert, or the pull assistant for a pull that needs a decision).
    @discardableResult
    func perform(_ action: GitAction, value: String = "", notify: Bool = true) async -> Bool {
        guard operation == nil else { return false }
        // Never on top of a checkbox still being applied.
        await chain?.value
        guard operation == nil else { return false }
        let current = GitOperation(title: action.progressTitle, cancellable: action.network)
        operation = current
        defer { if operation?.id == current.id { operation = nil } }
        var request: [String: Any] = ["method": "gitAction", "path": root, "action": action.rawValue, "value": value]
        if action.needsConfirmation { request["confirmed"] = true }
        // Over HTTPS with a connected provider, the account's token goes with this one transfer.
        if action.network { request = await GitHosting.shared.transfer(request, remote: snapshot.remote) }
        let result: Result<String, Error>
        if action.network {
            // Stoppable: «Cancelar» cancels this task, and the engine ends Git and its helpers.
            let store = self.store
            let task = Task { () -> Result<String, Error> in
                do { return .success(try await store.stoppableCall(request)) } catch { return .failure(error) }
            }
            stopRunning = { task.cancel() }
            result = await task.value
            stopRunning = nil
        } else {
            do { result = .success(try await store.call(request)) } catch { result = .failure(error) }
        }
        switch result {
        case .success:
            if action.network { lastFetch = Date() }
            if [.pull, .pullMerge, .pullRebase, .pullAutostash, .push].contains(action) { lastSyncFailure = nil }
            if notify { store.notify(action.doneTitle) }
            await refresh()
            return true
        case .failure(let error):
            let failure = GitFailure(error)
            await refresh()
            guard !failure.cancelled else { return false }
            if [.pull, .pullMerge, .pullRebase, .pullAutostash, .push, .fetch].contains(action) { lastSyncFailure = failure }
            if failure.needsPullAssistant { pullProblem = failure } else { self.failure = failure }
            return false
        }
    }

    /// «Cancelar» of the primary button: stops the network transfer.
    func cancel() { stopRunning?() }

    // MARK: Primary button

    /// Pushing a tracked primary branch straight asks first (`confirmingPushMain`).
    var pushNeedsConfirmation: Bool { snapshot.tracked && snapshot.branch == snapshot.primaryBranch }

    /// The one way to push from the interface: asks first when `pushNeedsConfirmation`, otherwise
    /// pushes. The dialog's «Subir de todos modos» calls `perform(.push)` itself.
    func push() async {
        if pushNeedsConfirmation { confirmingPushMain = true } else { await perform(.push) }
    }

    /// What the primary button does in its current state.
    func sync() async {
        switch syncState {
        case .running: return
        case .publishRepository: GitHosting.shared.publishing = true
        case .unfinished: GitTool.shared.tab = .problems
        case .publishBranch, .push: await push()
        case .pull(_, let thenPush):
            guard await perform(.pull, notify: thenPush == 0) else { return }
            if snapshot.ahead > 0 { await push() }
        case .fetch: await perform(.fetch)
        }
    }

    /// The assistant's choice for a pull that was not direct (the choice is the confirmation).
    func resolvePull(_ action: GitAction) async {
        pullProblem = nil
        guard await perform(action) else { return }
        if snapshot.ahead > 0, snapshot.behind == 0, snapshot.tracked { await push() }
    }

    // MARK: Changes

    /// Checkboxes: staging is quick and frequent, never shows progress and runs in order, so fast
    /// clicks queue instead of getting lost.
    func include(_ paths: [String], _ included: Bool) {
        guard !paths.isEmpty else { return }
        let previous = chain
        let store = self.store, root = self.root
        chain = Task { [weak self] in
            await previous?.value
            await self?.whenIdle()
            do {
                let _: Int = try await store.call(["method": "gitStagePaths", "path": root, "paths": paths, "staged": !included])
            } catch { self?.failure = GitFailure(error) }
            await self?.refresh(filesOnly: true)
        }
    }

    /// «Preparar bloque» (or, on the staged side, take it out) of the diff on screen.
    func stageHunk(_ index: Int) {
        guard let file else { return }
        var request: [String: Any] = ["method": "gitStageHunk", "path": root, "file": file.path, "staged": diffIsStaged, "index": index]
        if let header = hunkHeader(index) { request["expected"] = header }
        let previous = chain
        let store = self.store
        chain = Task { [weak self] in
            await previous?.value
            await self?.whenIdle()
            do { let _: String = try await store.call(request) } catch { self?.failure = GitFailure(error) }
            await self?.refresh(filesOnly: true)
        }
    }

    /// «Descartar cambios…», confirmed: each file goes back to its staged copy (or, untracked, away).
    func discard(_ targets: [GitFile]) async {
        let paths = targets.filter { !$0.conflicted }.map(\.path)
        guard !paths.isEmpty, operation == nil else { return }
        await chain?.value
        guard operation == nil else { return }
        let current = GitOperation(title: GitAction.discard.progressTitle, cancellable: false)
        operation = current
        defer { if operation?.id == current.id { operation = nil } }
        var failures: [String] = []
        for path in paths {
            do {
                let _: String = try await store.call(["method": "gitAction", "path": root, "action": "discard", "value": path, "confirmed": true])
            } catch { failures.append("\(path): \(GitFailure(error).detail)") }
        }
        await refresh()
        if failures.isEmpty {
            store.notify(String(format: L("git.done.discardCount"), paths.count))
        } else {
            failure = GitFailure(code: "git_failed", title: L("git.error.discard"), detail: failures.prefix(8).joined(separator: "\n"))
        }
    }

    /// «Confirmar en ‹rama›»: the summary, a blank line and the description; or the last commit
    /// corrected with what is included now.
    func commit(summary: String, description: String, amend: Bool) async -> Bool {
        let summary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let description = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty else { return false }
        let message = description.isEmpty ? summary : summary + "\n\n" + description
        return await perform(amend ? .commitAmend : .commit, value: message)
    }

    /// Whether «Deshacer el último commit» makes sense: there is a commit that is not on the remote.
    /// The engine has the last word (a commit already on any remote branch is refused).
    var canUndoCommit: Bool {
        guard snapshot.headCommit?.parents.count == 1, !snapshot.onProtectedMain, snapshot.operation.isEmpty else { return false }
        return !snapshot.tracked || snapshot.ahead > 0
    }
}
