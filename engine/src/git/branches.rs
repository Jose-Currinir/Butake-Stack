//! Comparing branches: details of one branch against a base, the diff of one file between two
//! commits, and «Sincronizar ramas» (what each side lacks, by content, and copying commits).
use super::actions::{validate_branch, validate_commit};
use super::protection::{main_protected, primary_branch};
use super::runner::{error, git, Result};
use super::status::{has_conflicts, snapshot, Commit};
use serde::Serialize;
use serde_json::{json, Value};
use std::{
    collections::{BTreeMap, HashSet},
    path::Path,
};

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BranchSync {
    pub left: String,
    pub right: String,
    pub only_left: Vec<Commit>,
    pub only_right: Vec<Commit>,
    pub equivalent_left: Vec<Commit>,
    pub equivalent_right: Vec<Commit>,
    pub merge_base: Option<String>,
}

/// Compares two branches by patch content (`--cherry-mark`): a commit copied with cherry-pick
/// counts as present on both sides even though its hash differs.
pub async fn branch_sync(root: &Path, left: &str, right: &str) -> Result<BranchSync> {
    for name in [left, right] {
        if name.is_empty() || name.starts_with('-') {
            return Err(error(
                "invalid_ref",
                "Nombre inválido: usa letras, números, guiones o barras, sin espacios.",
            ));
        }
        git(
            root,
            &[
                "rev-parse",
                "--verify",
                "--quiet",
                &format!("{name}^{{commit}}"),
            ],
        )
        .await
        .map_err(|_| error("invalid_ref", format!("No existe la rama {name}.")))?;
    }
    let range = format!("{left}...{right}");
    let log_args = [
        "log",
        "--left-right",
        "--cherry-mark",
        "--no-merges",
        "--topo-order",
        "-2000",
        "--format=%m%x1f%H%x1f%P%x1f%an%x1f%at%x1f%s",
        range.as_str(),
        "--",
    ];
    let base_args = ["merge-base", left, right];
    // Commits only reachable from the left side, in one process (instead of one `merge-base` per commit).
    let left_only = format!("{right}..{left}");
    let side_args = ["rev-list", "--no-merges", left_only.as_str(), "--"];
    let (log, base, side) = tokio::join!(
        git(root, &log_args),
        git(root, &base_args),
        git(root, &side_args)
    );
    let side = side.unwrap_or_default();
    let on_left_side: HashSet<&str> = side.lines().map(str::trim).collect();
    let mut sync = BranchSync {
        left: left.into(),
        right: right.into(),
        only_left: vec![],
        only_right: vec![],
        equivalent_left: vec![],
        equivalent_right: vec![],
        merge_base: base.ok().map(|b| b.trim().to_string()),
    };
    for line in log?.lines() {
        let f: Vec<_> = line.splitn(6, '\x1f').collect();
        if f.len() != 6 {
            continue;
        }
        let commit = Commit {
            hash: f[1].into(),
            parents: f[2].split_whitespace().map(String::from).collect(),
            author: f[3].into(),
            timestamp: f[4].into(),
            subject: f[5].into(),
            refs: String::new(),
        };
        // `=` marks equivalent commits; the side comes from comparing against the left tip's ancestry.
        match f[0] {
            "<" => sync.only_left.push(commit),
            ">" => sync.only_right.push(commit),
            _ => {
                if on_left_side.contains(commit.hash.as_str()) {
                    sync.equivalent_left.push(commit)
                } else {
                    sync.equivalent_right.push(commit)
                }
            }
        }
    }
    Ok(sync)
}

/// Copies commits onto `target` with `cherry-pick -x` (oldest first) and returns to the original
/// branch. On conflict the cherry-pick stays in progress on `target` for the conflict assistant.
pub async fn copy_commits(root: &Path, target: &str, hashes: &[String]) -> Result<usize> {
    if hashes.is_empty() {
        return Ok(0);
    }
    validate_branch(root, target).await?;
    git(
        root,
        &["show-ref", "--verify", &format!("refs/heads/{target}")],
    )
    .await
    .map_err(|_| error("invalid_ref", format!("No existe la rama local {target}.")))?;
    if target == primary_branch(root).await && main_protected(root).await {
        return Err(error(
            "protected_branch",
            "main está protegida en este repo. Desactiva la protección o lleva los cambios por PR.",
        ));
    }
    let state = snapshot(root).await?;
    if !state.operation.is_empty() {
        return Err(error(
            "operation_in_progress",
            "Termina o cancela la operación en curso antes de copiar commits.",
        ));
    }
    if !state.files.is_empty() {
        return Err(error(
            "dirty_worktree",
            "Tienes cambios sin commit. Haz commit o guárdalos en stash antes de copiar commits entre ramas.",
        ));
    }
    let mut ordered = Vec::new();
    for hash in hashes.iter().rev() {
        ordered.push(validate_commit(root, hash).await?);
    }
    let original = state.branch.clone();
    // Detached HEAD has no branch to return to: remember the commit instead.
    let detached = if original == "HEAD" {
        Some(
            git(root, &["rev-parse", "--verify", "HEAD"])
                .await?
                .trim()
                .to_string(),
        )
    } else {
        None
    };
    if original != target {
        git(root, &["switch", target]).await?;
    }
    let back = || async {
        match &detached {
            Some(hash) => git(root, &["switch", "--detach", hash]).await,
            None if original != target => git(root, &["switch", &original]).await,
            None => Ok(String::new()),
        }
    };
    let mut args = vec!["cherry-pick", "-x"];
    args.extend(ordered.iter().map(String::as_str));
    let mut outcome = git(root, &args).await;
    let mut skipped = 0;
    loop {
        let failure = match outcome {
            Ok(_) => break,
            Err(failure) => failure,
        };
        if has_conflicts(root).await? {
            return Err(error(
                "copy_conflicts",
                format!("Hay conflictos al copiar a {target}. Quedaste en {target}: resuélvelos, pulsa «Continuar» y luego vuelve a {original}."),
            ));
        }
        if failure.detail.contains("empty") && skipped < ordered.len() {
            // Already applied on the target: skip it and let the rest of the sequence continue.
            skipped += 1;
            outcome = git(root, &["cherry-pick", "--skip"]).await;
            continue;
        }
        let _ = git(root, &["cherry-pick", "--abort"]).await;
        let _ = back().await;
        return Err(failure);
    }
    back().await?;
    let copied = ordered.len() - skipped;
    if copied == 0 {
        return Err(error(
            "copy_empty",
            "Los commits ya estaban aplicados en la rama destino; no se copió nada nuevo.",
        ));
    }
    Ok(copied)
}

async fn reference(root: &Path, name: &str) -> Result<String> {
    let reference = format!("refs/heads/{name}");
    git(root, &["check-ref-format", &reference]).await?;
    git(root, &["show-ref", "--verify", "--hash", &reference]).await?;
    Ok(reference)
}

/// One local branch against a base: counts, authors, creation (from the reflog), its last 100
/// commits and the files it changes since the merge base.
pub async fn branch_details(root: &Path, name: &str, base: &str) -> Result<Value> {
    let branch = reference(root, name).await?;
    let base_ref = reference(root, base).await?;
    // Resolve once: every statistic and the comparison refer to the same snapshot.
    let head = git(root, &["rev-parse", &branch]).await?.trim().to_string();
    let base_head = git(root, &["rev-parse", &base_ref])
        .await?
        .trim()
        .to_string();
    let counts = git(
        root,
        &[
            "rev-list",
            "--left-right",
            "--count",
            &format!("{base_head}...{head}"),
        ],
    )
    .await?;
    let counts: Vec<u64> = counts
        .split_whitespace()
        .filter_map(|s| s.parse().ok())
        .collect();
    let total = git(root, &["rev-list", "--count", &head])
        .await?
        .trim()
        .parse::<u64>()
        .unwrap_or(0);
    let merge_base = git(root, &["merge-base", &base_head, &head])
        .await
        .ok()
        .map(|s| s.trim().to_string());
    let mut authors = BTreeMap::<String, u64>::new();
    for name in git(
        root,
        &["log", "--format=%aN", &format!("{base_head}..{head}")],
    )
    .await?
    .lines()
    {
        *authors.entry(name.to_string()).or_default() += 1;
    }
    let authors: Vec<Value> = authors
        .into_iter()
        .map(|(name, count)| json!({"name": name, "count": count}))
        .collect();
    let log = git(
        root,
        &[
            "log",
            "--topo-order",
            "-100",
            "--format=%H%x1f%P%x1f%aN%x1f%at%x1f%s%x1f%D",
            &head,
            &base_head,
            "--",
        ],
    )
    .await?;
    let commits: Vec<Value> = log
        .lines()
        .filter_map(|line| {
            let p: Vec<_> = line.split('\x1f').collect();
            (p.len() == 6).then(|| {
                json!({"hash": p[0], "parents": p[1].split_whitespace().collect::<Vec<_>>(),
                       "author": p[2], "timestamp": p[3], "subject": p[4], "refs": p[5]})
            })
        })
        .collect();
    let upstream = git(
        root,
        &["for-each-ref", "--format=%(upstream:short)", &branch],
    )
    .await?
    .trim()
    .to_string();
    let tracking = if upstream.is_empty() {
        None
    } else {
        git(
            root,
            &[
                "rev-list",
                "--left-right",
                "--count",
                &format!("{branch}...{branch}@{{upstream}}"),
            ],
        )
        .await
        .ok()
        .map(|s| {
            s.split_whitespace()
                .filter_map(|n| n.parse::<u64>().ok())
                .collect::<Vec<_>>()
        })
    };
    let reflog = git(
        root,
        &[
            "reflog",
            "show",
            "--date=unix",
            "--format=%gN%x1f%gs%x1f%gD",
            &branch,
        ],
    )
    .await
    .unwrap_or_default();
    let creation = reflog.lines().rev().find_map(|line| {
        let p: Vec<_> = line.split('\x1f').collect();
        if p.len() != 3 || !p[1].starts_with("branch: Created from ") {
            return None;
        }
        let timestamp = p[2]
            .rsplit_once("@{")?
            .1
            .trim_end_matches('}')
            .parse::<i64>()
            .ok()?;
        Some(json!({"actor": p[0], "timestamp": timestamp, "event": p[1]}))
    });
    let comparison = merge_base.as_ref().unwrap_or(&base_head);
    let numstat = git(
        root,
        &[
            "diff",
            "--no-ext-diff",
            "--no-renames",
            "--numstat",
            "-z",
            comparison,
            &head,
            "--",
        ],
    )
    .await?;
    let files: Vec<Value> = numstat
        .split('\0')
        .filter_map(|entry| {
            let mut p = entry.splitn(3, '\t');
            let additions = p.next()?;
            let deletions = p.next()?;
            let path = p.next()?;
            Some(
                json!({"path": path, "additions": additions.parse::<u64>().ok(),
                        "deletions": deletions.parse::<u64>().ok()}),
            )
        })
        .collect();
    Ok(json!({
        "name": name, "base": base, "head": head, "baseHead": base_head, "mergeBase": merge_base,
        "total": total, "ahead": counts.get(1).copied().unwrap_or(0),
        "behind": counts.first().copied().unwrap_or(0), "upstream": upstream,
        "tracking": tracking, "creation": creation, "authors": authors, "commits": commits,
        "files": files,
    }))
}
