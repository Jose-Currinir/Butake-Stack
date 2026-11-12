//! Git awareness for sites, read-only except for the stack's own records: branch and pending
//! changes, worktrees served as `<branch>.<site>.test`, what a branch switch changed (dependencies,
//! migrations) and the matching tasks run with the stack's own PHP, Composer and Node.
//! Git always runs as `/usr/bin/git` with arguments (no shell) and never with optional locks.
use crate::{model::Project, scaffold::Toolchain, store::Store};
use anyhow::{ensure, Result};
use serde::Serialize;
use std::{
    path::{Path, PathBuf},
    process::{Command, Stdio},
};

#[derive(Debug, Serialize, PartialEq, Default)]
pub struct GitInfo {
    pub branch: String,
    pub head: String,
    pub changes: usize,
    pub ahead: u32,
    pub behind: u32,
}

#[derive(Debug, Serialize, PartialEq)]
pub struct Worktree {
    pub path: PathBuf,
    pub branch: String,
    /// The stack site already serving this worktree, if any.
    pub site: Option<String>,
}

#[derive(Debug, Serialize, PartialEq, Default)]
pub struct BranchChanges {
    pub composer: bool,
    pub npm: bool,
    pub migrations: usize,
}

fn git(path: &Path, args: &[&str]) -> Result<String> {
    let output = Command::new("/usr/bin/git")
        .arg("-C")
        .arg(path)
        .args(args)
        .env_clear()
        .env("PATH", "/usr/bin:/bin")
        .env("HOME", dirs::home_dir().unwrap_or_default())
        .env("GIT_OPTIONAL_LOCKS", "0")
        .env("LANG", "en_US.UTF-8")
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output()?;
    ensure!(output.status.success(), "git_failed");
    Ok(String::from_utf8_lossy(&output.stdout).into_owned())
}

pub fn is_repository(path: &Path) -> bool {
    path.join(".git").exists()
}

/// `git status --porcelain=v2 --branch` read into branch, HEAD, pending files and ahead/behind.
pub fn parse_status(text: &str) -> GitInfo {
    let mut info = GitInfo::default();
    for line in text.lines() {
        if let Some(head) = line.strip_prefix("# branch.head ") {
            info.branch = if head == "(detached)" { String::new() } else { head.into() };
        } else if let Some(oid) = line.strip_prefix("# branch.oid ") {
            info.head = if oid == "(initial)" { String::new() } else { oid.into() };
        } else if let Some(ab) = line.strip_prefix("# branch.ab ") {
            for part in ab.split(' ') {
                if let Some(n) = part.strip_prefix('+') {
                    info.ahead = n.parse().unwrap_or(0);
                } else if let Some(n) = part.strip_prefix('-') {
                    info.behind = n.parse().unwrap_or(0);
                }
            }
        } else if !line.starts_with('#') && !line.is_empty() {
            info.changes += 1;
        }
    }
    info
}

pub fn info(project: &Project) -> Option<GitInfo> {
    if !is_repository(&project.path) {
        return None;
    }
    git(&project.path, &["status", "--porcelain=v2", "--branch", "--untracked-files=normal"])
        .ok()
        .map(|text| parse_status(&text))
}

pub fn parse_worktrees(text: &str) -> Vec<(PathBuf, String)> {
    let mut out = Vec::new();
    let (mut path, mut branch) = (None::<PathBuf>, String::new());
    for line in text.lines().chain(std::iter::once("")) {
        if let Some(p) = line.strip_prefix("worktree ") {
            path = Some(PathBuf::from(p));
        } else if let Some(b) = line.strip_prefix("branch ") {
            branch = b.trim_start_matches("refs/heads/").into();
        } else if line.is_empty() {
            if let Some(p) = path.take() {
                out.push((p, std::mem::take(&mut branch)));
            }
            branch.clear();
        }
    }
    out
}

/// Linked worktrees of a site's repository (the main checkout excluded).
pub fn worktrees(store: &Store, project: &Project) -> Result<Vec<Worktree>> {
    if !is_repository(&project.path) {
        return Ok(vec![]);
    }
    let sites = store.list()?;
    let main = project.path.canonicalize()?;
    Ok(parse_worktrees(&git(&project.path, &["worktree", "list", "--porcelain"])?)
        .into_iter()
        .filter_map(|(path, branch)| {
            let path = path.canonicalize().ok()?;
            (path != main && !branch.is_empty()).then(|| Worktree {
                site: sites.iter().find(|s| s.path == path).map(|s| s.id.clone()),
                path,
                branch,
            })
        })
        .collect())
}

/// A branch name as a DNS label: lowercase letters, digits and dashes.
pub fn slug(branch: &str) -> String {
    let raw: String = branch
        .to_ascii_lowercase()
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() { c } else { '-' })
        .collect();
    let joined = raw.split('-').filter(|p| !p.is_empty()).collect::<Vec<_>>().join("-");
    joined.chars().take(30).collect::<String>().trim_end_matches('-').to_string()
}

/// Serves one of a site's worktrees as `<branch>.<site domain>`, off and without processes
/// (they would collide with the main checkout's ports).
pub fn add_worktree_site(store: &Store, id: &str, path: &Path) -> Result<Project> {
    let project = store.get(id)?;
    let path = path.canonicalize().map_err(|_| anyhow::anyhow!("invalid_path"))?;
    let worktree = worktrees(store, &project)?
        .into_iter()
        .find(|w| w.path == path)
        .ok_or_else(|| anyhow::anyhow!("not_a_worktree"))?;
    ensure!(worktree.site.is_none(), "worktree_already_served");
    let branch = slug(&worktree.branch);
    ensure!(!branch.is_empty(), "invalid_branch");
    let domain = project.domains.first().cloned().ok_or_else(|| anyhow::anyhow!("invalid_domain"))?;
    let mut site_id: String = format!("{}-{}", project.id, branch).chars().take(40).collect();
    site_id = site_id.trim_end_matches('-').into();
    store.save(Project {
        id: site_id,
        name: format!("{} · {}", project.name, worktree.branch),
        path,
        domains: vec![format!("{branch}.{domain}")],
        processes: vec![],
        enabled: false,
        ..project
    })
}

fn valid_oid(oid: &str) -> bool {
    (oid.len() == 40 || oid.len() == 64) && oid.bytes().all(|c| c.is_ascii_hexdigit())
}

pub fn classify(files: &str) -> BranchChanges {
    let mut out = BranchChanges::default();
    for file in files.lines() {
        match file {
            "composer.lock" | "composer.json" => out.composer = true,
            "package-lock.json" | "package.json" | "pnpm-lock.yaml" | "yarn.lock" => out.npm = true,
            f if f.starts_with("database/migrations/") => out.migrations += 1,
            _ => {}
        }
    }
    out
}

/// What changed between two commits that a site needs to catch up with.
pub fn branch_changes(store: &Store, id: &str, from: &str, to: &str) -> Result<BranchChanges> {
    ensure!(valid_oid(from) && valid_oid(to), "invalid_commit");
    let project = store.get(id)?;
    Ok(classify(&git(&project.path, &["diff", "--name-only", from, to])?))
}

/// Brings a site up to date after a branch switch: Composer or npm dependencies, or migrations.
pub fn run_task(store: &Store, id: &str, task: &str) -> Result<()> {
    ensure!(["composer", "npm", "migrate"].contains(&task), "invalid_task");
    let project = store.get(id)?;
    let chain = Toolchain::new(
        store,
        project.runtime.get("php").map(String::as_str),
        project.runtime.get("node").map(String::as_str),
        &format!("task-{id}"),
    )?;
    let cwd = &project.path;
    match task {
        "composer" => chain.runner.run(cwd, &chain.php, &[&chain.composer, "install", "--no-interaction"]),
        "npm" => {
            let node = chain.node_bin.as_ref().ok_or_else(|| anyhow::anyhow!("node_missing"))?;
            chain.runner.run(cwd, &node.join("npm"), &["install", "--no-audit", "--no-fund"])
        }
        _ => chain.runner.run(cwd, &chain.php, &["artisan", "migrate", "--force", "--no-interaction"]),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn parses_status_worktrees_and_changes() {
        let info = parse_status("# branch.oid 0123456789abcdef0123456789abcdef01234567\n# branch.head develop\n# branch.upstream origin/develop\n# branch.ab +2 -1\n1 .M N... 100644 100644 100644 a b app.php\n? nuevo.txt\n");
        assert_eq!((info.branch.as_str(), info.changes, info.ahead, info.behind), ("develop", 2, 2, 1));
        assert_eq!(parse_status("# branch.oid (initial)\n# branch.head (detached)\n").branch, "");
        let list = parse_worktrees("worktree /a\nHEAD 1\nbranch refs/heads/main\n\nworktree /b\nHEAD 2\nbranch refs/heads/feature/login\n\nworktree /c\nHEAD 3\ndetached\n");
        assert_eq!(list, vec![("/a".into(), "main".into()), ("/b".into(), "feature/login".into()), ("/c".into(), String::new())]);
        assert_eq!(slug("Feature/Login_Nuevo"), "feature-login-nuevo");
        assert_eq!(slug("///"), "");
        let changes = classify("composer.lock\napp/x.php\ndatabase/migrations/2026_a.php\ndatabase/migrations/2026_b.php\n");
        assert_eq!(changes, BranchChanges { composer: true, npm: false, migrations: 2 });
        assert!(valid_oid(&"a".repeat(40)) && !valid_oid("HEAD") && !valid_oid(&"g".repeat(40)));
    }
}
