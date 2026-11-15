//! Protection of the primary branch (`main`, or `master` where the repository uses it), per
//! repository: the user's explicit choice (`butake.protectMain`), else the hosting provider's rule
//! as the app last read it (`butake.remoteProtectMain`), else not blocked (pushing to it still asks
//! for a confirmation in the app).
use super::runner::{error, git, Result};
use super::status::{Branch, RemoteBranch};
use std::path::Path;

/// Same rule as `primary_branch`, from branches that were already listed (no extra Git process).
pub fn primary_from(local: &[Branch], remote: &[RemoteBranch]) -> String {
    for name in ["main", "master"] {
        if local.iter().any(|b| b.name == name)
            || remote
                .iter()
                .any(|b| b.remote == "origin" && b.short == name)
        {
            return name.into();
        }
    }
    "main".into()
}

/// Protection settings and remote names of a repository, read with a single `git config` call.
#[derive(Default, Debug, PartialEq)]
pub struct RepositoryConfig {
    /// `butake.protectMain` as stored (empty when unset).
    pub protect_main: String,
    /// `butake.remoteProtectMain` as stored (empty when unset).
    pub remote_protect_main: String,
    pub remotes: Vec<String>,
}

impl RepositoryConfig {
    /// Explicit choice first, then the provider's rule; unknown means not blocked.
    pub fn main_protected(&self) -> bool {
        for value in [&self.protect_main, &self.remote_protect_main] {
            match value.trim().to_ascii_lowercase().as_str() {
                "true" | "1" | "yes" | "on" => return true,
                "false" | "0" | "no" | "off" => return false,
                _ => {}
            }
        }
        false
    }
}

/// Parses `git config --get-regexp` lines (`key value`; Git prints section and variable names in
/// lowercase and keeps the subsection, i.e. the remote name, as written). The last value of a key wins.
pub fn parse_repository_config(raw: &str) -> RepositoryConfig {
    let mut config = RepositoryConfig::default();
    for line in raw.lines() {
        let (key, value) = line.split_once(' ').unwrap_or((line, ""));
        match key {
            "butake.protectmain" => config.protect_main = value.trim().into(),
            "butake.remoteprotectmain" => config.remote_protect_main = value.trim().into(),
            _ => {
                if let Some(name) = key
                    .strip_prefix("remote.")
                    .and_then(|rest| rest.strip_suffix(".url"))
                {
                    if !name.is_empty() && !config.remotes.iter().any(|r| r == name) {
                        config.remotes.push(name.into());
                    }
                }
            }
        }
    }
    config.remotes.sort();
    config
}

pub async fn repository_config(root: &Path) -> RepositoryConfig {
    // Exit code 1 (no matching key) reads as an empty configuration.
    let raw = git(
        root,
        &[
            "config",
            "--get-regexp",
            r"^(butake\.(remote)?protectmain|remote\..+\.url)$",
        ],
    )
    .await
    .unwrap_or_default();
    parse_repository_config(&raw)
}

/// The repository's primary branch: `main`, or `master` in repositories that still use it.
pub async fn primary_branch(root: &Path) -> String {
    for name in ["main", "master"] {
        for reference in [
            format!("refs/heads/{name}"),
            format!("refs/remotes/origin/{name}"),
        ] {
            if git(root, &["rev-parse", "--verify", "--quiet", &reference])
                .await
                .is_ok()
            {
                return name.into();
            }
        }
    }
    "main".into()
}

/// Whether the primary branch is protected in this repository (see the module).
pub async fn main_protected(root: &Path) -> bool {
    repository_config(root).await.main_protected()
}

/// The current branch, or empty on a detached HEAD.
pub async fn current_branch(root: &Path) -> String {
    git(root, &["symbolic-ref", "--quiet", "--short", "HEAD"])
        .await
        .unwrap_or_default()
        .trim()
        .to_string()
}

/// Caches the provider's protection rule ("true", "false" or "unknown" to clear it).
pub async fn set_remote_protection(root: &Path, value: &str) -> Result<String> {
    match value {
        "true" | "false" => {
            git(
                root,
                &["config", "--local", "butake.remoteProtectMain", value],
            )
            .await
        }
        "unknown" => git(
            root,
            &["config", "--local", "--unset", "butake.remoteProtectMain"],
        )
        .await
        .or(Ok(String::new())),
        _ => Err(error("invalid_arguments", "Valor de protección inválido.")),
    }
}

pub async fn set_main_protection(root: &Path, value: &str) -> Result<String> {
    match value {
        "true" | "false" => git(root, &["config", "--local", "butake.protectMain", value]).await,
        "auto" => git(
            root,
            &["config", "--local", "--unset", "butake.protectMain"],
        )
        .await
        .or(Ok(String::new())),
        _ => Err(error("invalid_arguments", "Valor de protección inválido.")),
    }
}
