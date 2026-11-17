//! The actions of Historial, Problemas and «Más…»: finishing or cancelling an operation left
//! halfway, branches and tags at a commit, saved changes, remotes, the identity and ignoring a file.
use super::{commit_file, sandbox};
use crate::git::actions::{Action, execute};
use crate::git::console::check_query;
use crate::git::editing::{conflict, resolve};
use crate::git::runner::git;
use crate::git::status::{operation, status};
use std::path::Path;

/// `develop` and `other` change `base.txt` differently; merging `other` stops on a conflict.
async fn merge_conflict(root: &Path) {
    git(root, &["branch", "other"]).await.unwrap();
    commit_file(root, "base.txt", "develop\n", "feat: develop").await;
    git(root, &["switch", "-q", "other"]).await.unwrap();
    commit_file(root, "base.txt", "other\n", "feat: other").await;
    git(root, &["switch", "-q", "develop"]).await.unwrap();
    assert!(execute(root, Action::Merge, "other", true).await.is_err());
    assert_eq!(operation(root).await.unwrap(), "merge");
}

#[tokio::test]
async fn an_operation_halfway_is_cancelled_or_finished_without_a_console() {
    let temp = sandbox().await;
    // Canonical, as the dispatch gives it: a resolution is written only inside it.
    let root = &temp.path().canonicalize().unwrap();
    assert_eq!(
        execute(root, Action::ContinueOperation, "", false)
            .await
            .unwrap_err()
            .code,
        "no_operation"
    );
    merge_conflict(root).await;
    let before = git(root, &["rev-parse", "HEAD"]).await.unwrap();
    // Cancelling asks first, and leaves the branch as it was.
    assert_eq!(
        execute(root, Action::AbortOperation, "", false)
            .await
            .unwrap_err()
            .code,
        "confirmation_required"
    );
    execute(root, Action::AbortOperation, "", true)
        .await
        .unwrap();
    assert!(operation(root).await.unwrap().is_empty());
    assert_eq!(git(root, &["rev-parse", "HEAD"]).await.unwrap(), before);

    // Again; continuing is refused while a file is in conflict, then finishes the merge.
    assert!(execute(root, Action::Merge, "other", true).await.is_err());
    assert_eq!(
        execute(root, Action::ContinueOperation, "", false)
            .await
            .unwrap_err()
            .code,
        "conflict"
    );
    let versions = conflict(root, "base.txt").await.unwrap();
    assert_eq!(versions.ours, "develop\n");
    assert_eq!(versions.theirs, "other\n");
    resolve(root, "base.txt", "develop\nother\n", &versions.working)
        .await
        .unwrap();
    execute(root, Action::ContinueOperation, "", false)
        .await
        .unwrap();
    assert!(operation(root).await.unwrap().is_empty());
    let parents = git(root, &["rev-list", "--parents", "-n", "1", "HEAD"])
        .await
        .unwrap();
    assert_eq!(parents.split_whitespace().count(), 3, "{parents}");
    assert!(status(root).await.unwrap().is_empty());
}

#[tokio::test]
async fn a_copy_of_commits_that_collides_is_continued() {
    let temp = sandbox().await;
    let root = &temp.path().canonicalize().unwrap();
    git(root, &["branch", "other"]).await.unwrap();
    let picked = commit_file(root, "base.txt", "develop\n", "feat: develop").await;
    git(root, &["switch", "-q", "other"]).await.unwrap();
    commit_file(root, "base.txt", "other\n", "feat: other").await;
    assert!(
        execute(root, Action::CherryPick, &picked, true)
            .await
            .is_err()
    );
    assert_eq!(operation(root).await.unwrap(), "cherry-pick");
    let versions = conflict(root, "base.txt").await.unwrap();
    resolve(root, "base.txt", "both\n", &versions.working)
        .await
        .unwrap();
    execute(root, Action::ContinueOperation, "", false)
        .await
        .unwrap();
    assert!(operation(root).await.unwrap().is_empty());
    let subject = git(root, &["log", "-1", "--format=%s"]).await.unwrap();
    assert_eq!(subject.trim(), "feat: develop");
}

#[tokio::test]
async fn branches_and_tags_start_at_a_commit() {
    let temp = sandbox().await;
    let root = temp.path();
    let first = git(root, &["rev-parse", "HEAD"])
        .await
        .unwrap()
        .trim()
        .to_string();
    commit_file(root, "a.txt", "a\n", "feat: a").await;
    execute(
        root,
        Action::CreateBranchAt,
        &format!("fix/old:{first}"),
        false,
    )
    .await
    .unwrap();
    // The current branch does not change.
    let current = git(root, &["symbolic-ref", "--short", "HEAD"])
        .await
        .unwrap();
    assert_eq!(current.trim(), "develop");
    let tip = git(root, &["rev-parse", "fix/old"]).await.unwrap();
    assert_eq!(tip.trim(), first);
    for wrong in ["-x:abc", "a b:abc", "ok:not-a-hash"] {
        assert_eq!(
            execute(root, Action::CreateBranchAt, wrong, false)
                .await
                .unwrap_err()
                .code,
            "invalid_ref",
            "{wrong}"
        );
    }

    execute(root, Action::CreateTag, &format!("v1.0:{first}"), false)
        .await
        .unwrap();
    execute(root, Action::CreateTag, "v1.1", false)
        .await
        .unwrap();
    let tags = git(root, &["tag", "--list"]).await.unwrap();
    assert_eq!(tags.lines().collect::<Vec<_>>(), ["v1.0", "v1.1"]);
    for wrong in ["-d", "a..b", "x@{1}", ""] {
        assert!(
            execute(root, Action::CreateTag, wrong, false)
                .await
                .is_err(),
            "{wrong}"
        );
    }
    assert_eq!(
        execute(root, Action::DeleteTag, "v1.0", false)
            .await
            .unwrap_err()
            .code,
        "confirmation_required"
    );
    execute(root, Action::DeleteTag, "v1.0", true)
        .await
        .unwrap();
    let tags = git(root, &["tag", "--list"]).await.unwrap();
    assert_eq!(tags.trim(), "v1.1");
}

#[tokio::test]
async fn saved_changes_are_applied_and_deleted_by_their_name() {
    let temp = sandbox().await;
    let root = temp.path();
    std::fs::write(root.join("wip.txt"), "wip\n").unwrap();
    execute(root, Action::Stash, "", false).await.unwrap();
    assert!(!root.join("wip.txt").exists());
    for wrong in ["stash@{x}", "HEAD", "stash@{0}; rm", "--all", "stash@{}"] {
        assert_eq!(
            execute(root, Action::StashApply, wrong, true)
                .await
                .unwrap_err()
                .code,
            "invalid_ref",
            "{wrong}"
        );
    }
    execute(root, Action::StashApply, "stash@{0}", true)
        .await
        .unwrap();
    assert!(root.join("wip.txt").exists());
    let list = git(root, &["stash", "list"]).await.unwrap();
    assert_eq!(list.lines().count(), 1);
    assert_eq!(
        execute(root, Action::StashDrop, "stash@{0}", false)
            .await
            .unwrap_err()
            .code,
        "confirmation_required"
    );
    execute(root, Action::StashDrop, "stash@{0}", true)
        .await
        .unwrap();
    assert!(git(root, &["stash", "list"]).await.unwrap().is_empty());
}

#[tokio::test]
async fn remotes_and_the_identity_are_set_from_the_tool() {
    let temp = sandbox().await;
    let root = temp.path();
    let bare = tempfile::tempdir().unwrap();
    git(bare.path(), &["init", "-q", "--bare"]).await.unwrap();
    let url = bare.path().display().to_string();
    execute(root, Action::AddRemote, &format!("backup\n{url}"), false)
        .await
        .unwrap();
    let remotes = git(root, &["remote"]).await.unwrap();
    assert_eq!(remotes.trim(), "backup");
    for wrong in [
        "a/b\nx",
        "-x\nurl",
        "ok\n-u",
        "ok\na b",
        "solo",
        // Other transports are not remotes Stack adds (R-105).
        "ok\nfile:///tmp/repo.git",
        "ok\nhttp://example.invalid/a.git",
        "ok\next::sh -c touch%20/tmp/x",
        "ok\n/carpeta/que/no/existe",
        "ok\nrelativa/repo.git",
    ] {
        assert!(
            execute(root, Action::AddRemote, wrong, false)
                .await
                .is_err(),
            "{wrong:?}"
        );
    }
    assert_eq!(
        execute(root, Action::RemoveRemote, "backup", false)
            .await
            .unwrap_err()
            .code,
        "confirmation_required"
    );
    execute(root, Action::RemoveRemote, "backup", true)
        .await
        .unwrap();
    assert!(git(root, &["remote"]).await.unwrap().trim().is_empty());

    execute(
        root,
        Action::SetIdentity,
        "Ana Pérez\nana@example.invalid",
        false,
    )
    .await
    .unwrap();
    let name = git(root, &["config", "--local", "user.name"])
        .await
        .unwrap();
    assert_eq!(name.trim(), "Ana Pérez");
    for wrong in ["\nana@example.invalid", "Ana\nana", "Ana\n@x", "Ana\na b@x"] {
        assert!(
            execute(root, Action::SetIdentity, wrong, false)
                .await
                .is_err(),
            "{wrong:?}"
        );
    }
}

#[tokio::test]
async fn a_file_is_ignored_and_leaves_the_index_only_if_it_was_new() {
    let temp = sandbox().await;
    let root = temp.path();
    std::fs::create_dir(root.join("data")).unwrap();
    std::fs::write(root.join("data/big file[1].bin"), "x").unwrap();
    git(root, &["add", "data/big file[1].bin"]).await.unwrap();
    execute(root, Action::IgnorePath, "data/big file[1].bin", false)
        .await
        .unwrap();
    // Twice: one line only.
    execute(root, Action::IgnorePath, "data/big file[1].bin", false)
        .await
        .unwrap();
    let ignore = std::fs::read_to_string(root.join(".gitignore")).unwrap();
    assert_eq!(ignore, "/data/big\\ file\\[1\\].bin\n");
    assert!(root.join("data/big file[1].bin").exists());
    let files = status(root).await.unwrap();
    assert_eq!(
        files.iter().map(|f| f.path.as_str()).collect::<Vec<_>>(),
        [".gitignore"],
        "the ignored file left the index and Git no longer lists it"
    );
    // A file already committed stays in the index (removing it would delete it from the branch).
    execute(root, Action::IgnorePath, "base.txt", false)
        .await
        .unwrap();
    let tracked = git(root, &["ls-files", "base.txt"]).await.unwrap();
    assert_eq!(tracked.trim(), "base.txt");
    for wrong in ["../x", "/etc/passwd", ".git/config", ""] {
        assert!(
            execute(root, Action::IgnorePath, wrong, false)
                .await
                .is_err(),
            "{wrong}"
        );
    }
}

#[test]
fn text_in_the_files_is_searched_without_leaving_the_repository() {
    let args = |line: &str| line.split(' ').map(String::from).collect::<Vec<_>>();
    for ok in [
        "grep -n -I -i --fixed-strings -e hola",
        "grep -n -e -f",
        "grep -n -e x -- src",
    ] {
        assert!(check_query(&args(ok)).is_ok(), "{ok}");
    }
    for refused in [
        "grep -O -e x",
        "grep -nO -e x",
        "grep --open-files-in-pager=vi -e x",
        "grep -f /etc/passwd",
        "grep --file=/etc/passwd",
        "grep --no-index -e x",
    ] {
        assert!(check_query(&args(refused)).is_err(), "{refused}");
    }
}

#[tokio::test]
async fn grep_finds_text_in_the_files() {
    let temp = sandbox().await;
    let root = temp.path();
    commit_file(root, "a:b.txt", "uno\nbuscar aquí\n", "feat: src").await;
    // As the app asks it: the path ends in NUL, so a ':' in a name never confuses the line number.
    let output = git(
        root,
        &[
            "grep",
            "-n",
            "-I",
            "-z",
            "--fixed-strings",
            "--ignore-case",
            "-e",
            "BUSCAR",
        ],
    )
    .await
    .unwrap();
    assert_eq!(output.trim(), "a:b.txt\x002\x00buscar aquí");
}

#[tokio::test]
async fn ignoring_a_file_keeps_a_gitignore_that_is_not_utf8() {
    let temp = sandbox().await;
    let root = temp.path();
    let original = b"# configuraci\xf3n\n*.log\n".to_vec();
    std::fs::write(root.join(".gitignore"), &original).unwrap();
    execute(root, Action::IgnorePath, "notas.txt", false)
        .await
        .unwrap();
    let after = std::fs::read(root.join(".gitignore")).unwrap();
    assert!(
        after.starts_with(&original),
        "the existing lines stay as they were"
    );
    assert!(after.ends_with(b"/notas.txt\n"));
}

#[tokio::test]
async fn a_remote_branch_is_deleted_only_through_a_remote_of_the_repository() {
    let temp = sandbox().await;
    let root = temp.path();
    git(
        root,
        &["remote", "add", "origin", "https://example.invalid/a.git"],
    )
    .await
    .unwrap();
    for wrong in ["https://example.invalid/a.git/feature", "otro/feature"] {
        assert_eq!(
            execute(root, Action::DeleteRemoteBranch, wrong, true)
                .await
                .unwrap_err()
                .code,
            "invalid_ref",
            "{wrong}"
        );
    }
    let failure = execute(
        root,
        Action::AddRemote,
        "web\nhttps://usuario:clave@example.invalid/a.git",
        false,
    )
    .await
    .unwrap_err();
    assert_eq!(failure.code, "invalid_url");
}

#[tokio::test]
async fn a_failed_commit_explains_itself_from_stdout() {
    let temp = sandbox().await;
    let failure = execute(temp.path(), Action::Commit, "sin cambios", false)
        .await
        .unwrap_err();
    assert_eq!(failure.code, "git_failed");
    assert!(!failure.detail.is_empty(), "Git wrote it to stdout");
}
