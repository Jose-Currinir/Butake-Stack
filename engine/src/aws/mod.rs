//! The AWS tool: the profiles of AWS CLI v2 on this Mac (`~/.aws/config` and
//! `~/.aws/credentials`, or the files `AWS_CONFIG_FILE` and `AWS_SHARED_CREDENTIALS_FILE` name).
//!
//! Sensitive data (see docs/aws.md):
//! - The credentials file keeps access keys in plain text. Nothing here returns, logs or sends a
//!   secret access key or a session token: a profile says only its kind of credential and the last
//!   four characters of its access key id. Errors are fixed codes, never the CLI's own text.
//! - Every write is explicit (`confirmed`), backs the file up first (dated, 0600, in Stack's folder)
//!   and replaces it atomically with mode 0600, editing only the lines it changes (`ini.rs`).
//! - AWS CLI runs without a shell, with separate arguments, a small environment and a time limit.
//! - Keys the user chooses to keep in the Keychain are read only by `helper.rs`, the credential
//!   process the CLI itself starts.

mod cli;
mod edit;
pub mod helper;
mod ini;
mod keychain;
mod profiles;

use crate::core::{fsutil, store::Store, time, watch as core_watch};
use anyhow::{ensure, Result};
use serde_json::{json, Value};
use std::{
    fs,
    os::unix::fs::PermissionsExt,
    path::{Path, PathBuf},
};

/// The two files of AWS CLI and the home whose `.aws/sso/cache` holds its sign-in sessions.
pub struct Files {
    pub config: PathBuf,
    pub credentials: PathBuf,
    pub home: PathBuf,
}

/// Larger files are not AWS CLI's own: they are not read.
const MAX_FILE: u64 = 1_048_576;
/// Backups kept of each file.
const BACKUPS: usize = 20;
/// Days a backup is kept.
const BACKUP_DAYS: u64 = 30;

impl Files {
    /// As the CLI finds them: the environment's files, or `.aws` in the home (BUTAKE_DEVTOOLS_HOME
    /// in tests and QA, so the owner's files are never looked at there).
    pub fn from_environment() -> Result<Self> {
        let home = crate::runtimes::utilities::devtools::home()?;
        let pick = |variable: &str, default: &str| -> PathBuf {
            match std::env::var(variable) {
                Ok(value) if !value.trim().is_empty() => match value.strip_prefix("~/") {
                    Some(rest) => home.join(rest),
                    None => PathBuf::from(value),
                },
                _ => home.join(default),
            }
        };
        Ok(Self {
            config: pick("AWS_CONFIG_FILE", ".aws/config"),
            credentials: pick("AWS_SHARED_CREDENTIALS_FILE", ".aws/credentials"),
            home,
        })
    }

    pub fn sso_cache(&self) -> PathBuf {
        self.home.join(".aws/sso/cache")
    }
}

/// A file as text; a missing one is empty. Too large or not text: `aws_file_unreadable`.
pub fn read(path: &Path) -> Result<String> {
    let metadata = match fs::metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(String::new()),
        Err(_) => anyhow::bail!("aws_file_unreadable"),
    };
    ensure!(
        metadata.is_file() && metadata.len() <= MAX_FILE,
        "aws_file_unreadable"
    );
    String::from_utf8(fs::read(path).map_err(|_| anyhow::anyhow!("aws_file_unreadable"))?)
        .map_err(|_| anyhow::anyhow!("aws_file_unreadable"))
}

/// Keys whose values never go to a backup: the copy would outlive the key the user deleted.
const SECRET_KEYS: [&str; 3] = [
    "aws_secret_access_key",
    "aws_session_token",
    "aws_security_token",
];

/// `text` with the value of every secret key replaced; the rest of the file is as it was.
fn without_secrets(text: &str) -> String {
    text.split_inclusive('\n')
        .map(|line| {
            let key = line.split(['=', ':']).next().unwrap_or("").trim();
            match (
                SECRET_KEYS.iter().any(|s| key.eq_ignore_ascii_case(s)),
                line.find(['=', ':']),
            ) {
                (true, Some(at)) => {
                    let end = if line.ends_with('\n') { "\n" } else { "" };
                    format!("{} = <removed by Stack>{end}", line[..at].trim_end())
                }
                _ => line.to_string(),
            }
        })
        .collect()
}

/// Copies the file as it is now, without its secret keys, to Stack's folder
/// (`aws-backups/<config|credentials>-<date>.bak`, 0600) and keeps the last [`BACKUPS`] of each,
/// none older than [`BACKUP_DAYS`] days. It is a record of what changed, not a way to get a key back.
fn backup(store: &Store, path: &Path, kind: &str) -> Result<()> {
    let Ok(bytes) = fs::read(path) else {
        return Ok(());
    };
    // A file that is not text cannot be cleaned, so it is not copied.
    let Ok(text) = String::from_utf8(bytes) else {
        return Ok(());
    };
    let bytes = without_secrets(&text).into_bytes();
    let folder = store.directory("aws-backups")?;
    let stamp = time::utc_stamp(time::now_secs());
    let mut target = folder.join(format!("{kind}-{stamp}.bak"));
    let mut index = 2;
    while target.exists() {
        target = folder.join(format!("{kind}-{stamp}-{index}.bak"));
        index += 1;
    }
    fsutil::write_private_bytes(&target, &bytes)?;
    let mut kept: Vec<PathBuf> = fs::read_dir(&folder)?
        .filter_map(|e| e.ok().map(|e| e.path()))
        .filter(|p| {
            p.file_name()
                .and_then(|n| n.to_str())
                .is_some_and(|n| n.starts_with(&format!("{kind}-")) && n.ends_with(".bak"))
        })
        .collect();
    kept.sort();
    while kept.len() > BACKUPS {
        let _ = fs::remove_file(kept.remove(0));
    }
    // Copies from before this cleaning (with keys) are removed with the old ones.
    let limit = std::time::Duration::from_secs(BACKUP_DAYS * 86_400);
    for old in kept.iter().filter(|p| {
        fs::metadata(p)
            .and_then(|m| m.modified())
            .ok()
            .and_then(|t| t.elapsed().ok())
            .is_some_and(|age| age > limit)
    }) {
        let _ = fs::remove_file(old);
    }
    Ok(())
}

/// Writes `text` over the file when it changed: backup first, then an atomic private write. A
/// link (the file kept elsewhere) is followed, so the link stays and its target is replaced.
fn save(store: &Store, path: &Path, before: &str, text: &str, kind: &str) -> Result<()> {
    if before == text {
        return Ok(());
    }
    backup(store, path, kind)?;
    let target = fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf());
    if let Some(folder) = target.parent() {
        if !folder.exists() {
            fs::create_dir_all(folder)?;
            fs::set_permissions(folder, fs::Permissions::from_mode(0o700))?;
        }
    }
    fsutil::write_private(&target, text)
}

/// Requests of the AWS tool (`aws*`); the caller checked that the tool is on.
pub fn dispatch(store: &Store, method: &str, request: &Value) -> Result<Value> {
    let files = Files::from_environment()?;
    // A run of AWS CLI whose engine died without ending it (see core/watch.rs) ends now.
    core_watch::reap(&store.directory("aws-runs")?);
    let name = request["name"].as_str().unwrap_or("");
    let secrets = keychain::Keychain;
    let helper = helper::program();
    let writes = [
        "awsCreateProfile",
        "awsUpdateProfile",
        "awsDuplicateProfile",
        "awsDeleteProfile",
        "awsSetDefault",
        "awsRepairHelper",
        "awsSsoLogout",
    ];
    if writes.contains(&method) {
        ensure!(request["confirmed"] == true, "confirmation_required");
    }
    let changes = edit::Changes {
        store,
        files: &files,
        secrets: &secrets,
        helper: helper.as_deref(),
    };
    match method {
        "awsProfiles" => profiles::list(store, &files, helper.as_deref()),
        "awsCreateProfile" => {
            changes.create(
                serde_json::from_value(request["profile"].clone())
                    .map_err(|_| anyhow::anyhow!("aws_invalid_profile"))?,
                request.get("keys").and_then(edit::Keys::from_request),
                request["storage"].as_str() == Some("keychain"),
            )?;
            profiles::list(store, &files, helper.as_deref())
        }
        "awsUpdateProfile" => {
            changes.update(
                name,
                serde_json::from_value(request["profile"].clone())
                    .map_err(|_| anyhow::anyhow!("aws_invalid_profile"))?,
            )?;
            profiles::list(store, &files, helper.as_deref())
        }
        "awsDuplicateProfile" => {
            changes.duplicate(name, request["newName"].as_str().unwrap_or(""))?;
            profiles::list(store, &files, helper.as_deref())
        }
        "awsDeleteProfile" => {
            changes.delete(name)?;
            profiles::list(store, &files, helper.as_deref())
        }
        "awsSetDefault" => {
            changes.set_default(name, request["previous"].as_str())?;
            profiles::list(store, &files, helper.as_deref())
        }
        "awsRepairHelper" => {
            changes.repair(name)?;
            profiles::list(store, &files, helper.as_deref())
        }
        "awsCheck" => cli::check(&files, &store.directory("aws-runs")?, name),
        "awsSsoLogin" => {
            cli::sso_login(&files, &store.directory("aws-runs")?, name)?;
            profiles::list(store, &files, helper.as_deref())
        }
        "awsSsoLogout" => {
            cli::sso_logout(&files, &store.directory("aws-runs")?)?;
            profiles::list(store, &files, helper.as_deref())
        }
        _ => anyhow::bail!("unknown_method"),
    }
}

/// AWS CLI on this Mac (or its absence) and how long «Iniciar sesión…» waits for the user.
pub fn cli_status() -> Value {
    let path = cli::program();
    json!({"installed": path.is_some(), "path": path, "signInLimit": cli::sign_in_limit().as_secs()})
}

#[cfg(test)]
mod backup_tests {
    use super::*;

    #[test]
    fn backups_keep_the_file_but_not_its_secret_values() {
        let sentinel = "centinela-secreta-7d41";
        let text = format!(
            "[default]\naws_access_key_id = AKIAEJEMPLO\naws_secret_access_key = {sentinel}\nAWS_SESSION_TOKEN={sentinel}\nregion = us-east-1"
        );
        let clean = without_secrets(&text);
        assert!(!clean.contains(sentinel));
        assert!(clean.contains("[default]") && clean.contains("AKIAEJEMPLO"));
        assert!(clean.contains("region = us-east-1"));
        assert!(clean.contains("aws_secret_access_key = <removed by Stack>\n"));
    }

    #[test]
    fn the_backup_file_on_disk_has_no_secret() {
        let temp = tempfile::tempdir().unwrap();
        let store = Store::new(temp.path().join("store")).unwrap();
        let credentials = temp.path().join("credentials");
        fs::write(
            &credentials,
            "[p]\naws_secret_access_key = centinela-secreta-7d41\n",
        )
        .unwrap();
        backup(&store, &credentials, "credentials").unwrap();
        let folder = store.directory("aws-backups").unwrap();
        let copies: Vec<_> = fs::read_dir(folder).unwrap().flatten().collect();
        assert_eq!(copies.len(), 1);
        let copy = fs::read_to_string(copies[0].path()).unwrap();
        assert!(!copy.contains("centinela-secreta") && copy.contains("[p]"));
    }
}
