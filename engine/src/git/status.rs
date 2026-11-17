//! What a repository looks like now: changed files, line counts, branches, recent history and the
//! operation in progress, read with concurrent Git calls.
use super::protection::{primary_from, repository_config};
use super::remotes::without_credentials;
use super::runner::{error, git, git_input, Result};
use serde::Serialize;
use std::path::{Path, PathBuf};

#[derive(Serialize, Debug)]
#[serde(rename_all = "camelCase")]
pub struct ChangedFile {
    pub path: String,
    pub original_path: Option<String>,
    pub index: String,
    pub worktree: String,
}
impl ChangedFile {
    /// Unmerged entry: any `U`, or both sides added (`AA`) or deleted (`DD`).
    pub fn conflicted(&self) -> bool {
        self.index == "U"
            || self.worktree == "U"
            || (self.index == "A" && self.worktree == "A")
            || (self.index == "D" && self.worktree == "D")
    }
}
#[derive(Serialize)]
pub struct Commit {
    pub hash: String,
    pub parents: Vec<String>,
    pub author: String,
    pub timestamp: String,
    pub subject: String,
    pub refs: String,
}
#[derive(Serialize)]
pub struct Branch {
    pub name: String,
    pub current: bool,
    pub upstream: String,
    /// Commits ahead/behind its upstream; `gone` when the upstream branch was deleted.
    pub ahead: u64,
    pub behind: u64,
    pub gone: bool,
    /// Last commit date (epoch UTC).
    pub updated: i64,
}
#[derive(Serialize, Debug)]
#[serde(rename_all = "camelCase")]
pub struct RemoteBranch {
    /// `origin/feature/x`
    pub name: String,
    pub remote: String,
    /// `feature/x`
    pub short: String,
    pub updated: i64,
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Snapshot {
    pub root: String,
    pub branch: String,
    pub files: Vec<ChangedFile>,
    pub commits: Vec<Commit>,
    pub branches: Vec<Branch>,
    pub operation: String,
    pub ahead: u64,
    pub behind: u64,
    /// URL of `origin`, without credentials.
    pub remote: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub stats: Option<Vec<FileStat>>,
    pub main_protected: bool,
    /// "true", "false" or "" (automatic) as stored in `butake.protectMain`.
    pub main_protection: String,
    /// Last protection state read from the hosting provider ("true", "false" or empty when unknown).
    pub main_protection_remote: String,
    /// `main`, or `master` where the repository uses it.
    pub primary_branch: String,
    pub remote_branches: Vec<RemoteBranch>,
    /// Configured remotes (`origin`, …); empty for a repository that only exists locally.
    pub remotes: Vec<String>,
}
#[derive(Serialize, Debug)]
pub struct FileStat {
    pub path: String,
    pub staged: bool,
    pub additions: Option<u64>,
    pub deletions: Option<u64>,
}

/// A path relative to the repository, without `..` or a leading `/`.
pub fn validate_path(value: &str) -> Result<()> {
    if value.is_empty()
        || Path::new(value).is_absolute()
        || Path::new(value)
            .components()
            .any(|c| matches!(c, std::path::Component::ParentDir))
    {
        return Err(error("invalid_path", "Ruta relativa inválida."));
    }
    Ok(())
}

/// Added/removed lines for unstaged and staged changes, from concurrent numstat calls.
pub async fn line_stats(root: &Path) -> Vec<FileStat> {
    // Staged side detects renames (-M) so a moved file keeps its counts under the new path.
    let worktree_args = [
        "diff",
        "--numstat",
        "-z",
        "--no-renames",
        "--no-ext-diff",
        "--no-textconv",
    ];
    let index_args = [
        "diff",
        "--numstat",
        "-z",
        "-M",
        "--no-ext-diff",
        "--no-textconv",
        "--cached",
    ];
    let untracked_args = ["ls-files", "--others", "--exclude-standard", "-z"];
    let (worktree, index, untracked) = tokio::join!(
        git(root, &worktree_args),
        git(root, &index_args),
        git(root, &untracked_args)
    );
    let mut stats = parse_numstat_z(&worktree.unwrap_or_default(), false);
    stats.extend(parse_numstat_z(&index.unwrap_or_default(), true));
    // Untracked files have no diff: count their lines directly (bounded size; binary stays unknown).
    // Blocking reads run off the async workers: thousands of untracked files must not stall them.
    let untracked: Vec<String> = untracked
        .unwrap_or_default()
        .split('\0')
        .filter(|p| !p.is_empty())
        .map(String::from)
        .collect();
    let base = root.to_path_buf();
    let counted = tokio::task::spawn_blocking(move || {
        untracked
            .into_iter()
            .map(|path| {
                let lines = count_lines(&base.join(&path));
                FileStat {
                    path,
                    staged: false,
                    additions: lines,
                    deletions: lines.map(|_| 0),
                }
            })
            .collect::<Vec<_>>()
    })
    .await
    .unwrap_or_default();
    stats.extend(counted);
    stats
}

/// Lines of a regular text file of at most 2 MB, read in chunks; None for anything else (a binary
/// file, a folder, a larger file or one that cannot be read).
fn count_lines(path: &Path) -> Option<u64> {
    use std::io::Read;
    let metadata = std::fs::metadata(path).ok()?;
    if !metadata.is_file() || metadata.len() > 2_000_000 {
        return None;
    }
    let mut file = std::fs::File::open(path).ok()?;
    let (mut newlines, mut last, mut buffer) = (0u64, None, [0u8; 16_384]);
    loop {
        let read = file.read(&mut buffer).ok()?;
        if read == 0 {
            break;
        }
        let chunk = &buffer[..read];
        if chunk.contains(&0) {
            return None;
        }
        newlines += chunk.iter().filter(|b| **b == b'\n').count() as u64;
        last = chunk.last().copied();
    }
    Some(newlines + u64::from(last.is_some_and(|byte| byte != b'\n')))
}

/// Parses `git diff --numstat -z`; with renames an entry is `added\tdeleted\t\0old\0new\0`.
pub fn parse_numstat_z(raw: &str, staged: bool) -> Vec<FileStat> {
    let mut stats = Vec::new();
    let mut tokens = raw.split('\0');
    while let Some(entry) = tokens.next() {
        if entry.is_empty() {
            continue;
        }
        let mut fields = entry.splitn(3, '\t');
        let (Some(added), Some(deleted), Some(path)) =
            (fields.next(), fields.next(), fields.next())
        else {
            continue;
        };
        let path = if path.is_empty() {
            let _old = tokens.next();
            tokens.next().unwrap_or_default().to_string()
        } else {
            path.to_string()
        };
        stats.push(FileStat {
            path,
            staged,
            additions: added.parse().ok(),
            deletions: deleted.parse().ok(),
        });
    }
    stats
}

/// Stages or unstages many paths with a single Git process; every path must be a current change.
pub async fn stage_paths(root: &Path, paths: &[String], unstage: bool) -> Result<usize> {
    if paths.is_empty() {
        return Ok(0);
    }
    for path in paths {
        validate_path(path)?;
    }
    let status = status(root).await?;
    let changes: std::collections::HashMap<&str, &ChangedFile> =
        status.iter().map(|f| (f.path.as_str(), f)).collect();
    let mut spec = Vec::new();
    for path in paths {
        let file = changes.get(path.as_str()).ok_or_else(|| {
            error(
                "stale_file",
                format!("{path} ya no figura entre los cambios."),
            )
        })?;
        for item in std::iter::once(&file.path).chain(file.original_path.iter()) {
            spec.extend_from_slice(item.as_bytes());
            spec.push(0);
        }
    }
    let has_head = git(root, &["rev-parse", "--verify", "HEAD"]).await.is_ok();
    let args: &[&str] = match (unstage, has_head) {
        (false, _) => &["add", "--pathspec-from-file=-", "--pathspec-file-nul", "--"],
        (true, true) => &[
            "restore",
            "--staged",
            "--pathspec-from-file=-",
            "--pathspec-file-nul",
        ],
        // No commits yet: `-f` lets a file edited after `git add` leave the index (the working tree is untouched).
        (true, false) => &[
            "rm",
            "--cached",
            "-f",
            "--quiet",
            "--pathspec-from-file=-",
            "--pathspec-file-nul",
        ],
    };
    git_input(root, args, &spec).await?;
    Ok(paths.len())
}

/// The top folder of the repository that contains `path`.
pub async fn open_root(path: &str) -> Result<PathBuf> {
    let candidate = std::fs::canonicalize(path).map_err(|_| {
        error(
            "invalid_path",
            "La carpeta no existe o no se puede leer. Elige otra o revisa sus permisos.",
        )
    })?;
    let root = git(&candidate, &["rev-parse", "--show-toplevel"]).await?;
    std::fs::canonicalize(root.trim()).map_err(|_| {
        error(
            "invalid_path",
            "La carpeta no existe o no se puede leer. Elige otra o revisa sus permisos.",
        )
    })
}

pub fn parse_status(raw: &str) -> Vec<ChangedFile> {
    let mut entries = raw.split('\0').filter(|s| !s.is_empty());
    let mut files = Vec::new();
    while let Some(entry) = entries.next() {
        if entry.len() < 4 || !entry.is_char_boundary(3) {
            continue;
        }
        let index = &entry[0..1];
        let worktree = &entry[1..2];
        let original_path = if index == "R" || index == "C" || worktree == "R" || worktree == "C" {
            entries.next().map(String::from)
        } else {
            None
        };
        files.push(ChangedFile {
            path: entry[3..].to_string(),
            original_path,
            index: index.into(),
            worktree: worktree.into(),
        });
    }
    files
}

/// Changed files only: the cheap refresh for working-tree edits, which cannot move refs or history.
pub async fn status(root: &Path) -> Result<Vec<ChangedFile>> {
    Ok(parse_status(
        &git(
            root,
            &["status", "--porcelain=v1", "-z", "--untracked-files=all"],
        )
        .await?,
    ))
}

/// Whether any file is unmerged: the index lists it, no need to scan the working tree.
pub async fn has_conflicts(root: &Path) -> Result<bool> {
    Ok(!git(root, &["ls-files", "--unmerged", "-z"])
        .await?
        .is_empty())
}

pub const DEFAULT_HISTORY_LIMIT: usize = 180;
pub const MAX_HISTORY_LIMIT: usize = 5_000;

pub async fn snapshot(root: &Path) -> Result<Snapshot> {
    snapshot_with(root, DEFAULT_HISTORY_LIMIT, false).await
}

const OPERATION_MARKERS: [(&str, &str); 5] = [
    ("rebase-merge", "rebase"),
    ("rebase-apply", "rebase"),
    ("MERGE_HEAD", "merge"),
    ("CHERRY_PICK_HEAD", "cherry-pick"),
    ("REVERT_HEAD", "revert"),
];

/// The operation left halfway ("rebase", "merge", "cherry-pick", "revert") or empty: the same
/// rule as the snapshot's `operation`, without reading the rest.
pub async fn operation(root: &Path) -> Result<String> {
    let mut args = vec!["rev-parse"];
    for (marker, _) in OPERATION_MARKERS.iter() {
        args.extend(["--git-path", marker]);
    }
    let paths = git(root, &args).await?;
    Ok(paths
        .lines()
        .zip(OPERATION_MARKERS.iter())
        .find(|(location, _)| root.join(location.trim()).exists())
        .map(|(_, (_, label))| label.to_string())
        .unwrap_or_default())
}

/// Independent Git reads run concurrently: with large working trees the snapshot cost is bounded
/// by the slowest command instead of their sum.
pub async fn snapshot_with(root: &Path, limit: usize, with_stats: bool) -> Result<Snapshot> {
    let limit = format!("-{}", limit.clamp(1, MAX_HISTORY_LIMIT));
    let markers: Vec<String> = OPERATION_MARKERS
        .iter()
        .flat_map(|(marker, _)| ["--git-path".to_string(), marker.to_string()])
        .collect();
    let mut marker_args = vec!["rev-parse"];
    marker_args.extend(markers.iter().map(String::as_str));
    // Branches, remotes, tags and HEAD only: `--all` would also show stashes and backup refs.
    let log_args = [
        "log",
        limit.as_str(),
        "--branches",
        "--remotes",
        "--tags",
        "HEAD",
        "--topo-order",
        "--format=%H%x1f%P%x1f%an%x1f%at%x1f%s%x1f%D",
    ];
    let (status, branch, log, raw_branches, divergence, paths, remote, stats, config) = tokio::join!(
        git(
            root,
            &["status", "--porcelain=v1", "-z", "--untracked-files=all"]
        ),
        git(root, &["symbolic-ref", "--quiet", "--short", "HEAD"]),
        git(root, &log_args),
        git(
            root,
            &[
                "for-each-ref",
                "--format=%(refname)%09%(HEAD)%09%(upstream:short)%09%(upstream:track,nobracket)%09%(committerdate:unix)",
                "refs/heads/",
                "refs/remotes/",
            ],
        ),
        git(
            root,
            &["rev-list", "--left-right", "--count", "HEAD...@{upstream}"]
        ),
        git(root, &marker_args),
        git(root, &["remote", "get-url", "origin"]),
        async {
            if with_stats {
                Some(line_stats(root).await)
            } else {
                None
            }
        },
        repository_config(root),
    );
    let files = parse_status(&status?);
    let branch = branch.unwrap_or_else(|_| "HEAD".into()).trim().to_string();
    // An unborn branch has no HEAD: `git log` fails and the history is empty.
    let commits = log
        .unwrap_or_default()
        .lines()
        .filter_map(|line| {
            let f: Vec<_> = line.splitn(6, '\x1f').collect();
            (f.len() == 6).then(|| Commit {
                hash: f[0].into(),
                parents: f[1].split_whitespace().map(String::from).collect(),
                author: f[2].into(),
                timestamp: f[3].into(),
                subject: f[4].into(),
                refs: f[5].into(),
            })
        })
        .collect();
    let (branches, remote_branches) = parse_branches(&raw_branches?);
    let primary = primary_from(&branches, &remote_branches);
    let divergence = divergence.unwrap_or_default();
    let mut counts = divergence
        .split_whitespace()
        .map(|n| n.parse::<u64>().unwrap_or(0));
    let ahead = counts.next().unwrap_or(0);
    let behind = counts.next().unwrap_or(0);
    let paths = paths?;
    let operation = paths
        .lines()
        .zip(OPERATION_MARKERS.iter())
        .find(|(location, _)| root.join(location.trim()).exists())
        .map(|(_, (_, label))| label.to_string())
        .unwrap_or_default();
    Ok(Snapshot {
        root: root.display().to_string(),
        branch,
        files,
        commits,
        branches,
        operation,
        ahead,
        behind,
        remote: without_credentials(remote.unwrap_or_default().trim()),
        stats,
        main_protected: config.main_protected(),
        main_protection: config.protect_main,
        main_protection_remote: config.remote_protect_main,
        primary_branch: primary,
        remote_branches,
        remotes: config.remotes,
    })
}

/// Splits `for-each-ref` output into local branches (with tracking state) and remote branches.
pub fn parse_branches(text: &str) -> (Vec<Branch>, Vec<RemoteBranch>) {
    let mut local = Vec::new();
    let mut remote = Vec::new();
    for line in text.lines() {
        let f: Vec<_> = line.splitn(5, '\t').collect();
        if f.len() < 5 {
            continue;
        }
        let updated = f[4].trim().parse().unwrap_or(0);
        if let Some(name) = f[0].strip_prefix("refs/heads/") {
            let track = f[3];
            let number = |key: &str| {
                track
                    .split(", ")
                    .find_map(|part| part.strip_prefix(key))
                    .and_then(|n| n.trim().parse().ok())
                    .unwrap_or(0)
            };
            local.push(Branch {
                name: name.into(),
                current: f[1] == "*",
                upstream: f[2].into(),
                ahead: number("ahead "),
                behind: number("behind "),
                gone: track == "gone",
                updated,
            });
        } else if let Some(name) = f[0].strip_prefix("refs/remotes/") {
            let Some((remote_name, short)) = name.split_once('/') else {
                continue;
            };
            if short == "HEAD" {
                continue;
            }
            remote.push(RemoteBranch {
                name: name.into(),
                remote: remote_name.into(),
                short: short.into(),
                updated,
            });
        }
    }
    (local, remote)
}
