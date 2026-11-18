//! Organizing unpublished commits, with a backup before each rewrite and «Deshacer».
use crate::git::rewrite::{RewritePlan, RewriteStep, apply, candidates, undo};
use crate::git::runner::git;
use crate::git::status::snapshot;

async fn repo() -> tempfile::TempDir {
    let temp = tempfile::tempdir().unwrap();
    let root = temp.path();
    for args in [
        vec!["init", "-q", "-b", "develop"],
        vec!["config", "user.name", "Test"],
        vec!["config", "user.email", "t@example.invalid"],
    ] {
        git(root, &args).await.unwrap();
    }
    for (file, message) in [
        ("base", "chore: base"),
        ("a", "feat: a"),
        ("b", "wip b"),
        ("c", "feat: c"),
        ("d", "feat: d"),
    ] {
        std::fs::write(root.join(file), format!("{file}\n")).unwrap();
        git(root, &["add", file]).await.unwrap();
        git(root, &["commit", "-qm", message]).await.unwrap();
    }
    temp
}

#[tokio::test]
async fn squash_reword_reorder_drop_and_undo() {
    let temp = repo().await;
    let root = temp.path();
    let found = candidates(root).await.unwrap();
    assert_eq!(found.boundary, "root");
    let subjects: Vec<_> = found.commits.iter().map(|c| c.subject.as_str()).collect();
    assert_eq!(subjects, ["feat: a", "wip b", "feat: c", "feat: d"]);
    let h: Vec<String> = found.commits.iter().map(|c| c.hash.clone()).collect();
    let plan = RewritePlan {
        head: found.head.clone(),
        base: found.base.clone(),
        steps: vec![
            RewriteStep {
                hashes: vec![h[0].clone(), h[1].clone()],
                drop: false,
                message: Some("feat: a y b\n\ndetalle".into()),
            },
            RewriteStep {
                hashes: vec![h[3].clone()],
                drop: false,
                message: None,
            },
            RewriteStep {
                hashes: vec![h[2].clone()],
                drop: true,
                message: None,
            },
        ],
    };
    let result = apply(root, &plan).await.unwrap();
    // The backup is taken before the rewrite and points at the old head.
    assert!(result.backup.starts_with("refs/butake/backup/develop/"));
    assert_eq!(
        git(root, &["rev-parse", &result.backup])
            .await
            .unwrap()
            .trim(),
        found.head
    );
    let log = git(root, &["log", "--format=%s", "-3"]).await.unwrap();
    assert_eq!(
        log.lines().collect::<Vec<_>>(),
        ["feat: d", "feat: a y b", "chore: base"]
    );
    assert!(!root.join("c").exists());
    assert!(root.join("b").exists());
    // Backups never show up in the history of the app.
    assert!(
        !snapshot(root)
            .await
            .unwrap()
            .commits
            .iter()
            .any(|c| c.refs.contains("butake"))
    );
    undo(root, &result.backup).await.unwrap();
    assert_eq!(
        git(root, &["rev-parse", "HEAD"]).await.unwrap().trim(),
        found.head
    );
    assert!(undo(root, "refs/heads/develop").await.is_err());
    assert!(
        undo(root, "refs/butake/backup/develop/../../heads/x")
            .await
            .is_err()
    );
}

#[tokio::test]
async fn rejects_stale_incomplete_dirty_and_protected_plans() {
    let temp = repo().await;
    let root = temp.path();
    let found = candidates(root).await.unwrap();
    let one = RewritePlan {
        head: found.head.clone(),
        base: found.base.clone(),
        steps: vec![RewriteStep {
            hashes: vec![found.commits[0].hash.clone()],
            drop: false,
            message: None,
        }],
    };
    assert_eq!(apply(root, &one).await.unwrap_err().code, "invalid_plan");
    let stale = RewritePlan {
        head: "0".repeat(40),
        base: found.base.clone(),
        steps: vec![],
    };
    assert_eq!(apply(root, &stale).await.unwrap_err().code, "stale_plan");
    git(root, &["branch", "-m", "develop", "main"])
        .await
        .unwrap();
    git(root, &["config", "butake.protectMain", "true"])
        .await
        .unwrap();
    assert_eq!(
        apply(root, &one).await.unwrap_err().code,
        "protected_branch"
    );
    git(root, &["config", "butake.protectMain", "false"])
        .await
        .unwrap();
    std::fs::write(root.join("dirty"), "x").unwrap();
    assert_eq!(apply(root, &one).await.unwrap_err().code, "dirty_rewrite");
}

#[tokio::test]
async fn published_commits_are_not_candidates_without_an_upstream() {
    let temp = repo().await;
    let root = temp.path();
    let remote = tempfile::tempdir().unwrap();
    git(remote.path(), &["init", "-q", "--bare"]).await.unwrap();
    git(
        root,
        &["remote", "add", "origin", &remote.path().to_string_lossy()],
    )
    .await
    .unwrap();
    git(root, &["push", "-q", "origin", "develop"])
        .await
        .unwrap();
    git(root, &["config", "log.showSignature", "true"])
        .await
        .unwrap();
    git(root, &["switch", "-q", "-c", "feature/x"])
        .await
        .unwrap();
    std::fs::write(root.join("mine"), "mine\n").unwrap();
    git(root, &["add", "mine"]).await.unwrap();
    git(root, &["commit", "-qm", "feat: mine"]).await.unwrap();
    let found = candidates(root).await.unwrap();
    let subjects: Vec<_> = found.commits.iter().map(|c| c.subject.as_str()).collect();
    assert_eq!(subjects, ["feat: mine"]);
    assert_eq!(found.boundary, "upstream");
}

#[tokio::test]
async fn new_messages_survive_a_conflict_and_undo_keeps_later_commits() {
    let temp = repo().await;
    let root = temp.path();
    for (content, message) in [("one\n", "feat: one"), ("two\n", "feat: two")] {
        std::fs::write(root.join("shared"), content).unwrap();
        git(root, &["add", "shared"]).await.unwrap();
        git(root, &["commit", "-qm", message]).await.unwrap();
    }
    std::fs::write(root.join("last"), "last\n").unwrap();
    git(root, &["add", "last"]).await.unwrap();
    git(root, &["commit", "-qm", "wip last"]).await.unwrap();
    let found = candidates(root).await.unwrap();
    let hash = |subject: &str| {
        found
            .commits
            .iter()
            .find(|c| c.subject == subject)
            .unwrap()
            .hash
            .clone()
    };
    let keep = |subject: &str, message: Option<&str>| RewriteStep {
        hashes: vec![hash(subject)],
        drop: false,
        message: message.map(String::from),
    };
    let mut steps: Vec<RewriteStep> = found
        .commits
        .iter()
        .filter(|c| !["feat: one", "feat: two", "wip last"].contains(&c.subject.as_str()))
        .map(|c| keep(&c.subject, None))
        .collect();
    // "two" before "one": both rewrite the same line, so the rebase stops on a conflict.
    steps.push(keep("feat: two", None));
    steps.push(keep("feat: one", None));
    steps.push(keep("wip last", Some("feat: last, reworded")));
    let plan = RewritePlan {
        head: found.head.clone(),
        base: found.base.clone(),
        steps,
    };
    let failure = apply(root, &plan).await.unwrap_err();
    assert_eq!(failure.code, "rewrite_conflicts");
    let backup = failure
        .detail
        .rsplit("Respaldo: ")
        .next()
        .unwrap()
        .to_string();
    // The app reads the backup from the detail: it survives the cleaning of details.
    assert!(crate::git::public_detail(&failure.detail).ends_with(&backup));
    for _ in 0..4 {
        if snapshot(root).await.unwrap().operation.is_empty() {
            break;
        }
        std::fs::write(root.join("shared"), "resolved\n").unwrap();
        git(root, &["add", "shared"]).await.unwrap();
        let _ = git(root, &["rebase", "--continue"]).await;
    }
    assert!(snapshot(root).await.unwrap().operation.is_empty());
    assert_eq!(
        git(root, &["log", "-1", "--format=%s"])
            .await
            .unwrap()
            .trim(),
        "feat: last, reworded"
    );
    // A commit made after the rewrite stays reachable from a second backup when undoing.
    std::fs::write(root.join("after"), "after\n").unwrap();
    git(root, &["add", "after"]).await.unwrap();
    git(root, &["commit", "-qm", "feat: after"]).await.unwrap();
    let later = git(root, &["rev-parse", "HEAD"]).await.unwrap();
    undo(root, &backup).await.unwrap();
    assert_eq!(
        git(root, &["rev-parse", "HEAD"]).await.unwrap().trim(),
        found.head
    );
    let refs = git(
        root,
        &[
            "for-each-ref",
            "--format=%(objectname)",
            "refs/butake/backup/develop/",
        ],
    )
    .await
    .unwrap();
    assert!(refs.contains(later.trim()));
}
