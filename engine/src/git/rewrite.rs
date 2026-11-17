//! Guided history rewriting: reorder, squash, reword and drop *unpublished* commits without any
//! editor. Every rewrite stores a backup ref first (`refs/butake/backup/<branch>/<epoch>`) so it
//! can be undone with `reset --keep`.
use super::protection::{main_protected, primary_branch};
use super::runner::{error, git, git_env, Result};
use super::status::{has_conflicts, snapshot};
use crate::core::time::now_secs;
use serde::{Deserialize, Serialize};
use std::{collections::HashSet, path::Path};

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RewriteCommit {
    pub hash: String,
    pub subject: String,
    pub message: String,
    pub author: String,
    pub timestamp: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RewriteCandidates {
    pub branch: String,
    pub head: String,
    pub base: String,
    /// Oldest first.
    pub commits: Vec<RewriteCommit>,
    /// Why the list stops where it does: "upstream", "merge", "root" or "limit".
    pub boundary: String,
}

#[derive(Deserialize, Debug)]
pub struct RewriteStep {
    /// Oldest first; more than one hash squashes them into a single commit.
    pub hashes: Vec<String>,
    pub drop: bool,
    /// New full message (subject + body); `None` keeps the original.
    pub message: Option<String>,
}

#[derive(Deserialize, Debug)]
pub struct RewritePlan {
    pub head: String,
    pub base: String,
    pub steps: Vec<RewriteStep>,
}

#[derive(Serialize, Debug)]
pub struct RewriteResult {
    pub backup: String,
    pub head: String,
}

const LIMIT: usize = 60;
/// Where backups of rewritten branches live (never shown in the history: see `snapshot`).
pub const BACKUP_PREFIX: &str = "refs/butake/backup/";

async fn current_branch(root: &Path) -> Result<String> {
    let branch = git(root, &["symbolic-ref", "--quiet", "--short", "HEAD"])
        .await
        .map_err(|_| {
            error(
                "detached_head",
                "Cambia a una rama antes de organizar commits.",
            )
        })?;
    Ok(branch.trim().to_string())
}

/// Commits that can be rewritten safely: reachable from HEAD on the first-parent line, not yet in
/// the upstream (rewriting published commits would require force-push, which stays blocked).
pub async fn candidates(root: &Path) -> Result<RewriteCandidates> {
    let branch = current_branch(root).await?;
    let head = git(root, &["rev-parse", "--verify", "HEAD"])
        .await?
        .trim()
        .to_string();
    let upstream = git(root, &["rev-parse", "--verify", "--quiet", "@{upstream}"])
        .await
        .ok();
    // Anything a remote already has is published, whether or not this branch tracks it (a branch
    // cut from a pushed develop has no upstream, yet rewriting develop's commits would duplicate
    // shared history).
    let published = !git(
        root,
        &[
            "for-each-ref",
            "--count=1",
            "--format=%(refname)",
            "refs/remotes/",
        ],
    )
    .await
    .unwrap_or_default()
    .trim()
    .is_empty();
    let limit = format!("-{}", LIMIT + 1);
    // --no-show-signature: `log.showSignature` would mix verification lines into the records.
    let mut args = vec![
        "log",
        "--no-show-signature",
        "--first-parent",
        &limit,
        "--format=%H%x1f%P%x1f%an%x1f%at%x1f%B%x1e",
        "HEAD",
        "--not",
    ];
    if upstream.is_some() {
        args.push("@{upstream}");
    }
    args.push("--remotes");
    let raw = git(root, &args).await?;
    let mut commits = Vec::new();
    let mut boundary = if upstream.is_some() || published {
        "upstream"
    } else {
        "limit"
    }
    .to_string();
    for record in raw
        .split('\x1e')
        .map(|r| r.trim_start_matches('\n'))
        .filter(|r| !r.is_empty())
    {
        let f: Vec<_> = record.splitn(5, '\x1f').collect();
        if f.len() != 5 {
            continue;
        }
        let parents: Vec<_> = f[1].split_whitespace().collect();
        if parents.len() > 1 {
            boundary = "merge".into();
            break;
        }
        if parents.is_empty() {
            boundary = "root".into();
            break;
        }
        if commits.len() == LIMIT {
            boundary = "limit".into();
            break;
        }
        let message = f[4].trim_end().to_string();
        commits.push(RewriteCommit {
            hash: f[0].into(),
            subject: message.lines().next().unwrap_or("").to_string(),
            message,
            author: f[2].into(),
            timestamp: f[3].into(),
        });
    }
    let base = match commits.last() {
        Some(oldest) => git(root, &["rev-parse", &format!("{}^", oldest.hash)])
            .await?
            .trim()
            .to_string(),
        None => head.clone(),
    };
    commits.reverse();
    Ok(RewriteCandidates {
        branch,
        head,
        base,
        commits,
        boundary,
    })
}

/// Builds the rebase todo; messages go to files referenced by `exec git commit --amend -F`.
fn todo(plan: &RewritePlan, dir: &Path) -> Result<String> {
    let mut lines = Vec::new();
    for (index, step) in plan.steps.iter().enumerate() {
        if step.hashes.is_empty() {
            return Err(error("invalid_plan", "Paso vacío en el plan."));
        }
        if step.drop {
            lines.extend(step.hashes.iter().map(|h| format!("drop {h}")));
            continue;
        }
        lines.push(format!("pick {}", step.hashes[0]));
        lines.extend(step.hashes[1..].iter().map(|h| format!("fixup {h}")));
        if let Some(message) = &step.message {
            if message.trim().is_empty() {
                return Err(error("empty_message", "Un commit quedó sin mensaje."));
            }
            let path = dir.join(format!("message-{index}.txt"));
            std::fs::write(&path, format!("{}\n", message.trim_end()))
                .map_err(|_| error("plan_file", "No se pudo preparar el plan."))?;
            let quoted = path.to_string_lossy().replace('\'', "'\\''");
            // --no-verify: hooks already ran for the original commits; only the message changes here.
            lines.push(format!(
                "exec git commit --amend --no-verify --allow-empty -F '{quoted}'"
            ));
        }
    }
    Ok(lines.join("\n") + "\n")
}

/// Folder for the files of a rewrite in progress (`<git dir>/butake-rewrite`).
async fn scratch(root: &Path) -> Result<std::path::PathBuf> {
    let path = git(root, &["rev-parse", "--git-path", "butake-rewrite"]).await?;
    Ok(root.join(path.trim()))
}

pub async fn apply(root: &Path, plan: &RewritePlan) -> Result<RewriteResult> {
    let state = snapshot(root).await?;
    if state.branch == state.primary_branch && state.main_protected {
        return Err(error(
            "protected_branch",
            "main está protegida en este repo.",
        ));
    }
    if !state.files.is_empty() || !state.operation.is_empty() {
        return Err(error(
            "dirty_rewrite",
            "Confirma tus cambios o guárdalos aparte (Más… › Guardados) y termina la operación a medias antes de organizar commits.",
        ));
    }
    let current = candidates(root).await?;
    if current.head != plan.head || current.base != plan.base {
        return Err(error(
            "stale_plan",
            "El historial cambió. Vuelve a abrir «Organizar commits».",
        ));
    }
    let expected: HashSet<_> = current.commits.iter().map(|c| c.hash.as_str()).collect();
    let supplied: Vec<_> = plan
        .steps
        .iter()
        .flat_map(|s| s.hashes.iter().map(String::as_str))
        .collect();
    if supplied.len() != expected.len()
        || supplied.iter().copied().collect::<HashSet<_>>() != expected
    {
        return Err(error(
            "invalid_plan",
            "El plan debe contener cada commit exactamente una vez.",
        ));
    }
    if plan.steps.iter().all(|s| s.drop) {
        return Err(error(
            "invalid_plan",
            "Debe quedar al menos un commit: deja alguno sin descartar.",
        ));
    }
    let backup = format!("{BACKUP_PREFIX}{}/{}", current.branch, now_secs());
    git(root, &["update-ref", &backup, &current.head]).await?;
    // Inside the git dir, not a temporary folder: when the rebase stops on a conflict, the `exec`
    // lines that set the new messages still run after «Continuar», so their files must outlive
    // this process.
    let dir = scratch(root).await?;
    let plan_failed = || error("plan_file", "No se pudo preparar el plan.");
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).map_err(|_| plan_failed())?;
    let todo_path = dir.join("todo.txt");
    std::fs::write(&todo_path, todo(plan, &dir)?).map_err(|_| plan_failed())?;
    let editor = format!(
        "cp '{}'",
        todo_path.to_string_lossy().replace('\'', "'\\''")
    );
    let outcome = git_env(
        root,
        &[
            "rebase",
            "--interactive",
            "--keep-empty",
            "--no-autosquash",
            &plan.base,
        ],
        &[
            ("GIT_SEQUENCE_EDITOR", editor.as_str()),
            ("GIT_EDITOR", "true"),
        ],
    )
    .await;
    match outcome {
        Ok(_) => {
            let _ = std::fs::remove_dir_all(&dir);
            let head = git(root, &["rev-parse", "HEAD"]).await?.trim().to_string();
            Ok(RewriteResult { backup, head })
        }
        Err(failure) => {
            if has_conflicts(root).await? {
                Err(error(
                    "rewrite_conflicts",
                    format!("Al reordenar, dos commits chocan. Resuelve el conflicto y pulsa «Continuar», o «Cancelar» para volver atrás. Respaldo: {backup}"),
                ))
            } else {
                let _ = git(root, &["rebase", "--abort"]).await;
                let _ = std::fs::remove_dir_all(&dir);
                Err(failure)
            }
        }
    }
}

/// Whether `backup` is a backup of exactly `branch`: after the branch's prefix comes one last
/// segment (`<epoch>` or `undo-<epoch>`), so `feature/x`'s backups never match branch `feature`.
fn backup_of(branch: &str, backup: &str) -> bool {
    let Some(last) = backup.strip_prefix(&format!("{BACKUP_PREFIX}{branch}/")) else {
        return false;
    };
    let number = last.strip_prefix("undo-").unwrap_or(last);
    !number.is_empty() && number.bytes().all(|byte| byte.is_ascii_digit())
}

/// Restores the branch to a backup taken before a rewrite. `--keep` refuses to overwrite local changes.
pub async fn undo(root: &Path, backup: &str) -> Result<String> {
    let branch = current_branch(root).await?;
    if !backup_of(&branch, backup) {
        return Err(error(
            "invalid_ref",
            "Respaldo inválido para la rama actual.",
        ));
    }
    git(root, &["rev-parse", "--verify", "--quiet", backup])
        .await
        .map_err(|_| error("invalid_ref", "El respaldo ya no existe."))?;
    if branch == primary_branch(root).await && main_protected(root).await {
        return Err(error(
            "protected_branch",
            "main está protegida en este repo.",
        ));
    }
    // Commits made after the rewrite would only survive in the reflog: keep them reachable from a second backup.
    git(
        root,
        &[
            "update-ref",
            &format!("{BACKUP_PREFIX}{branch}/undo-{}", now_secs()),
            "HEAD",
        ],
    )
    .await?;
    let _ = std::fs::remove_dir_all(scratch(root).await?);
    git(root, &["reset", "--keep", backup]).await
}

#[cfg(test)]
mod tests {
    use super::backup_of;

    #[test]
    fn a_backup_belongs_to_exactly_its_branch() {
        assert!(backup_of(
            "feature",
            "refs/butake/backup/feature/1700000000"
        ));
        assert!(backup_of(
            "feature",
            "refs/butake/backup/feature/undo-1700000000"
        ));
        assert!(backup_of(
            "feature/x",
            "refs/butake/backup/feature/x/1700000000"
        ));
        // The backups of `feature/x` are not the ones of `feature`.
        assert!(!backup_of(
            "feature",
            "refs/butake/backup/feature/x/1700000000"
        ));
        assert!(!backup_of("feature", "refs/butake/backup/feature/"));
        assert!(!backup_of("feature", "refs/butake/backup/feature/../x"));
        assert!(!backup_of("feature", "refs/heads/feature"));
    }
}
