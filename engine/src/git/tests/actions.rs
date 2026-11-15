//! Typed actions and their guards: protection of the primary branch, confirmations, explicit push
//! destination, validated references, pulls classified for the assistant.
use super::{commit_file, repository, sandbox};
use crate::git::actions::{classify_pull_failure, execute, Action};
use crate::git::diff::diff;
use crate::git::protection::{main_protected, set_main_protection, set_remote_protection};
use crate::git::runner::git;
use crate::git::status::{parse_branches, snapshot, snapshot_with, stage_paths, status};
use std::time::Duration;

#[tokio::test]
async fn actual_git_lifecycle_and_protection() {
    let temp = tempfile::tempdir().unwrap();
    let root = temp.path();
    git(root, &["init", "-b", "develop"]).await.unwrap();
    std::fs::write(root.join("file.txt"), "hello\n").unwrap();
    execute(root, Action::Stage, "file.txt", false)
        .await
        .unwrap();
    assert_eq!(snapshot(root).await.unwrap().files[0].index, "A");
    execute(root, Action::Unstage, "file.txt", false)
        .await
        .unwrap();
    execute(root, Action::Stage, "file.txt", false)
        .await
        .unwrap();
    execute(root, Action::Commit, "feat(test): primer commit", false)
        .await
        .unwrap();
    assert_eq!(snapshot(root).await.unwrap().commits.len(), 1);
    execute(root, Action::CreateBranch, "main", false)
        .await
        .unwrap();
    // The hosting provider reports main as protected.
    set_remote_protection(root, "true").await.unwrap();
    assert_eq!(
        execute(root, Action::Push, "", true)
            .await
            .unwrap_err()
            .code,
        "protected_branch"
    );
    assert!(execute(root, Action::Commit, "blocked", false)
        .await
        .is_err());
    execute(root, Action::SwitchBranch, "develop", false)
        .await
        .unwrap();
    assert_eq!(
        execute(root, Action::Push, "", false)
            .await
            .unwrap_err()
            .code,
        "confirmation_required"
    );
    assert!(execute(root, Action::CreateBranch, "--evil", false)
        .await
        .is_err());
    assert!(diff(root, "../outside", false).await.is_err());
}

#[tokio::test]
async fn main_protection_follows_convention_and_explicit_config() {
    let temp = repository().await;
    let root = temp.path();
    git(root, &["switch", "-q", "-c", "main"]).await.unwrap();
    git(root, &["branch", "-D", "develop"]).await.unwrap();
    std::fs::write(root.join("a.txt"), "a\n").unwrap();
    execute(root, Action::Stage, "a.txt", false).await.unwrap();
    // Unknown rule: main is not blocked, even with a develop branch.
    assert!(!main_protected(root).await);
    execute(root, Action::Commit, "feat: trabajo en main", false)
        .await
        .unwrap();
    git(root, &["branch", "develop"]).await.unwrap();
    assert!(!main_protected(root).await);
    // The provider says main is protected.
    set_remote_protection(root, "true").await.unwrap();
    assert!(main_protected(root).await);
    std::fs::write(root.join("b.txt"), "b\n").unwrap();
    execute(root, Action::Stage, "b.txt", false).await.unwrap();
    assert_eq!(
        execute(root, Action::Commit, "bloqueado", false)
            .await
            .unwrap_err()
            .code,
        "protected_branch"
    );
    // Fast-forward pulls stay available on protected main (here they fail only for lack of upstream).
    assert_ne!(
        execute(root, Action::Pull, "", true)
            .await
            .unwrap_err()
            .code,
        "protected_branch"
    );
    assert_eq!(
        execute(root, Action::PullMerge, "", true)
            .await
            .unwrap_err()
            .code,
        "protected_branch"
    );
    set_main_protection(root, "false").await.unwrap();
    assert!(!snapshot(root).await.unwrap().main_protected);
    execute(root, Action::Commit, "feat: permitido por config", false)
        .await
        .unwrap();
    set_main_protection(root, "auto").await.unwrap();
    assert!(snapshot(root).await.unwrap().main_protected);
    set_remote_protection(root, "false").await.unwrap();
    assert!(!main_protected(root).await);
    set_main_protection(root, "true").await.unwrap();
    assert!(
        main_protected(root).await,
        "explicit choice wins over the provider"
    );
    set_remote_protection(root, "unknown").await.unwrap();
    assert!(set_remote_protection(root, "maybe").await.is_err());
    assert!(set_main_protection(root, "maybe").await.is_err());
}

#[tokio::test]
async fn pull_failures_are_classified_and_conflicts_detected() {
    let upstream = repository().await;
    let up = upstream.path();
    std::fs::write(up.join("shared.txt"), "base\n").unwrap();
    git(up, &["add", "."]).await.unwrap();
    git(up, &["commit", "-m", "base"]).await.unwrap();
    let clone = tempfile::tempdir().unwrap();
    let local = clone.path().join("local");
    git(
        clone.path(),
        &["clone", "-q", up.to_str().unwrap(), "local"],
    )
    .await
    .unwrap();
    git(&local, &["config", "user.name", "Test"]).await.unwrap();
    git(&local, &["config", "user.email", "test@example.invalid"])
        .await
        .unwrap();
    std::fs::write(up.join("shared.txt"), "remote\n").unwrap();
    git(up, &["commit", "-qam", "remote"]).await.unwrap();
    std::fs::write(local.join("shared.txt"), "local\n").unwrap();
    git(&local, &["commit", "-qam", "local"]).await.unwrap();
    assert_eq!(
        execute(&local, Action::Pull, "", false)
            .await
            .unwrap_err()
            .code,
        "confirmation_required"
    );
    assert_eq!(
        execute(&local, Action::Pull, "", true)
            .await
            .unwrap_err()
            .code,
        "pull_diverged"
    );
    assert_eq!(
        execute(&local, Action::PullMerge, "", true)
            .await
            .unwrap_err()
            .code,
        "pull_conflicts"
    );
    assert_eq!(snapshot(&local).await.unwrap().operation, "merge");
    assert_eq!(
        classify_pull_failure(
            "error: Your local changes to the following files would be overwritten by merge",
            false
        )
        .code,
        "pull_local_changes"
    );
    assert_eq!(
        classify_pull_failure("fatal: Could not read from remote repository.", false).code,
        "pull_remote_unreachable"
    );
}

#[tokio::test]
async fn discard_preserves_index_and_requires_confirmation() {
    let temp = repository().await;
    let root = temp.path();
    std::fs::write(root.join("tracked.txt"), "one\n").unwrap();
    git(root, &["add", "tracked.txt"]).await.unwrap();
    git(root, &["commit", "-m", "base"]).await.unwrap();
    std::fs::write(root.join("tracked.txt"), "two\n").unwrap();
    git(root, &["add", "tracked.txt"]).await.unwrap();
    std::fs::write(root.join("tracked.txt"), "three\n").unwrap();
    std::fs::write(root.join("new.txt"), "new\n").unwrap();
    assert_eq!(
        execute(root, Action::Discard, "tracked.txt", false)
            .await
            .unwrap_err()
            .code,
        "confirmation_required"
    );
    execute(root, Action::Discard, "tracked.txt", true)
        .await
        .unwrap();
    assert_eq!(
        std::fs::read_to_string(root.join("tracked.txt")).unwrap(),
        "two\n"
    );
    assert_eq!(
        execute(root, Action::Discard, "tracked.txt", true)
            .await
            .unwrap_err()
            .code,
        "nothing_to_discard"
    );
    execute(root, Action::Discard, "new.txt", true)
        .await
        .unwrap();
    assert!(!root.join("new.txt").exists());
    assert!(execute(root, Action::Discard, "../outside", true)
        .await
        .is_err());
    let limited = snapshot_with(root, 1, false).await.unwrap();
    assert_eq!(limited.commits.len(), 1);
    for i in 0..50 {
        std::fs::write(root.join(format!("bulk {i}.txt")), "x\n").unwrap();
    }
    let bulk: Vec<String> = (0..50).map(|i| format!("bulk {i}.txt")).collect();
    assert_eq!(stage_paths(root, &bulk, false).await.unwrap(), 50);
    let staged = snapshot_with(root, 10, true).await.unwrap();
    assert_eq!(staged.files.iter().filter(|f| f.index == "A").count(), 50);
    assert!(staged
        .stats
        .unwrap()
        .iter()
        .any(|s| s.staged && s.path == "bulk 7.txt" && s.additions == Some(1)));
    stage_paths(root, &bulk, true).await.unwrap();
    assert_eq!(
        snapshot(root)
            .await
            .unwrap()
            .files
            .iter()
            .filter(|f| f.index == "?")
            .count(),
        50
    );
    assert!(stage_paths(root, &["missing.txt".into()], false)
        .await
        .is_err());
    assert!(stage_paths(root, &["../x".into()], false).await.is_err());
}

#[tokio::test]
async fn rebase_conflict_is_visible_and_abort_recovers() {
    let temp = repository().await;
    let root = temp.path();
    execute(root, Action::CreateBranch, "feature/test", false)
        .await
        .unwrap();
    std::fs::write(root.join("base.txt"), "feature\n").unwrap();
    execute(root, Action::Stage, "base.txt", false)
        .await
        .unwrap();
    execute(root, Action::Commit, "feat(test): cambio feature", false)
        .await
        .unwrap();
    let before = git(root, &["rev-parse", "HEAD"]).await.unwrap();
    execute(root, Action::SwitchBranch, "develop", false)
        .await
        .unwrap();
    std::fs::write(root.join("base.txt"), "develop\n").unwrap();
    execute(root, Action::Stage, "base.txt", false)
        .await
        .unwrap();
    execute(root, Action::Commit, "feat(test): cambio develop", false)
        .await
        .unwrap();
    execute(root, Action::SwitchBranch, "feature/test", false)
        .await
        .unwrap();
    assert!(execute(root, Action::Rebase, "develop", true)
        .await
        .is_err());
    assert_eq!(snapshot(root).await.unwrap().operation, "rebase");
    execute(root, Action::RebaseAbort, "", true).await.unwrap();
    assert_eq!(git(root, &["rev-parse", "HEAD"]).await.unwrap(), before);
    assert!(snapshot(root).await.unwrap().operation.is_empty());
}

#[tokio::test]
async fn push_updates_only_current_branch() {
    let temp = repository().await;
    let root = temp.path();
    let remote = tempfile::tempdir().unwrap();
    git(remote.path(), &["init", "--bare"]).await.unwrap();
    git(
        root,
        &["remote", "add", "origin", remote.path().to_str().unwrap()],
    )
    .await
    .unwrap();
    // A hazardous push configuration must not turn a develop push into a main deploy.
    git(
        root,
        &["config", "remote.origin.push", "HEAD:refs/heads/main"],
    )
    .await
    .unwrap();
    execute(root, Action::Push, "", true).await.unwrap();
    assert!(git(
        remote.path(),
        &["show-ref", "--verify", "refs/heads/develop"]
    )
    .await
    .is_ok());
    assert!(
        git(remote.path(), &["show-ref", "--verify", "refs/heads/main"])
            .await
            .is_err()
    );
}

#[tokio::test]
async fn branch_lifecycle_track_rename_delete() {
    let temp = repository().await;
    let root = temp.path();
    std::fs::write(root.join("a.txt"), "a\n").unwrap();
    execute(root, Action::Stage, "a.txt", false).await.unwrap();
    execute(root, Action::Commit, "feat: base", false)
        .await
        .unwrap();
    git(root, &["branch", "master"]).await.unwrap();
    assert_eq!(crate::git::protection::primary_branch(root).await, "master");
    git(root, &["branch", "feature/x"]).await.unwrap();
    execute(root, Action::RenameBranch, "feature/x:feature/y", false)
        .await
        .unwrap();
    assert!(execute(root, Action::RenameBranch, "master:otra", false)
        .await
        .is_err());
    assert_eq!(
        execute(root, Action::DeleteBranch, "feature/y", false)
            .await
            .unwrap_err()
            .code,
        "confirmation_required"
    );
    execute(root, Action::DeleteBranch, "feature/y", true)
        .await
        .unwrap();
    assert_eq!(
        execute(root, Action::DeleteBranch, "master", true)
            .await
            .unwrap_err()
            .code,
        "protected_branch"
    );
    // A branch with unique commits needs the explicit force variant.
    git(root, &["switch", "-q", "-c", "solo"]).await.unwrap();
    std::fs::write(root.join("b.txt"), "b\n").unwrap();
    execute(root, Action::Stage, "b.txt", false).await.unwrap();
    execute(root, Action::Commit, "feat: solo", false)
        .await
        .unwrap();
    git(root, &["switch", "-q", "develop"]).await.unwrap();
    assert_eq!(
        execute(root, Action::DeleteBranch, "solo", true)
            .await
            .unwrap_err()
            .code,
        "branch_not_merged"
    );
    execute(root, Action::ForceDeleteBranch, "solo", true)
        .await
        .unwrap();
    let (local, _) = parse_branches(&git(root, &["for-each-ref", "--format=%(refname)%09%(HEAD)%09%(upstream:short)%09%(upstream:track,nobracket)%09%(committerdate:unix)", "refs/heads/"]).await.unwrap());
    assert!(!local
        .iter()
        .any(|b| b.name == "solo" || b.name == "feature/y"));
}

#[tokio::test]
async fn remote_actions_explain_a_missing_remote() {
    let temp = repository().await;
    let root = temp.path();
    assert!(snapshot(root).await.unwrap().remotes.is_empty());
    for action in [Action::Fetch, Action::Pull, Action::Push] {
        assert_eq!(
            execute(root, action, "", true).await.unwrap_err().code,
            "no_remote"
        );
    }
}

#[tokio::test]
async fn background_process_left_by_a_hook_does_not_stall_the_commit() {
    use std::os::unix::fs::PermissionsExt;
    let temp = sandbox().await;
    let root = temp.path();
    let hook = root.join(".git/hooks/post-commit");
    std::fs::write(&hook, "#!/bin/sh\nsleep 30 &\n").unwrap();
    std::fs::set_permissions(&hook, std::fs::Permissions::from_mode(0o755)).unwrap();
    std::fs::write(root.join("base.txt"), "changed\n").unwrap();
    git(root, &["add", "base.txt"]).await.unwrap();
    let started = std::time::Instant::now();
    execute(root, Action::Commit, "feat: with hook", false)
        .await
        .unwrap();
    assert!(started.elapsed() < Duration::from_secs(15));
    assert!(git(root, &["log", "-1", "--format=%s"])
        .await
        .unwrap()
        .contains("feat: with hook"));
}

#[tokio::test]
async fn unstage_works_before_the_first_commit_for_files_edited_after_add() {
    let temp = tempfile::tempdir().unwrap();
    let root = temp.path();
    git(root, &["init", "-q", "-b", "develop"]).await.unwrap();
    for file in ["one.txt", "dir/two.txt"] {
        std::fs::create_dir_all(root.join("dir")).unwrap();
        std::fs::write(root.join(file), "first\n").unwrap();
        git(root, &["add", file]).await.unwrap();
        std::fs::write(root.join(file), "edited after add\n").unwrap();
    }
    stage_paths(root, &["one.txt".into()], true).await.unwrap();
    execute(root, Action::Unstage, "dir/two.txt", false)
        .await
        .unwrap();
    let files = status(root).await.unwrap();
    assert!(files.iter().all(|f| f.index == "?"), "{files:?}");
    assert_eq!(
        std::fs::read_to_string(root.join("one.txt")).unwrap(),
        "edited after add\n"
    );
    // A file inside a new folder is found by the single-file action too.
    execute(root, Action::Stage, "dir/two.txt", false)
        .await
        .unwrap();
}

#[tokio::test]
async fn branch_names_cannot_be_reflog_shortcuts() {
    let temp = sandbox().await;
    let root = temp.path();
    git(root, &["branch", "main"]).await.unwrap();
    git(root, &["switch", "-q", "main"]).await.unwrap();
    git(root, &["switch", "-q", "develop"]).await.unwrap();
    assert_eq!(
        execute(root, Action::ForceDeleteBranch, "@{-1}", true)
            .await
            .unwrap_err()
            .code,
        "invalid_ref"
    );
    assert!(git(root, &["rev-parse", "--verify", "refs/heads/main"])
        .await
        .is_ok());
}

#[tokio::test]
async fn stash_and_cherry_pick_need_confirmation_and_work() {
    let temp = sandbox().await;
    let root = temp.path();
    git(root, &["branch", "other"]).await.unwrap();
    let picked = commit_file(root, "a.txt", "a\n", "feat: a").await;
    git(root, &["switch", "-q", "other"]).await.unwrap();
    assert_eq!(
        execute(root, Action::CherryPick, &picked, false)
            .await
            .unwrap_err()
            .code,
        "confirmation_required"
    );
    execute(root, Action::CherryPick, &picked, true)
        .await
        .unwrap();
    assert!(root.join("a.txt").exists());
    std::fs::write(root.join("wip.txt"), "wip\n").unwrap();
    execute(root, Action::Stash, "", false).await.unwrap();
    let left = status(root).await.unwrap();
    assert!(left.is_empty(), "{left:?}");
    execute(root, Action::StashPop, "", true).await.unwrap();
    assert!(root.join("wip.txt").exists());
    assert_eq!(
        execute(root, Action::Revert, "not-a-hash", true)
            .await
            .unwrap_err()
            .code,
        "invalid_ref"
    );
}
