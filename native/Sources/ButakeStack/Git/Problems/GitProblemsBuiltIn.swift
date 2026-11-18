import Foundation

/// The problems Git itself can tell (DISENO.md, «Problemas»): conflicts, an operation halfway, a
/// branch that diverged, is not on the remote or lost its remote, a missing identity, Git missing
/// or too old, the remote out of reach, the last pull or push that failed, files too big and the
/// protected primary branch. Each one says what happens, why, and has the button that solves it.
@MainActor enum GitProblemsBuiltIn {
    static func problems(_ repository: GitRepository) -> [GitProblem] {
        let snapshot = repository.snapshot
        let work = GitWork.shared
        var list: [GitProblem] = []
        if let requirement = requirement() { list.append(requirement) }
        let operation = snapshot.operation
        let operationName = operation.isEmpty ? "" : L("git.operation.\(operation)")
        let abort = GitProblemAction(title: L("git.problems.abortEllipsis"), symbol: Symbols.gitAbort, id: "abort", destructive: true) {
            work.aborting = true
        }

        // Conflicts, then the operation they stopped.
        let conflicts = repository.conflicts
        if !conflicts.isEmpty {
            list.append(GitProblem(
                id: "git.conflicts", severity: .error,
                title: String(format: L("git.problems.conflicts"), conflicts.count),
                reason: operation.isEmpty ? L("git.problems.conflictsReasonStash")
                    : String(format: L("git.problems.conflictsReason"), operationName),
                symbol: Symbols.warning,
                action: GitProblemAction(title: L("git.problems.resolveEllipsis"), symbol: Symbols.gitResolve, id: "resolve") { work.resolving = true },
                secondary: operation.isEmpty ? nil : abort,
                items: conflicts.map(\.path)))
        } else if !operation.isEmpty {
            list.append(GitProblem(
                id: "git.unfinished", severity: .error,
                title: String(format: L("git.problems.unfinished"), operationName),
                reason: L("git.problems.unfinishedReason"),
                symbol: Symbols.gitContinue,
                action: GitProblemAction(title: L("git.problems.continue"), symbol: Symbols.gitContinue, id: "continue") {
                    await repository.continueOperation()
                },
                secondary: abort))
        }

        if repository.checks.identityMissing {
            list.append(GitProblem(
                id: "git.identity", severity: .error, title: L("git.problems.identity"), reason: L("git.problems.identityReason"),
                symbol: Symbols.user,
                action: GitProblemAction(title: L("git.problems.identityAction"), symbol: Symbols.user, id: "identity") { work.identity = true }))
        }

        list += remote(repository)

        let large = repository.checks.largeFiles
        if !large.isEmpty {
            list.append(GitProblem(
                id: "git.largeFiles", severity: .warning,
                title: String(format: L("git.problems.largeFiles"), large.count),
                reason: String(format: L("git.problems.largeFilesReason"), Int(GitProblemChecks.largeFileLimit / 1_048_576)),
                symbol: Symbols.largeDiff,
                action: GitProblemAction(title: L("git.problems.ignoreEllipsis"), symbol: Symbols.hide, id: "ignore") { work.ignoring = large },
                items: large))
        }

        if snapshot.onProtectedMain && (!repository.files.isEmpty || snapshot.ahead > 0) {
            list.append(GitProblem(
                id: "git.protectedMain", severity: .warning,
                title: String(format: L("git.problems.protectedMain"), snapshot.primaryBranch),
                reason: L("git.problems.protectedMainReason"),
                symbol: Symbols.locked,
                action: GitProblemAction(title: L("git.problems.newBranchEllipsis"), symbol: Symbols.gitNewBranch, id: "newBranch") {
                    GitTool.shared.creatingBranch = true
                }))
        }
        return list
    }

    /// Git missing or older than the tool needs (the page shows it too; here it has its button).
    private static func requirement() -> GitProblem? {
        let tool = GitTool.shared
        let outdated: String? = if case .outdated(let version) = tool.requirement { version } else { nil }
        guard tool.requirement == .missing || outdated != nil else { return nil }
        return GitProblem(
            id: "git.requirement", severity: .error,
            title: L(outdated == nil ? "git.requirement.missing" : "git.requirement.outdated"),
            reason: outdated.map { String(format: L("git.requirement.outdatedDetail"), $0, GitRequirement.minimum.map(String.init).joined(separator: ".")) }
                ?? L("git.requirement.missingDetail"),
            symbol: Symbols.utilities,
            action: GitProblemAction(title: L("git.requirement.openUtilities"), symbol: Symbols.utilities, id: "utilities") {
                StackStore.shared.route = UtilityCatalog.route(for: "git")
            })
    }

    /// The branch against its remote, and the last pull or push.
    private static func remote(_ repository: GitRepository) -> [GitProblem] {
        let snapshot = repository.snapshot
        var list: [GitProblem] = []
        let failure = repository.lastSyncFailure
        let unreachable = failure.map(isUnreachable) ?? false
        if let failure, unreachable {
            list.append(GitProblem(
                id: "git.remoteAccess", severity: .error, title: L("git.problems.remoteAccess"),
                reason: failure.detail.isEmpty ? failure.title : failure.detail,
                symbol: Symbols.gitOffline,
                action: GitProblemAction(title: L("git.problems.retry"), symbol: Symbols.reload, id: "retryFetch") {
                    // Reaching the remote again solves it (a failed push or pull is retried by its own button).
                    if await repository.perform(.fetch), repository.lastSyncFailure.map(isUnreachable) == true { repository.lastSyncFailure = nil }
                }))
        }
        let branch = snapshot.currentBranch
        let diverged = snapshot.tracked && snapshot.ahead > 0 && snapshot.behind > 0
        if diverged {
            list.append(GitProblem(
                id: "git.diverged", severity: .warning, title: L("git.problems.diverged"),
                reason: String(format: L("git.problems.divergedReason"), snapshot.ahead, snapshot.behind),
                symbol: Symbols.gitDiverged,
                action: GitProblemAction(title: L("git.problems.divergedAction"), symbol: Symbols.gitPull, id: "pullAssistant") {
                    repository.pullProblem = GitFailure(code: "pull_diverged", title: L("git.error.pull_diverged"),
                                                        detail: String(format: L("git.problems.divergedReason"), snapshot.ahead, snapshot.behind))
                }))
        }
        if let branch, snapshot.hasRemote, !snapshot.detached, snapshot.operation.isEmpty {
            let landing = repository.landingBranch
            let publishAgain = GitProblemAction(title: L("git.problems.publishAgain"), symbol: Symbols.gitPush, id: "publish") {
                await repository.perform(.push)
            }
            if branch.mergedAndGone && landing != branch.name {
                // Its pull request was merged and its remote branch deleted: what is left is going back.
                let clean = repository.files.isEmpty
                list.append(GitProblem(
                    id: "git.upstreamGone", severity: .note, title: String(format: L("git.problems.merged"), branch.name),
                    reason: String(format: L(clean ? "git.problems.mergedReason" : "git.problems.mergedDirtyReason"), landing),
                    symbol: Symbols.gitMerge,
                    action: clean ? GitProblemAction(title: String(format: L("git.problems.leaveMerged"), landing), symbol: Symbols.gitMerge,
                                                     id: "leaveMerged") { await repository.leaveMergedBranch() } : nil,
                    secondary: publishAgain))
            } else if branch.gone {
                list.append(GitProblem(
                    id: "git.upstreamGone", severity: .warning, title: L("git.problems.upstreamGone"),
                    reason: String(format: L("git.problems.upstreamGoneReason"), branch.upstream),
                    symbol: Symbols.gitNotPublished,
                    action: publishAgain))
            } else if branch.upstream.isEmpty {
                list.append(GitProblem(
                    id: "git.notPublished", severity: .note, title: L("git.problems.notPublished"),
                    reason: L("git.problems.notPublishedReason"),
                    symbol: Symbols.gitNotPublished,
                    action: GitProblemAction(title: L("git.sync.publishBranch"), symbol: Symbols.gitPush, id: "publish") {
                        await repository.perform(.push)
                    }))
            }
        }
        // Other branches whose pull request was merged on the provider: only this Mac still has them.
        let merged = repository.mergedGoneBranches
        if snapshot.operation.isEmpty, let first = merged.first {
            list.append(GitProblem(
                id: "git.mergedBranches", severity: .note,
                title: merged.count == 1 ? String(format: L("git.problems.mergedBranchOne"), first.name)
                    : String(format: L("git.problems.mergedBranches"), merged.count),
                reason: L("git.problems.mergedBranchesReason"),
                symbol: Symbols.gitMerge,
                action: GitProblemAction(title: L("git.problems.deleteMerged"), symbol: Symbols.delete, id: "deleteMerged") {
                    await repository.deleteMergedBranches()
                },
                items: merged.map(\.name)))
        }
        // The last pull or push that failed for another reason (the ones above already say it).
        if let failure, !unreachable, !(diverged && failure.code == "pull_diverged"), failure.code != "pull_conflicts" || repository.conflicts.isEmpty {
            let localChanges = failure.code == "pull_local_changes"
            list.append(GitProblem(
                id: "git.lastSync", severity: .warning, title: String(format: L("git.problems.lastSync"), failure.title),
                reason: failure.detail.isEmpty ? L("git.problems.lastSyncReason") : failure.detail,
                symbol: Symbols.warning,
                action: GitProblemAction(title: L(localChanges ? "git.pull.autostash" : "git.problems.retry"),
                                         symbol: localChanges ? Symbols.gitStash : Symbols.reload, id: "retrySync") {
                    if localChanges { await repository.resolvePull(.pullAutostash) } else { await repository.sync() }
                }))
        }
        return list
    }

    /// A failure of reaching the remote: offline, refused credentials, a wrong address, time out.
    static func isUnreachable(_ failure: GitFailure) -> Bool {
        ["pull_remote_unreachable", "ssh_denied", "https_denied", "timeout", "clone_auth", "clone_not_found", "token_rejected", "token_forbidden", "clone_offline"].contains(failure.code)
            || [L("git.message.offline"), L("git.message.remoteAccess"), L("git.message.sshKey"), L("git.message.authentication"),
                L("git.message.remoteNotFound"), L("git.message.timeout")].contains(failure.detail)
    }
}
