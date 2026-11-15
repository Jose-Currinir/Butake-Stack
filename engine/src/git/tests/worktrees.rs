//! Other working folders («Más…» › Carpetas de trabajo): added on a new or an existing branch,
//! refused where they would overwrite or nest, and taken out only when asked and clean.
use super::sandbox;
use crate::git::actions::{execute, Action};
use crate::git::runner::git;

#[tokio::test]
async fn a_worktree_is_added_on_a_new_or_existing_branch_and_removed_when_confirmed() {
    let temp = sandbox().await;
    let root = &temp.path().canonicalize().unwrap();
    let outside = tempfile::tempdir().unwrap();
    let place = outside.path().canonicalize().unwrap();

    // A new branch, from the current commit.
    let first = place.join("feature-a");
    let value = format!("{}\nfeature/a", first.display());
    execute(root, Action::AddWorktree, &value, false)
        .await
        .unwrap();
    assert!(first.join("base.txt").exists());
    assert_eq!(
        git(&first, &["branch", "--show-current"])
            .await
            .unwrap()
            .trim(),
        "feature/a"
    );

    // An existing branch.
    git(root, &["branch", "fix"]).await.unwrap();
    let second = place.join("fix");
    execute(
        root,
        Action::AddWorktree,
        &format!("{}\nfix", second.display()),
        false,
    )
    .await
    .unwrap();
    assert!(second.join("base.txt").exists());

    // A branch already open in another folder is refused in plain words.
    let third = place.join("again");
    let failure = execute(
        root,
        Action::AddWorktree,
        &format!("{}\nfix", third.display()),
        false,
    )
    .await
    .unwrap_err();
    assert_eq!(failure.code, "branch_in_use");
    assert!(!third.exists());

    // Taking one out asks first; with changes it is refused, and nothing is lost.
    let path = second.to_string_lossy().to_string();
    assert_eq!(
        execute(root, Action::RemoveWorktree, &path, false)
            .await
            .unwrap_err()
            .code,
        "confirmation_required"
    );
    std::fs::write(second.join("base.txt"), "changed\n").unwrap();
    assert_eq!(
        execute(root, Action::RemoveWorktree, &path, true)
            .await
            .unwrap_err()
            .code,
        "worktree_dirty"
    );
    assert!(second.join("base.txt").exists());
    git(&second, &["checkout", "--", "base.txt"]).await.unwrap();
    execute(root, Action::RemoveWorktree, &path, true)
        .await
        .unwrap();
    assert!(!second.exists());
    // Its branch stays in the repository.
    git(root, &["show-ref", "--verify", "refs/heads/fix"])
        .await
        .unwrap();
}

#[tokio::test]
async fn a_worktree_never_overwrites_nests_or_removes_the_main_folder() {
    let temp = sandbox().await;
    let root = &temp.path().canonicalize().unwrap();
    let outside = tempfile::tempdir().unwrap();
    let place = outside.path().canonicalize().unwrap();

    let taken = place.join("taken");
    std::fs::create_dir(&taken).unwrap();
    let cases = [
        (format!("{}\nnew", taken.display()), "path_exists"),
        (
            format!("{}\nnew", root.join("inside").display()),
            "invalid_path",
        ),
        ("relative/folder\nnew".to_string(), "invalid_path"),
        (
            format!("{}/../escape\nnew", place.display()),
            "invalid_path",
        ),
        (
            format!("{}\nnew", place.join("missing/child").display()),
            "invalid_path",
        ),
        (
            format!("{}\n-x", place.join("dash").display()),
            "invalid_ref",
        ),
        (
            place.join("no-branch").display().to_string(),
            "invalid_arguments",
        ),
    ];
    for (value, code) in cases {
        assert_eq!(
            execute(root, Action::AddWorktree, &value, false)
                .await
                .unwrap_err()
                .code,
            code,
            "{value}"
        );
    }
    assert_eq!(
        execute(root, Action::RemoveWorktree, &root.to_string_lossy(), true)
            .await
            .unwrap_err()
            .code,
        "main_worktree"
    );
    assert_eq!(
        execute(root, Action::RemoveWorktree, &taken.to_string_lossy(), true)
            .await
            .unwrap_err()
            .code,
        "invalid_path"
    );
    assert!(taken.exists());
}
