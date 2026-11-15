//! Clone, create and publish, and URLs without credentials. Only local bare repositories and
//! `example.invalid` addresses that are refused before any network access.
use super::repository;
use crate::git::remotes::{
    access_failure, clone, init_repository, publish, validate_clone_url, without_credentials,
};
use crate::git::runner::{error, git};
use crate::git::status::snapshot;
use std::path::Path;

#[test]
fn clone_urls_are_restricted_to_network_transports() {
    for ok in [
        "https://github.com/a/b.git",
        "ssh://git@bitbucket.org/a/b.git",
        "git@bitbucket.org:equipo/app.git",
    ] {
        assert!(validate_clone_url(ok).is_ok(), "{ok}");
    }
    for bad in [
        "",
        "-u evil",
        "ext::sh -c touch% /tmp/x",
        "file:///etc",
        "/tmp/repo",
        "https://x/a b",
        "git@host::x",
    ] {
        assert!(validate_clone_url(bad).is_err(), "{bad}");
    }
}

#[test]
fn urls_leave_without_credentials() {
    assert_eq!(
        without_credentials("https://user:s3cr3t@example.invalid/a/b.git"),
        "https://example.invalid/a/b.git"
    );
    assert_eq!(
        without_credentials("https://abcdef123456@bitbucket.org/a/b.git"),
        "https://bitbucket.org/a/b.git"
    );
    assert_eq!(
        without_credentials("ssh://git:pass@example.invalid/a.git"),
        "ssh://git@example.invalid/a.git"
    );
    for kept in [
        "git@bitbucket.org:a/b.git",
        "ssh://git@example.invalid/a.git",
        "https://example.invalid/a@b",
    ] {
        assert_eq!(without_credentials(kept), kept);
    }
}

#[tokio::test]
async fn snapshot_hides_a_token_in_the_remote() {
    let temp = repository().await;
    let root = temp.path();
    git(
        root,
        &[
            "remote",
            "add",
            "origin",
            "https://x-access-token:ghp_secretsecretsecret@example.invalid/a/b.git",
        ],
    )
    .await
    .unwrap();
    let state = snapshot(root).await.unwrap();
    assert_eq!(state.remote, "https://example.invalid/a/b.git");
    assert!(!serde_json::to_string(&state).unwrap().contains("secret"));
}

#[tokio::test]
async fn clone_refuses_existing_folders_and_bad_names() {
    let temp = repository().await;
    let parent = temp.path();
    std::fs::create_dir(parent.join("ya")).unwrap();
    assert_eq!(
        clone(parent, "https://example.invalid/x.git", "ya")
            .await
            .unwrap_err()
            .code,
        "path_exists"
    );
    assert_eq!(
        clone(parent, "https://example.invalid/x.git", "../fuera")
            .await
            .unwrap_err()
            .code,
        "invalid_path"
    );
    assert_eq!(
        clone(parent, "ext::sh", "x").await.unwrap_err().code,
        "invalid_url"
    );
}

#[tokio::test]
async fn init_and_publish_to_a_bare_remote() {
    let temp = repository().await;
    let parent = temp.path();
    let path = init_repository(parent, "nuevo", true).await.unwrap();
    let root = Path::new(&path);
    assert_eq!(
        git(root, &["branch", "--show-current"])
            .await
            .unwrap()
            .trim(),
        "develop"
    );
    assert_eq!(git(root, &["ls-files"]).await.unwrap().trim(), ".gitignore");
    assert!(init_repository(parent, "nuevo", true).await.is_err());
    assert!(init_repository(parent, "../fuera", true).await.is_err());
    // Publishing only accepts network transports.
    assert_eq!(
        publish(root, "/tmp/x.git", &["main".into()], false)
            .await
            .unwrap_err()
            .code,
        "invalid_url"
    );
    let denied = access_failure(error(
        "git_failed",
        "git@github.com: Permission denied (publickey).\nfatal: Could not read from remote repository.",
    ));
    assert_eq!(denied.code, "ssh_denied");
}

#[tokio::test]
async fn publish_keeps_another_origin_and_protected_main() {
    let temp = repository().await;
    let root = temp.path();
    git(
        root,
        &["remote", "add", "origin", "https://example.invalid/a.git"],
    )
    .await
    .unwrap();
    assert_eq!(
        publish(root, "https://example.invalid/b.git", &[], false)
            .await
            .unwrap_err()
            .code,
        "remote_exists"
    );
    git(root, &["branch", "main"]).await.unwrap();
    git(root, &["config", "butake.protectMain", "true"])
        .await
        .unwrap();
    assert_eq!(
        publish(
            root,
            "https://example.invalid/a.git",
            &["main".into()],
            false
        )
        .await
        .unwrap_err()
        .code,
        "protected_branch"
    );
}
