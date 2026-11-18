//! Environments of a site's `.env` (Local, Pruebas, Staging, Producción…).
//!
//! Security model (privacy requirements R1 to R12):
//! - The store keeps keys and **non-secret** values only. Secret values live in the macOS Keychain,
//!   owned by the app; they reach the engine only on activation, through stdin, in memory (R1, R6).
//! - Nothing here prints, logs or returns a secret value; errors carry no values (R6).
//! - The `.env` is written atomically with mode 600, only inside the site folder, never through a
//!   symlink, and secrets are refused while `.env` is tracked by Git or not ignored (R5).
//! - Production is locked by default: activating it needs explicit confirmation, and while it is
//!   active the site's processes do not start on their own (R4).
//! - Every action is appended to a local audit log without values, kept 180 days (R7).
mod dotenv;
mod ports;

pub use dotenv::*;
pub use ports::*;

use crate::core::fsutil::private_options;
use crate::core::fsutil::write_private;
use crate::core::json;
use crate::core::time::now_secs;
use crate::{core::model::Project, core::store::Store};
use anyhow::{Result, bail, ensure};
use serde::{Deserialize, Serialize};
use std::{collections::BTreeMap, fs, io::Write, path::PathBuf, process::Stdio};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "lowercase")]
pub enum Kind {
    Local,
    Development,
    Testing,
    Staging,
    Production,
    Other,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct Entry {
    pub key: String,
    /// Empty for secrets: their value is in the Keychain.
    #[serde(default)]
    pub value: String,
    pub secret: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct Environment {
    pub id: String,
    pub name: String,
    pub kind: Kind,
    pub entries: Vec<Entry>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct SiteEnvironments {
    #[serde(default)]
    pub active: Option<String>,
    #[serde(default)]
    pub environments: Vec<Environment>,
    /// The site's processes start with the active environment (the `.env` Stack wrote) in their
    /// environment. On by default.
    #[serde(default = "yes", rename = "passToProcesses")]
    pub pass_to_processes: bool,
    /// Projects named by `{port:<id>}` in the active environment whose port changed (or that are
    /// gone) since Stack wrote the `.env`, when the engine could not write it again by itself
    /// (the environment has secrets, which only the app's Keychain holds). Activating it again
    /// clears the list. Kept by the engine: a save from the app never changes it.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub outdated: Vec<String>,
}

fn yes() -> bool {
    true
}

impl Default for SiteEnvironments {
    fn default() -> Self {
        Self {
            active: None,
            environments: vec![],
            pass_to_processes: true,
            outdated: vec![],
        }
    }
}

/// The first line of every `.env` Stack writes; only such a file reaches the site's processes.
const HEADER_START: &str = "# Entorno «";
const HEADER_END: &str = "» aplicado por Stack. Edítalo en la app.";

/// Key names that suggest a credential are secrets by default (R2).
pub fn looks_secret(key: &str) -> bool {
    let key = key.to_ascii_uppercase();
    [
        "PASSWORD",
        "PASS",
        "SECRET",
        "KEY",
        "TOKEN",
        "PRIVATE",
        "DSN",
        "CREDENTIAL",
        "AUTH",
        "SALT",
        "CERT",
    ]
    .iter()
    .any(|w| key.contains(w))
}

pub fn validate_key(key: &str) -> Result<()> {
    ensure!(
        !key.is_empty()
            && key.len() <= 128
            && key
                .bytes()
                .all(|c| c.is_ascii_alphanumeric() || c == b'_' || c == b'.')
            && !key.as_bytes()[0].is_ascii_digit(),
        "invalid_env_key"
    );
    Ok(())
}

fn validate(site: &SiteEnvironments) -> Result<()> {
    let mut ids = std::collections::HashSet::new();
    for env in &site.environments {
        crate::core::model::validate_id(&env.id)?;
        ensure!(ids.insert(&env.id), "duplicate_environment");
        ensure!(
            !env.name.trim().is_empty()
                && env.name.len() <= 60
                && !env.name.chars().any(char::is_control),
            "invalid_environment_name"
        );
        let mut keys = std::collections::HashSet::new();
        for entry in &env.entries {
            validate_key(&entry.key)?;
            ensure!(keys.insert(&entry.key), "duplicate_env_key");
            // A secret never sits in the store (R1); a non-secret value is one line.
            ensure!(!entry.secret || entry.value.is_empty(), "secret_in_store");
            ensure!(
                entry.value.len() <= 8192
                    && !entry.value.contains('\0')
                    && !entry.value.contains('\n'),
                "invalid_env_value"
            );
        }
    }
    if let Some(active) = &site.active {
        ensure!(
            site.environments.iter().any(|e| &e.id == active),
            "unknown_environment"
        );
    }
    Ok(())
}

fn path(store: &Store, id: &str) -> Result<PathBuf> {
    crate::core::model::validate_id(id)?;
    Ok(store.directory("envs")?.join(format!("{id}.json")))
}

pub fn load(store: &Store, id: &str) -> Result<SiteEnvironments> {
    let file = path(store, id)?;
    if !file.exists() {
        return Ok(SiteEnvironments::default());
    }
    let site: SiteEnvironments = json::read_regular(&file, Some(1_048_576))?;
    validate(&site)?;
    Ok(site)
}

pub fn save(store: &Store, id: &str, site: &SiteEnvironments, actor: &str) -> Result<()> {
    store.get(id)?;
    validate(site)?;
    // Whether the written `.env` is out of date is the engine's to say, not the request's.
    let mut site = site.clone();
    site.outdated = load(store, id)?.outdated;
    let site = &site;
    // A `{port:<id>}` must name a project with a port, and a `{public:<id>}` a project (its fixed
    // address may come later), so the mistake shows when saving.
    let projects = store.list()?;
    for env in &site.environments {
        for entry in &env.entries {
            crate::core::model::fill_project_ports(&entry.value, &projects)?;
            for named in crate::core::model::public_references(&entry.value) {
                ensure!(
                    projects.iter().any(|p| p.id == named),
                    "unknown_public_project"
                );
            }
        }
    }
    json::write(&path(store, id)?, site)?;
    audit(store, id, "", "guardar", "", actor)?;
    Ok(())
}

pub fn delete_environment(
    store: &Store,
    id: &str,
    env: &str,
    actor: &str,
) -> Result<SiteEnvironments> {
    let mut site = load(store, id)?;
    ensure!(site.active.as_deref() != Some(env), "environment_active");
    let before = site.environments.len();
    site.environments.retain(|e| e.id != env);
    ensure!(site.environments.len() < before, "unknown_environment");
    json::write(&path(store, id)?, &site)?;
    audit(store, id, env, "eliminar", "", actor)?;
    Ok(site)
}

/// Variables moved in from the app's vault (an old `.env` kept there): each key becomes a secret of
/// the environment, added or replaced, with no value in the store, because the app put its value in
/// the Keychain first (R1). A missing environment is created with `create` (name and kind). Only the
/// keys change; the rest of the environments stays as it was. Each key is audited as «mover»,
/// without its value (R7).
pub fn merge_secret_keys(
    store: &Store,
    id: &str,
    env: &str,
    keys: &[String],
    create: Option<(&str, Kind)>,
    actor: &str,
) -> Result<SiteEnvironments> {
    store.get(id)?;
    crate::core::model::validate_id(env)?;
    ensure!(!keys.is_empty() && keys.len() <= 500, "invalid_env_key");
    let mut unique: Vec<&String> = Vec::with_capacity(keys.len());
    for key in keys {
        validate_key(key)?;
        if !unique.contains(&key) {
            unique.push(key);
        }
    }
    let mut site = load(store, id)?;
    let position = match site.environments.iter().position(|e| e.id == env) {
        Some(position) => position,
        None => {
            let Some((name, kind)) = create else {
                bail!("unknown_environment")
            };
            site.environments.push(Environment {
                id: env.to_string(),
                name: name.trim().to_string(),
                kind,
                entries: Vec::new(),
            });
            site.environments.len() - 1
        }
    };
    let entries = &mut site.environments[position].entries;
    for key in &unique {
        match entries.iter_mut().find(|e| &e.key == *key) {
            Some(entry) => {
                entry.value.clear();
                entry.secret = true;
            }
            None => entries.push(Entry {
                key: (*key).clone(),
                value: String::new(),
                secret: true,
            }),
        }
    }
    validate(&site)?;
    json::write(&path(store, id)?, &site)?;
    for key in unique {
        audit(store, id, env, "mover", key, actor)?;
    }
    Ok(site)
}

/// Whether project `id` has environments of its own (and so, maybe, secrets in the Keychain).
pub fn exists(store: &Store, id: &str) -> bool {
    path(store, id).is_ok_and(|file| file.is_file())
}

/// A project renamed (P-41): its environments go to the new id, and every environment that names
/// it with `{port:<from>}` or `{public:<from>}`, or lists it as `outdated`, names the new one. The
/// values of secrets are in the Keychain and are never seen here. Returns the projects whose
/// environments changed.
pub fn rename_project(
    journal: &mut crate::core::journal::Journal,
    store: &Store,
    from: &str,
    to: &str,
) -> Result<Vec<String>> {
    let (old, new) = (path(store, from)?, path(store, to)?);
    ensure!(!new.exists(), "id_in_use");
    let mut changed = vec![];
    if old.exists() {
        journal.rename(&old, &new)?;
        changed.push(to.to_string());
    }
    for entry in fs::read_dir(store.directory("envs")?)? {
        let file = entry?.path();
        let Some(id) = file
            .file_stem()
            .and_then(|s| s.to_str())
            .filter(|_| file.extension().is_some_and(|e| e == "json"))
            .map(str::to_string)
        else {
            continue;
        };
        if crate::core::model::validate_id(&id).is_err() {
            continue;
        }
        // A file that does not read is left as it is: the rename never depends on it.
        let Ok(mut site) = load(store, &id) else {
            continue;
        };
        let before = site.clone();
        for env in &mut site.environments {
            for entry in &mut env.entries {
                entry.value = crate::core::model::rename_references(&entry.value, from, to);
            }
        }
        for named in &mut site.outdated {
            if named == from {
                *named = to.to_string();
            }
        }
        if site != before {
            journal.write_json(&file, &site)?;
            if !changed.contains(&id) {
                changed.push(id);
            }
        }
    }
    changed.sort();
    Ok(changed)
}

/// The audit lines of a renamed project carry its new id, so its history follows it (no value is
/// read or written: the lines hold none).
pub fn rename_audit(
    journal: &mut crate::core::journal::Journal,
    store: &Store,
    from: &str,
    to: &str,
) -> Result<()> {
    let file = store.directory("logs")?.join("env-audit.log");
    let Ok(text) = fs::read_to_string(&file) else {
        return Ok(());
    };
    let mut touched = false;
    let lines: Vec<String> = text
        .lines()
        .map(
            |line| match serde_json::from_str::<serde_json::Value>(line) {
                Ok(mut value) if value["site"] == from => {
                    value["site"] = serde_json::json!(to);
                    touched = true;
                    value.to_string()
                }
                _ => line.to_string(),
            },
        )
        .collect();
    if touched {
        journal.write_bytes(&file, (lines.join("\n") + "\n").as_bytes())?;
    }
    Ok(())
}

/// Production active on a site: its processes must not start on their own (R4).
pub fn production_active(store: &Store, id: &str) -> bool {
    load(store, id)
        .ok()
        .and_then(|site| {
            let active = site.active.clone()?;
            site.environments.into_iter().find(|e| e.id == active)
        })
        .is_some_and(|env| env.kind == Kind::Production)
}

#[derive(Debug, Serialize, PartialEq)]
pub struct GitGuard {
    /// `.env` is ignored by Git (or the site is not a repository).
    pub ignored: bool,
    /// `.env` is already committed: secrets must not be written there.
    pub tracked: bool,
    pub repository: bool,
}

pub fn git_guard(project: &Project) -> GitGuard {
    if !crate::web::projects::git::is_repository(&project.path) {
        return GitGuard {
            ignored: true,
            tracked: false,
            repository: false,
        };
    }
    let run = |args: &[&str]| {
        crate::web::projects::git::command(&project.path)
            .args(args)
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .is_ok_and(|s| s.success())
    };
    GitGuard {
        ignored: run(&["check-ignore", "-q", ".env"]),
        tracked: run(&["ls-files", "--error-unmatch", "--", ".env"]),
        repository: true,
    }
}

/// One `.env` line, written so dotenv (vlucas/phpdotenv, the Node and Python ports) reads back
/// exactly the same value:
/// - plain values stay bare;
/// - `${OTHER}` references keep working inside double quotes;
/// - any other `$` is literal, so the value goes in single quotes (no interpolation there);
/// - otherwise double quotes with `\` and `"` escaped.
pub fn line(key: &str, value: &str) -> String {
    let plain = !value.is_empty()
        && value
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || "_-.:/@,+=%~".contains(c));
    if value.is_empty() || plain {
        format!("{key}={value}")
    } else if value.contains("${") {
        format!(
            "{key}=\"{}\"",
            value.replace('\\', "\\\\").replace('"', "\\\"")
        )
    } else if value.contains('$') && !value.contains('\'') {
        format!("{key}='{value}'")
    } else {
        let escaped = value
            .replace('\\', "\\\\")
            .replace('"', "\\\"")
            .replace('$', "\\$");
        format!("{key}=\"{escaped}\"")
    }
}

pub fn render(env: &Environment, secrets: &BTreeMap<String, String>) -> Result<String> {
    let mut out = format!("{HEADER_START}{}{HEADER_END}\n", env.name);
    for entry in &env.entries {
        let value = if entry.secret {
            secrets.get(&entry.key).map(String::as_str).unwrap_or("")
        } else {
            entry.value.as_str()
        };
        ensure!(
            !value.contains('\0') && !value.contains('\n') && value.len() <= 65_536,
            "invalid_env_value"
        );
        out.push_str(&line(&entry.key, value));
        out.push('\n');
    }
    Ok(out)
}

/// Writes the environment as the site's `.env`, then clears Laravel's caches and restarts the site's
/// processes. `secrets` comes from the app's Keychain through stdin and is dropped afterwards.
pub fn activate(
    store: &Store,
    id: &str,
    env_id: &str,
    secrets: &BTreeMap<String, String>,
    confirmed_production: bool,
    actor: &str,
) -> Result<SiteEnvironments> {
    let project = store.get(id)?;
    let mut site = load(store, id)?;
    let env = site
        .environments
        .iter()
        .find(|e| e.id == env_id)
        .cloned()
        .ok_or_else(|| anyhow::anyhow!("unknown_environment"))?;
    if env.kind == Kind::Production && !confirmed_production {
        bail!("production_locked");
    }
    for key in secrets.keys() {
        ensure!(
            env.entries.iter().any(|e| e.secret && &e.key == key),
            "unexpected_secret"
        );
    }
    let Filled {
        ref env,
        ref secrets,
    } = with_ports(store, &env, secrets)?;
    let guard = git_guard(&project);
    if env.entries.iter().any(|e| e.secret) {
        ensure!(!guard.tracked, "env_tracked_by_git");
        ensure!(guard.ignored, "env_not_ignored");
    }
    let target = project.path.join(".env");
    if let Ok(meta) = fs::symlink_metadata(&target) {
        ensure!(
            !meta.file_type().is_symlink() && meta.is_file(),
            "unsafe_env_path"
        );
    }
    ensure!(
        target.parent() == Some(project.path.as_path()),
        "unsafe_env_path"
    );
    write_private(&target, &render(env, secrets)?)?;
    site.active = Some(env.id.clone());
    site.outdated.clear();
    json::write(&path(store, id)?, &site)?;
    audit(store, id, &env.id, "activar", "", actor)?;
    // Laravel: a cached config would keep the old values.
    if project.path.join("artisan").exists()
        && let Ok(chain) = crate::web::projects::scaffold::Toolchain::new(
            store,
            project.runtime.get("php").map(String::as_str),
            None,
            &format!("env-{id}"),
        )
    {
        let _ = chain.runner.run(
            &project.path,
            &chain.php,
            &["artisan", "optimize:clear", "--no-interaction"],
        );
    }
    Ok(site)
}

/// Downloads an environment as a `.env` file chosen by the user (R9, as revised): explicit,
/// authenticated by the app, written atomically with mode 600, never through a symlink, refused
/// inside a Git repository unless the file is ignored, and audited (without values).
pub fn export(
    store: &Store,
    id: &str,
    env_id: &str,
    secrets: &BTreeMap<String, String>,
    target: &std::path::Path,
    actor: &str,
) -> Result<()> {
    let site = load(store, id)?;
    let env = site
        .environments
        .iter()
        .find(|e| e.id == env_id)
        .ok_or_else(|| anyhow::anyhow!("unknown_environment"))?;
    for key in secrets.keys() {
        ensure!(
            env.entries.iter().any(|e| e.secret && &e.key == key),
            "unexpected_secret"
        );
    }
    ensure!(target.is_absolute(), "invalid_path");
    let name = target.file_name().and_then(|n| n.to_str()).unwrap_or("");
    ensure!(
        name.starts_with(".env") && !name.contains('/'),
        "invalid_path"
    );
    let parent = target
        .parent()
        .ok_or_else(|| anyhow::anyhow!("invalid_path"))?
        .canonicalize()?;
    ensure!(parent.is_dir(), "invalid_path");
    let target = parent.join(name);
    if let Ok(meta) = fs::symlink_metadata(&target) {
        ensure!(
            !meta.file_type().is_symlink() && meta.is_file(),
            "unsafe_env_path"
        );
    }
    // Inside a repository the file must be ignored, so it cannot be committed by accident.
    let inside_repo = crate::web::projects::git::command(&parent)
        .args(["rev-parse", "--is-inside-work-tree"])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .is_ok_and(|s| s.success());
    if inside_repo {
        let ignored = crate::web::projects::git::command(&parent)
            .args(["check-ignore", "-q", "--"])
            .arg(name)
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .is_ok_and(|s| s.success());
        ensure!(ignored, "export_not_ignored");
    }
    let Filled { env, secrets } = with_ports(store, env, secrets)?;
    write_private(&target, &render(&env, &secrets)?)?;
    audit(store, id, env_id, "exportar", "", actor)
}

/// Appends one audit line (no values, ever) and keeps only the last 180 days (R7).
pub fn audit(
    store: &Store,
    id: &str,
    env: &str,
    action: &str,
    key: &str,
    actor: &str,
) -> Result<()> {
    ensure!(
        [
            "guardar",
            "activar",
            "eliminar",
            "revelar",
            "copiar",
            "importar",
            "exportar",
            "mover",
            "actualizar",
            "renombrar"
        ]
        .contains(&action),
        "invalid_action"
    );
    if !key.is_empty() {
        validate_key(key)?;
    }
    if !env.is_empty() {
        crate::core::model::validate_id(env)?;
    }
    let actor: String = actor
        .chars()
        .filter(|c| c.is_alphanumeric() || *c == '.' || *c == '_' || *c == '-')
        .take(64)
        .collect();
    let file = store.directory("logs")?.join("env-audit.log");
    let now = now_secs();
    let entry = serde_json::json!({"ts": now, "site": id, "env": env, "action": action, "key": key, "user": actor});
    let keep_after = now.saturating_sub(180 * 24 * 3600);
    let mut lines: Vec<String> = fs::read_to_string(&file)
        .unwrap_or_default()
        .lines()
        .filter(|l| {
            serde_json::from_str::<serde_json::Value>(l)
                .ok()
                .and_then(|v| v["ts"].as_u64())
                .is_some_and(|ts| ts >= keep_after)
        })
        .map(str::to_string)
        .collect();
    lines.push(entry.to_string());
    let mut out = private_options().create(true).truncate(true).open(&file)?;
    out.write_all((lines.join("\n") + "\n").as_bytes())?;
    Ok(())
}

pub fn audit_lines(store: &Store, id: &str) -> Result<Vec<serde_json::Value>> {
    crate::core::model::validate_id(id)?;
    let file = store.directory("logs")?.join("env-audit.log");
    Ok(fs::read_to_string(file)
        .unwrap_or_default()
        .lines()
        .filter_map(|l| serde_json::from_str::<serde_json::Value>(l).ok())
        .filter(|v| v["site"] == id)
        .rev()
        .take(200)
        .collect())
}

/// Reads only test fixtures written by the environment activation test.
#[cfg(test)]
fn read_dotenv(path: &std::path::Path) -> BTreeMap<String, String> {
    let ok = fs::symlink_metadata(path).is_ok_and(|m| m.is_file() && m.len() <= 1_048_576);
    parse_dotenv(&if ok {
        fs::read_to_string(path).unwrap_or_default()
    } else {
        String::new()
    })
}

/// Keys declared in the site's `.env.example` (names only), to spot missing ones.
pub fn example_keys(project: &Project) -> Vec<String> {
    // At most 1 MiB, like every other `.env` the engine reads; a larger file says nothing.
    crate::web::projects::detect::read_small(&project.path.join(".env.example"), 1_048_576)
        .unwrap_or_default()
        .lines()
        .filter_map(|l| {
            let l = l.trim().trim_start_matches("export ").trim();
            if l.starts_with('#') {
                return None;
            }
            let key = l.split('=').next()?.trim();
            (l.contains('=') && validate_key(key).is_ok()).then(|| key.to_string())
        })
        .collect()
}

#[cfg(test)]
fn env_path(project: &Project) -> PathBuf {
    project.path.join(".env")
}

#[cfg(test)]
mod tests;
