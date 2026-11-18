//! Comparing and synchronizing branches.
use super::{commit_file, repository, sandbox};
use crate::git::branches::{branch_details, branch_sync, copy_commits};
use crate::git::runner::git;
use crate::git::status::{snapshot, status};

#[tokio::test]
async fn branch_sync_detects_copies_and_copy_commits_returns_to_branch() {
    let temp = repository().await;
    let root = temp.path();
    git(root, &["branch", "main"]).await.unwrap();
    git(root, &["config", "butake.protectMain", "false"])
        .await
        .unwrap();
    for (file, message) in [
        ("a.txt", "feat: a"),
        ("b.txt", "feat: b"),
        ("c.txt", "feat: c"),
    ] {
        std::fs::write(root.join(file), format!("{file}\n")).unwrap();
        git(root, &["add", file]).await.unwrap();
        git(root, &["commit", "-qm", message]).await.unwrap();
    }
    let b = git(root, &["rev-parse", "HEAD~1"])
        .await
        .unwrap()
        .trim()
        .to_string();
    git(root, &["switch", "-q", "main"]).await.unwrap();
    git(root, &["cherry-pick", &b]).await.unwrap();
    git(root, &["switch", "-q", "develop"]).await.unwrap();
    let sync = branch_sync(root, "develop", "main").await.unwrap();
    assert_eq!(
        sync.only_left
            .iter()
            .map(|c| c.subject.as_str())
            .collect::<Vec<_>>(),
        ["feat: c", "feat: a"]
    );
    assert!(sync.only_right.is_empty());
    assert_eq!(sync.equivalent_left.len(), 1);
    assert_eq!(sync.equivalent_right.len(), 1);
    let hashes: Vec<String> = sync.only_left.iter().map(|c| c.hash.clone()).collect();
    assert_eq!(copy_commits(root, "main", &hashes).await.unwrap(), 2);
    assert_eq!(snapshot(root).await.unwrap().branch, "develop");
    let after = branch_sync(root, "develop", "main").await.unwrap();
    assert!(after.only_left.is_empty() && after.only_right.is_empty());
    let log = git(root, &["log", "-1", "--format=%B", "main"])
        .await
        .unwrap();
    assert!(log.contains("cherry picked from commit"));
    std::fs::write(root.join("dirty.txt"), "x\n").unwrap();
    assert_eq!(
        copy_commits(root, "main", &hashes).await.unwrap_err().code,
        "dirty_worktree"
    );
    assert!(branch_sync(root, "develop", "--evil").await.is_err());
}

#[tokio::test]
async fn copying_to_a_protected_main_is_refused() {
    let temp = sandbox().await;
    let root = temp.path();
    git(root, &["branch", "main"]).await.unwrap();
    let fresh = commit_file(root, "a.txt", "a\n", "feat: a").await;
    git(root, &["config", "butake.protectMain", "true"])
        .await
        .unwrap();
    assert_eq!(
        copy_commits(root, "main", &[fresh]).await.unwrap_err().code,
        "protected_branch"
    );
}

#[tokio::test]
async fn copy_commits_skips_applied_ones_and_returns_from_detached_head() {
    let temp = sandbox().await;
    let root = temp.path();
    git(root, &["branch", "other"]).await.unwrap();
    let applied = commit_file(root, "a.txt", "a\n", "feat: a").await;
    let fresh = commit_file(root, "b.txt", "b\n", "feat: b").await;
    // `other` already has the content of "feat: a".
    git(root, &["switch", "-q", "other"]).await.unwrap();
    commit_file(root, "a.txt", "a\n", "feat: a (copy)").await;
    git(root, &["switch", "-q", "--detach", "develop"])
        .await
        .unwrap();
    let head = git(root, &["rev-parse", "HEAD"]).await.unwrap();
    // Newest first, as the UI sends them.
    let copied = copy_commits(root, "other", &[fresh.clone(), applied.clone()])
        .await
        .unwrap();
    assert_eq!(copied, 1);
    assert_eq!(git(root, &["rev-parse", "HEAD"]).await.unwrap(), head);
    assert!(git(root, &["symbolic-ref", "-q", "HEAD"]).await.is_err());
    assert!(
        git(root, &["log", "-1", "--format=%s", "other"])
            .await
            .unwrap()
            .contains("feat: b")
    );
    // Nothing new at all: reported as such, and still back where it started.
    assert_eq!(
        copy_commits(root, "other", &[applied])
            .await
            .unwrap_err()
            .code,
        "copy_empty"
    );
    assert_eq!(git(root, &["rev-parse", "HEAD"]).await.unwrap(), head);
}

#[tokio::test]
async fn add_add_conflicts_are_reported_as_conflicts() {
    let temp = sandbox().await;
    let root = temp.path();
    git(root, &["branch", "other"]).await.unwrap();
    let theirs = commit_file(root, "new.txt", "from develop\n", "feat: new").await;
    git(root, &["switch", "-q", "other"]).await.unwrap();
    commit_file(root, "new.txt", "from other\n", "feat: new elsewhere").await;
    git(root, &["switch", "-q", "develop"]).await.unwrap();
    assert_eq!(
        copy_commits(root, "other", &[theirs])
            .await
            .unwrap_err()
            .code,
        "copy_conflicts"
    );
    assert!(status(root).await.unwrap().iter().any(|f| f.conflicted()));
}

async fn creator_repository() -> tempfile::TempDir {
    let temp = tempfile::tempdir().unwrap();
    let root = temp.path();
    for args in [
        vec!["init", "-b", "develop"],
        vec!["config", "user.name", "Test Creator"],
        vec!["config", "user.email", "test@example.invalid"],
    ] {
        git(root, &args).await.unwrap();
    }
    std::fs::write(root.join("file.txt"), "base\n").unwrap();
    git(root, &["add", "file.txt"]).await.unwrap();
    git(root, &["commit", "-m", "base"]).await.unwrap();
    git(root, &["branch", "main"]).await.unwrap();
    temp
}

#[tokio::test]
async fn branch_counts_creation_and_snapshot_diff_are_real() {
    let temp = creator_repository().await;
    let root = temp.path();
    git(root, &["switch", "-c", "feature/stats"]).await.unwrap();
    std::fs::write(root.join("file.txt"), "base\nfeature\n").unwrap();
    git(root, &["commit", "-am", "feature"]).await.unwrap();
    git(root, &["switch", "main"]).await.unwrap();
    std::fs::write(root.join("other.txt"), "main\n").unwrap();
    git(root, &["add", "other.txt"]).await.unwrap();
    git(root, &["commit", "-m", "base moved"]).await.unwrap();
    let details = branch_details(root, "feature/stats", "main").await.unwrap();
    assert_eq!(details["total"], 2);
    assert_eq!(details["ahead"], 1);
    assert_eq!(details["behind"], 1);
    assert_eq!(details["creation"]["actor"], "Test Creator");
    assert!(details["creation"]["timestamp"].as_i64().unwrap() > 0);
    assert_eq!(details["authors"][0]["count"], 1);
    assert_eq!(details["files"].as_array().unwrap().len(), 1);
    assert_eq!(details["files"][0]["additions"], 1);
    git(
        root,
        &[
            "reflog",
            "expire",
            "--expire=all",
            "refs/heads/feature/stats",
        ],
    )
    .await
    .unwrap();
    assert!(branch_details(root, "feature/stats", "main").await.unwrap()["creation"].is_null());
    assert!(branch_details(root, "--all", "main").await.is_err());
}

/// A pull request merged on the provider with «delete the branch»: «Actualizar» and «Bajar» stop
/// listing `origin/…`, the local branch reads as merged and goes without forcing; one with a
/// commit only on this Mac is kept.
#[tokio::test]
async fn a_merged_and_deleted_branch_is_pruned_and_goes_without_forcing() {
    use crate::git::actions::{Action, execute};
    let temp = repository().await;
    let root = temp.path();
    let remote = tempfile::tempdir().unwrap();
    let remote_path = remote.path().to_str().unwrap().to_string();
    git(remote.path(), &["init", "-q", "--bare"]).await.unwrap();
    git(root, &["remote", "add", "origin", &remote_path])
        .await
        .unwrap();
    for (name, file) in [
        ("feature/pagos", "pagos.txt"),
        ("feature/local", "local.txt"),
        ("feature/extra", "extra.txt"),
    ] {
        git(root, &["switch", "-q", "-c", name, "develop"])
            .await
            .unwrap();
        commit_file(root, file, "x\n", &format!("feat: {file}")).await;
    }
    git(root, &["switch", "-q", "develop"]).await.unwrap();
    git(
        root,
        &[
            "push",
            "-q",
            "-u",
            "origin",
            "develop",
            "feature/pagos",
            "feature/local",
            "feature/extra",
        ],
    )
    .await
    .unwrap();
    // A commit of feature/local that never reached the remote.
    git(root, &["switch", "-q", "feature/local"]).await.unwrap();
    commit_file(root, "solo.txt", "solo\n", "feat: solo aquí").await;
    git(root, &["switch", "-q", "develop"]).await.unwrap();

    // The provider merges feature/pagos into develop and deletes it; feature/local is deleted too.
    let provider = tempfile::tempdir().unwrap();
    let other = provider.path();
    git(other, &["clone", "-q", "-b", "develop", &remote_path, "."])
        .await
        .unwrap();
    git(
        other,
        &[
            "-c",
            "user.name=Proveedor",
            "-c",
            "user.email=pr@example.invalid",
            "merge",
            "-q",
            "--no-ff",
            "-m",
            "Merge pull request #7",
            "origin/feature/pagos",
        ],
    )
    .await
    .unwrap();
    git(other, &["push", "-q", "origin", "develop"])
        .await
        .unwrap();
    git(
        other,
        &[
            "push",
            "-q",
            "origin",
            "--delete",
            "feature/pagos",
            "feature/local",
        ],
    )
    .await
    .unwrap();

    execute(root, Action::Fetch, "", false).await.unwrap();
    let state = snapshot(root).await.unwrap();
    let branch = |name: &str| state.branches.iter().find(|b| b.name == name).unwrap();
    assert!(branch("feature/pagos").gone);
    assert!(branch("feature/pagos").merged);
    assert!(branch("feature/local").gone && !branch("feature/local").merged);
    assert!(!branch("feature/extra").gone && !branch("feature/extra").merged);
    assert!(
        !state
            .remote_branches
            .iter()
            .any(|b| b.short == "feature/pagos")
    );
    // Not merged into develop on this Mac yet: `-d` refuses, the merged variant does not.
    assert_eq!(
        execute(root, Action::DeleteBranch, "feature/pagos", true)
            .await
            .unwrap_err()
            .code,
        "branch_not_merged"
    );
    assert_eq!(
        execute(root, Action::DeleteMergedBranch, "feature/pagos", false)
            .await
            .unwrap_err()
            .code,
        "confirmation_required"
    );
    execute(root, Action::DeleteMergedBranch, "feature/pagos", true)
        .await
        .unwrap();
    assert_eq!(
        execute(root, Action::DeleteMergedBranch, "feature/local", true)
            .await
            .unwrap_err()
            .code,
        "branch_not_merged"
    );
    assert_eq!(
        execute(root, Action::DeleteMergedBranch, "develop", true)
            .await
            .unwrap_err()
            .code,
        "protected_branch"
    );

    // «Bajar» prunes too: feature/extra, deleted on the remote after the last «Actualizar».
    git(
        other,
        &["push", "-q", "origin", "--delete", "feature/extra"],
    )
    .await
    .unwrap();
    execute(root, Action::Pull, "", true).await.unwrap();
    let after = snapshot(root).await.unwrap();
    assert!(
        !after
            .remote_branches
            .iter()
            .any(|b| b.short == "feature/extra")
    );
    assert!(!after.branches.iter().any(|b| b.name == "feature/pagos"));
    assert!(
        after
            .branches
            .iter()
            .any(|b| b.name == "feature/local" && b.gone)
    );
}
