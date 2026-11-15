//! Staging one block, resolving conflicts and the file viewer.
use crate::git::actions::{execute, Action};
use crate::git::diff::diff;
use crate::git::editing::{conflict, resolve, stage_hunk};
use crate::git::files::read_file;
use crate::git::runner::{git, git_bytes};
use crate::git::status::status;

async fn lines_repository() -> tempfile::TempDir {
    let temp = tempfile::tempdir().unwrap();
    let root = temp.path();
    git(root, &["init", "-b", "develop"]).await.unwrap();
    git(root, &["config", "user.name", "Test"]).await.unwrap();
    git(root, &["config", "user.email", "test@example.invalid"])
        .await
        .unwrap();
    let text = (0..40).map(|n| format!("line {n}\n")).collect::<String>();
    std::fs::write(root.join("file.txt"), text).unwrap();
    execute(root, Action::Stage, "file.txt", false)
        .await
        .unwrap();
    execute(root, Action::Commit, "chore(test): base", false)
        .await
        .unwrap();
    temp
}

#[tokio::test]
async fn stage_and_unstage_one_hunk_only() {
    let temp = lines_repository().await;
    let root = temp.path();
    let text = std::fs::read_to_string(root.join("file.txt"))
        .unwrap()
        .replace("line 2\n", "change first\n")
        .replace("line 36\n", "change second\n");
    std::fs::write(root.join("file.txt"), text).unwrap();
    stage_hunk(root, "file.txt", false, 0, None).await.unwrap();
    let staged = diff(root, "file.txt", true).await.unwrap();
    assert!(staged.contains("+change first"));
    assert!(!staged.contains("+change second"));
    stage_hunk(root, "file.txt", true, 0, None).await.unwrap();
    assert!(diff(root, "file.txt", true).await.unwrap().is_empty());
    assert!(stage_hunk(root, "file.txt", false, 8, None).await.is_err());
}

#[tokio::test]
async fn hunk_staging_survives_noprefix_other_encodings_and_checks_the_expected_block() {
    let temp = lines_repository().await;
    let root = temp.path();
    git(root, &["config", "diff.noprefix", "true"])
        .await
        .unwrap();
    git(root, &["config", "apply.whitespace", "fix"])
        .await
        .unwrap();
    std::fs::create_dir_all(root.join("src")).unwrap();
    let base: Vec<u8> = (0..40)
        .flat_map(|n| {
            format!("l\u{ed}nea {n}\n")
                .chars()
                .map(|c| c as u8)
                .collect::<Vec<_>>()
        })
        .collect();
    for file in ["src/a.txt", "a.txt"] {
        std::fs::write(root.join(file), &base).unwrap();
        git(root, &["add", file]).await.unwrap();
    }
    git(root, &["commit", "-qm", "latin"]).await.unwrap();
    let mut edited = b"primero   \n".to_vec();
    edited.extend_from_slice(&base);
    edited.extend_from_slice(b"ultimo\n");
    std::fs::write(root.join("src/a.txt"), &edited).unwrap();
    // A block that is not the one on screen is refused.
    assert_eq!(
        stage_hunk(root, "src/a.txt", false, 0, Some("@@ -9,9 +9,9 @@"))
            .await
            .unwrap_err()
            .code,
        "invalid_hunk"
    );
    let shown = diff(root, "src/a.txt", false).await.unwrap();
    let header = shown.lines().find(|l| l.starts_with("@@ ")).unwrap();
    stage_hunk(root, "src/a.txt", false, 0, Some(header))
        .await
        .unwrap();
    let files = status(root).await.unwrap();
    assert_eq!(files.len(), 1, "{files:?}");
    assert_eq!(files[0].path, "src/a.txt");
    assert_eq!(
        (files[0].index.as_str(), files[0].worktree.as_str()),
        ("M", "M")
    );
    // Trailing whitespace is staged as written, and the Latin-1 bytes are intact.
    let staged = git_bytes(root, &["show", ":src/a.txt"]).await.unwrap();
    let mut expected = b"primero   \n".to_vec();
    expected.extend_from_slice(&base);
    assert_eq!(staged, expected);
}

#[tokio::test]
async fn unstaging_one_hunk_of_a_staged_rename_keeps_the_rename() {
    let temp = lines_repository().await;
    let root = temp.path();
    let text = std::fs::read_to_string(root.join("file.txt"))
        .unwrap()
        .replace("line 2\n", "change first\n")
        .replace("line 36\n", "change second\n");
    git(root, &["mv", "file.txt", "moved.txt"]).await.unwrap();
    std::fs::write(root.join("moved.txt"), text).unwrap();
    git(root, &["add", "moved.txt"]).await.unwrap();
    stage_hunk(root, "moved.txt", true, 0, None).await.unwrap();
    let files = status(root).await.unwrap();
    assert_eq!(files.len(), 1, "{files:?}");
    assert_eq!(files[0].index, "R");
    assert_eq!(files[0].original_path.as_deref(), Some("file.txt"));
    let staged = git(root, &["show", ":moved.txt"]).await.unwrap();
    assert!(staged.contains("line 2\n") && staged.contains("change second"));
}

#[tokio::test]
async fn resolution_accepts_setext_headings_but_not_real_markers() {
    let temp = lines_repository().await;
    let root = temp.path().canonicalize().unwrap();
    git(&root, &["switch", "-q", "-c", "other"]).await.unwrap();
    std::fs::write(root.join("file.txt"), "theirs\n").unwrap();
    git(&root, &["commit", "-qam", "theirs"]).await.unwrap();
    git(&root, &["switch", "-q", "develop"]).await.unwrap();
    std::fs::write(root.join("file.txt"), "ours\n").unwrap();
    git(&root, &["commit", "-qam", "ours"]).await.unwrap();
    assert!(git(&root, &["merge", "other"]).await.is_err());
    let loaded = conflict(&root, "file.txt").await.unwrap();
    assert_eq!(
        resolve(&root, "file.txt", "<<<<<<< ours\nx\n", &loaded.working)
            .await
            .unwrap_err()
            .code,
        "conflict_markers"
    );
    // The file changed after it was loaded: refused.
    assert_eq!(
        resolve(&root, "file.txt", "x\n", "otro contenido")
            .await
            .unwrap_err()
            .code,
        "stale_conflict"
    );
    resolve(&root, "file.txt", "Title\n=======\nbody\n", &loaded.working)
        .await
        .unwrap();
    assert_eq!(status(&root).await.unwrap()[0].index, "M");
    assert_eq!(
        conflict(&root, "file.txt").await.unwrap_err().code,
        "stale_conflict"
    );
}

async fn editor_repository() -> tempfile::TempDir {
    let temp = tempfile::tempdir().unwrap();
    let root = temp.path();
    for args in [
        vec!["init", "-b", "develop"],
        vec!["config", "user.name", "Test"],
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
async fn viewer_rejects_metadata_symlinks_binary_and_large_files() {
    let temp = editor_repository().await;
    let root = temp.path().canonicalize().unwrap();
    assert!(read_file(&root, ".git/config").await.is_err());
    assert!(read_file(&root, "../file.txt").await.is_err());
    std::os::unix::fs::symlink(root.join("file.txt"), root.join("link.txt")).unwrap();
    assert!(read_file(&root, "link.txt").await.is_err());
    std::fs::write(root.join("binary"), [0, 1, 2]).unwrap();
    assert!(read_file(&root, "binary").await.is_err());
    std::fs::write(root.join("large.txt"), "x".repeat(2_000_001)).unwrap();
    assert_eq!(
        read_file(&root, "large.txt").await.unwrap_err().code,
        "large_file"
    );
    // A file it can read says the branch and HEAD it was read at.
    let read = read_file(&root, "file.txt").await.unwrap();
    assert_eq!(read["content"], "base\n");
    assert_eq!(read["branch"], "develop");
    assert_eq!(read["head"].as_str().unwrap().len(), 40);
}
