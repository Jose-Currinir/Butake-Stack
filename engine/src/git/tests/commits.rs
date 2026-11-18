//! Correcting and taking back the last commit: only while it is on no remote branch, never on a
//! protected main, and without losing its changes.
use super::{commit_file, repository, sandbox};
use crate::git::actions::{Action, execute};
use crate::git::runner::git;
use crate::git::status::status;

#[tokio::test]
async fn amend_and_undo_only_touch_a_local_commit() {
    let temp = repository().await;
    let root = temp.path();
    // The first commit has no parent: it can be amended but not undone.
    assert_eq!(
        execute(root, Action::UndoCommit, "", false)
            .await
            .unwrap_err()
            .code,
        "commit_not_undoable"
    );
    std::fs::write(root.join("a.txt"), "a\n").unwrap();
    execute(root, Action::Stage, "a.txt", false).await.unwrap();
    execute(root, Action::Commit, "feat: a\n\nDetalle.", false)
        .await
        .unwrap();
    std::fs::write(root.join("b.txt"), "b\n").unwrap();
    execute(root, Action::Stage, "b.txt", false).await.unwrap();
    assert_eq!(
        execute(root, Action::CommitAmend, "  ", false)
            .await
            .unwrap_err()
            .code,
        "empty_message"
    );
    execute(root, Action::CommitAmend, "feat: a y b", false)
        .await
        .unwrap();
    let shown = git(root, &["show", "--name-only", "--format=%s", "HEAD"])
        .await
        .unwrap();
    assert!(shown.starts_with("feat: a y b"), "{shown}");
    assert!(
        shown.contains("a.txt") && shown.contains("b.txt"),
        "{shown}"
    );
    assert_eq!(
        git(root, &["rev-list", "--count", "HEAD"])
            .await
            .unwrap()
            .trim(),
        "2"
    );
    // Undo keeps the changes staged.
    execute(root, Action::UndoCommit, "", false).await.unwrap();
    assert_eq!(
        git(root, &["log", "-1", "--format=%s"])
            .await
            .unwrap()
            .trim(),
        "chore(test): base"
    );
    let staged = status(root).await.unwrap();
    assert!(staged.iter().any(|f| f.path == "a.txt" && f.index == "A"));
    assert!(staged.iter().any(|f| f.path == "b.txt" && f.index == "A"));
    // Once the commit is on a remote branch neither rewrites it.
    execute(root, Action::Commit, "feat: a y b", false)
        .await
        .unwrap();
    let remote = tempfile::tempdir().unwrap();
    git(remote.path(), &["init", "--bare"]).await.unwrap();
    git(
        root,
        &["remote", "add", "origin", remote.path().to_str().unwrap()],
    )
    .await
    .unwrap();
    execute(root, Action::Push, "", true).await.unwrap();
    for action in [Action::UndoCommit, Action::CommitAmend] {
        assert_eq!(
            execute(root, action, "feat: otro", false)
                .await
                .unwrap_err()
                .code,
            "commit_published"
        );
    }
}

#[tokio::test]
async fn undo_refuses_a_merge_commit() {
    let temp = sandbox().await;
    let root = temp.path();
    git(root, &["switch", "-q", "-c", "feature"]).await.unwrap();
    commit_file(root, "a.txt", "a\n", "feat: a").await;
    git(root, &["switch", "-q", "develop"]).await.unwrap();
    commit_file(root, "b.txt", "b\n", "feat: b").await;
    git(root, &["merge", "-q", "--no-edit", "feature"])
        .await
        .unwrap();
    assert_eq!(
        execute(root, Action::UndoCommit, "", false)
            .await
            .unwrap_err()
            .code,
        "commit_not_undoable"
    );
}

#[tokio::test]
async fn amend_and_undo_respect_a_protected_main() {
    let temp = sandbox().await;
    let root = temp.path();
    commit_file(root, "a.txt", "a\n", "feat: a").await;
    git(root, &["branch", "-m", "develop", "main"])
        .await
        .unwrap();
    git(root, &["config", "butake.protectMain", "true"])
        .await
        .unwrap();
    for action in [Action::UndoCommit, Action::CommitAmend] {
        assert_eq!(
            execute(root, action, "feat: b", false)
                .await
                .unwrap_err()
                .code,
            "protected_branch"
        );
    }
}
