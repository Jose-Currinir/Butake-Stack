//! Tests of the Git tool, brought from Butake Git and adapted. Every repository is a temporary
//! folder made by the test, and every Git process runs with a private HOME and global
//! configuration, without system configuration or SSH agent (`runner::isolate`): nothing touches
//! the user's repositories, configuration, keys or the network.
mod actions;
mod commits;
mod console;
mod dispatch;
mod editing;
mod operations;
mod remotes;
mod rewrite;
mod status;
mod sync;
mod worktrees;

use super::actions::{execute, Action};
use super::runner::git;
use std::path::Path;
use tempfile::TempDir;

/// A repository on `develop` with one commit (`base.txt`), staged and committed through the tool.
pub(super) async fn repository() -> TempDir {
    let temp = tempfile::tempdir().unwrap();
    git(temp.path(), &["init", "-b", "develop"]).await.unwrap();
    git(temp.path(), &["config", "user.name", "Test"])
        .await
        .unwrap();
    git(
        temp.path(),
        &["config", "user.email", "test@example.invalid"],
    )
    .await
    .unwrap();
    std::fs::write(temp.path().join("base.txt"), "base\n").unwrap();
    execute(temp.path(), Action::Stage, "base.txt", false)
        .await
        .unwrap();
    execute(temp.path(), Action::Commit, "chore(test): base", false)
        .await
        .unwrap();
    temp
}

/// A repository on `develop` with one commit, made with Git directly.
pub(super) async fn sandbox() -> TempDir {
    let temp = tempfile::tempdir().unwrap();
    let root = temp.path();
    for args in [
        vec!["init", "-q", "-b", "develop"],
        vec!["config", "user.name", "Test"],
        vec!["config", "user.email", "t@example.invalid"],
    ] {
        git(root, &args).await.unwrap();
    }
    std::fs::write(root.join("base.txt"), "base\n").unwrap();
    git(root, &["add", "base.txt"]).await.unwrap();
    git(root, &["commit", "-qm", "chore: base"]).await.unwrap();
    temp
}

/// Writes, stages and commits one file; returns the new commit.
pub(super) async fn commit_file(root: &Path, file: &str, content: &str, message: &str) -> String {
    std::fs::write(root.join(file), content).unwrap();
    git(root, &["add", file]).await.unwrap();
    git(root, &["commit", "-qm", message]).await.unwrap();
    git(root, &["rev-parse", "HEAD"])
        .await
        .unwrap()
        .trim()
        .to_string()
}
