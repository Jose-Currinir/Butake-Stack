//! Reading a repository: status, line counts, branches, configuration, diffs and their limits.
use super::{repository, sandbox};
use crate::git::diff::{diff, diff_whole};
use crate::git::protection::{
    parse_repository_config, primary_branch, set_main_protection, set_remote_protection,
};
use crate::git::runner::{git, git_console};
use crate::git::status::{
    line_stats, parse_branches, parse_numstat_z, parse_status, snapshot, status,
};

#[test]
fn parses_special_paths_and_renames() {
    let files = parse_status(" M archivo con espacio\0R  nuevo\nanother\0anterior\0?? -opcion\0");
    assert_eq!(files.len(), 3);
    assert_eq!(files[1].original_path.as_deref(), Some("anterior"));
    assert_eq!(files[2].path, "-opcion");
}

#[test]
fn numstat_handles_renames_and_binary() {
    let parsed = parse_numstat_z(
        "3\t1\tsrc/a.rs\0-\t-\timg.png\x000\t0\t\0old/x.rs\0new/x.rs\0",
        true,
    );
    assert_eq!(parsed.len(), 3);
    assert_eq!(parsed[2].path, "new/x.rs");
    assert_eq!(parsed[1].additions, None);
    assert_eq!(parsed[0].additions, Some(3));
}

#[test]
fn repository_config_is_parsed_from_one_listing() {
    let config = parse_repository_config(
        "remote.origin.url git@github.com:a/b.git\nbutake.protectmain false\nremote.Mi.Fork.url https://x/y.git\nbutake.protectmain true\nbutake.remoteprotectmain false\n",
    );
    assert_eq!(config.protect_main, "true");
    assert_eq!(config.remote_protect_main, "false");
    assert_eq!(config.remotes, ["Mi.Fork", "origin"]);
    assert!(config.main_protected(), "explicit choice wins");
    assert!(!parse_repository_config("").main_protected());
}

#[test]
fn branches_are_split_into_local_and_remote() {
    let text = "refs/heads/develop\t*\torigin/develop\tahead 2, behind 1\t1700000000\nrefs/heads/old\t \torigin/old\tgone\t1600000000\nrefs/remotes/origin/HEAD\t \t\t\t1700000000\nrefs/remotes/origin/hotfix/fit_webfleet\t \t\t\t1700000500\n";
    let (local, remote) = parse_branches(text);
    assert_eq!(local.len(), 2);
    assert!(local[0].current);
    assert_eq!((local[0].ahead, local[0].behind), (2, 1));
    assert!(local[1].gone);
    assert_eq!(remote.len(), 1);
    assert_eq!(remote[0].short, "hotfix/fit_webfleet");
    assert_eq!(remote[0].remote, "origin");
}

#[tokio::test]
async fn untracked_files_get_line_counts() {
    let temp = repository().await;
    let root = temp.path();
    std::fs::write(root.join("nuevo.txt"), "a\nb\nc").unwrap();
    std::fs::write(root.join("bin.dat"), [0u8, 1, 2]).unwrap();
    let stats = line_stats(root).await;
    let new = stats.iter().find(|s| s.path == "nuevo.txt").unwrap();
    assert_eq!((new.additions, new.deletions), (Some(3), Some(0)));
    assert_eq!(
        stats
            .iter()
            .find(|s| s.path == "bin.dat")
            .unwrap()
            .additions,
        None
    );
}

#[tokio::test]
async fn snapshot_reads_config_remotes_and_primary_without_extra_calls() {
    let temp = repository().await;
    let root = temp.path();
    git(root, &["branch", "master"]).await.unwrap();
    git(
        root,
        &["remote", "add", "origin", "https://example.invalid/a/b.git"],
    )
    .await
    .unwrap();
    git(
        root,
        &[
            "remote",
            "add",
            "respaldo",
            "https://example.invalid/c/d.git",
        ],
    )
    .await
    .unwrap();
    set_remote_protection(root, "true").await.unwrap();
    let state = snapshot(root).await.unwrap();
    assert_eq!(state.primary_branch, "master");
    assert_eq!(state.primary_branch, primary_branch(root).await);
    assert_eq!(state.remotes, ["origin", "respaldo"]);
    assert_eq!(state.remote, "https://example.invalid/a/b.git");
    assert!(state.main_protected);
    assert_eq!(state.main_protection, "");
    assert_eq!(state.main_protection_remote, "true");
    set_main_protection(root, "false").await.unwrap();
    let state = snapshot(root).await.unwrap();
    assert!(!state.main_protected);
    assert_eq!(state.main_protection, "false");
    std::fs::write(root.join("nuevo.txt"), "x\n").unwrap();
    let files = status(root).await.unwrap();
    assert_eq!(files.len(), 1);
    assert_eq!(
        (files[0].path.as_str(), files[0].index.as_str()),
        ("nuevo.txt", "?")
    );
}

#[tokio::test]
async fn new_file_staged_then_edited_is_shown_whole() {
    let temp = tempfile::tempdir().unwrap();
    let root = temp.path();
    git(root, &["init", "-b", "develop"]).await.unwrap();
    // No commits yet: compared against the empty tree.
    std::fs::write(root.join("first.txt"), "one\n").unwrap();
    git(root, &["add", "first.txt"]).await.unwrap();
    assert!(diff_whole(root, "first.txt")
        .await
        .unwrap()
        .contains("+one"));
    git(root, &["commit", "-m", "base"]).await.unwrap();
    // Staged as a copy, edited afterwards (status AM).
    std::fs::write(root.join("copy.txt"), "old a\nold b\nsame\n").unwrap();
    git(root, &["add", "copy.txt"]).await.unwrap();
    std::fs::write(root.join("copy.txt"), "new a\nnew b\nsame\n").unwrap();
    let parts = diff(root, "copy.txt", false).await.unwrap();
    assert!(parts.contains("-old a") && parts.contains("+new a"));
    let whole = diff_whole(root, "copy.txt").await.unwrap();
    assert!(whole.contains("new file mode"));
    assert!(whole.contains("+new a") && whole.contains("+same"));
    assert!(!whole.contains("old a"));
    assert!(diff_whole(root, "../outside").await.is_err());
}

#[tokio::test]
async fn staged_rename_diff_reports_rename() {
    let temp = repository().await;
    let root = temp.path();
    git(root, &["mv", "base.txt", "moved.txt"]).await.unwrap();
    let text = diff(root, "moved.txt", true).await.unwrap();
    assert!(
        text.contains("rename from base.txt") && text.contains("rename to moved.txt"),
        "{text}"
    );
    assert!(!text.contains("new file mode"));
}

#[tokio::test]
async fn diff_keeps_prefixes_and_shows_other_encodings() {
    let temp = sandbox().await;
    let root = temp.path();
    git(root, &["config", "diff.noprefix", "true"])
        .await
        .unwrap();
    std::fs::write(root.join("latin.txt"), b"a\xf1o\n").unwrap();
    git(root, &["add", "latin.txt"]).await.unwrap();
    git(root, &["commit", "-qm", "latin"]).await.unwrap();
    std::fs::write(root.join("latin.txt"), b"a\xf1o nuevo\n").unwrap();
    let text = diff(root, "latin.txt", false).await.unwrap();
    assert!(text.contains("--- a/latin.txt") && text.contains("+++ b/latin.txt"));
    assert!(text.contains("nuevo"));
}

#[tokio::test]
async fn large_untracked_files_are_not_read_whole() {
    let temp = sandbox().await;
    let root = temp.path().canonicalize().unwrap();
    std::fs::write(root.join("big.txt"), "x".repeat(1_000_001)).unwrap();
    assert_eq!(
        diff(&root, "big.txt", false).await.unwrap(),
        "[Archivo mayor a 1 MB: vista previa omitida]"
    );
    std::fs::write(root.join("blob.bin"), [0xffu8, 0xfe, 0]).unwrap();
    assert_eq!(
        diff(&root, "blob.bin", false).await.unwrap(),
        "[Archivo binario]"
    );
}

#[tokio::test]
async fn console_runner_keeps_globs_and_returns_stderr() {
    let temp = sandbox().await;
    let root = temp.path();
    std::fs::write(root.join("one.rs"), "fn main() {}\n").unwrap();
    git_console(root, &["add", "*.rs"]).await.unwrap();
    assert_eq!(status(root).await.unwrap()[0].index, "A");
    let output = git_console(root, &["switch", "-c", "feature/console"])
        .await
        .unwrap();
    assert!(output.contains("feature/console"), "{output}");
}

#[tokio::test]
async fn tests_never_read_the_users_git_configuration() {
    let temp = sandbox().await;
    let root = temp.path();
    let global = git(root, &["config", "--global", "--list"]).await.unwrap();
    assert!(global.contains("user.name=stack test") || global.contains("user.name=Stack Test"));
    let origin = git(root, &["config", "--show-origin", "--get", "user.email"])
        .await
        .unwrap();
    // The repository's own value; the global one is the tests' private file.
    assert!(origin.contains(".git/config"), "{origin}");
    let home = git(root, &["config", "--global", "--show-origin", "--list"])
        .await
        .unwrap();
    assert!(home.contains(&*crate::git::runner::test_home().to_string_lossy()));
}
