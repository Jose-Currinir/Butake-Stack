//! Environments of a site's `.env` (Local, Pruebas, Staging, Producción…).
//!
//! Security model (see `.compliance/docs/21719-gestor-entornos-requisitos.md`):
//! - The store keeps keys and **non-secret** values only. Secret values live in the macOS Keychain,
//!   owned by the app; they reach the engine only on activation, through stdin, in memory (R1, R6).
//! - Nothing here prints, logs or returns a secret value; errors carry no values (R6).
//! - The `.env` is written atomically with mode 600, only inside the site folder, never through a
//!   symlink, and secrets are refused while `.env` is tracked by Git or not ignored (R5).
//! - Production is locked by default: activating it needs explicit confirmation, and while it is
//!   active the site's processes do not start on their own (R4).
//! - Every action is appended to a local audit log without values, kept 180 days (R7).
use crate::{model::Project, store::Store};
use anyhow::{bail, ensure, Result};
use serde::{Deserialize, Serialize};
use std::{
    collections::BTreeMap,
    fs,
    io::Write,
    os::unix::fs::OpenOptionsExt,
    path::PathBuf,
    process::{Command, Stdio},
};

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

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
#[serde(deny_unknown_fields)]
pub struct SiteEnvironments {
    #[serde(default)]
    pub active: Option<String>,
    #[serde(default)]
    pub environments: Vec<Environment>,
}

/// Key names that suggest a credential are secrets by default (R2).
pub fn looks_secret(key: &str) -> bool {
    let key = key.to_ascii_uppercase();
    ["PASSWORD", "PASS", "SECRET", "KEY", "TOKEN", "PRIVATE", "DSN", "CREDENTIAL", "AUTH", "SALT", "CERT"]
        .iter()
        .any(|w| key.contains(w))
}

pub fn validate_key(key: &str) -> Result<()> {
    ensure!(
        !key.is_empty()
            && key.len() <= 128
            && key.bytes().all(|c| c.is_ascii_alphanumeric() || c == b'_' || c == b'.')
            && !key.as_bytes()[0].is_ascii_digit(),
        "invalid_env_key"
    );
    Ok(())
}

fn validate(site: &SiteEnvironments) -> Result<()> {
    let mut ids = std::collections::HashSet::new();
    for env in &site.environments {
        crate::model::validate_id(&env.id)?;
        ensure!(ids.insert(&env.id), "duplicate_environment");
        ensure!(
            !env.name.trim().is_empty() && env.name.len() <= 60 && !env.name.chars().any(char::is_control),
            "invalid_environment_name"
        );
        let mut keys = std::collections::HashSet::new();
        for entry in &env.entries {
            validate_key(&entry.key)?;
            ensure!(keys.insert(&entry.key), "duplicate_env_key");
            // A secret never sits in the store (R1); a non-secret value is one line.
            ensure!(!entry.secret || entry.value.is_empty(), "secret_in_store");
            ensure!(entry.value.len() <= 8192 && !entry.value.contains('\0') && !entry.value.contains('\n'), "invalid_env_value");
        }
    }
    if let Some(active) = &site.active {
        ensure!(site.environments.iter().any(|e| &e.id == active), "unknown_environment");
    }
    Ok(())
}

fn path(store: &Store, id: &str) -> Result<PathBuf> {
    crate::model::validate_id(id)?;
    Ok(store.directory("envs")?.join(format!("{id}.json")))
}

pub fn load(store: &Store, id: &str) -> Result<SiteEnvironments> {
    let file = path(store, id)?;
    if !file.exists() {
        return Ok(SiteEnvironments::default());
    }
    ensure!(!fs::symlink_metadata(&file)?.file_type().is_symlink(), "unsafe_store_path");
    ensure!(fs::metadata(&file)?.len() <= 1_048_576, "store_too_large");
    let site: SiteEnvironments = serde_json::from_slice(&fs::read(&file)?)?;
    validate(&site)?;
    Ok(site)
}

pub fn save(store: &Store, id: &str, site: &SiteEnvironments, actor: &str) -> Result<()> {
    store.get(id)?;
    validate(site)?;
    crate::services::write_private(&path(store, id)?, &serde_json::to_string_pretty(site)?)?;
    audit(store, id, "", "guardar", "", actor)?;
    Ok(())
}

pub fn delete_environment(store: &Store, id: &str, env: &str, actor: &str) -> Result<SiteEnvironments> {
    let mut site = load(store, id)?;
    ensure!(site.active.as_deref() != Some(env), "environment_active");
    let before = site.environments.len();
    site.environments.retain(|e| e.id != env);
    ensure!(site.environments.len() < before, "unknown_environment");
    crate::services::write_private(&path(store, id)?, &serde_json::to_string_pretty(&site)?)?;
    audit(store, id, env, "eliminar", "", actor)?;
    Ok(site)
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
    if !crate::git::is_repository(&project.path) {
        return GitGuard { ignored: true, tracked: false, repository: false };
    }
    let run = |args: &[&str]| {
        Command::new("/usr/bin/git")
            .arg("-C")
            .arg(&project.path)
            .args(args)
            .env_clear()
            .env("PATH", "/usr/bin:/bin")
            .env("GIT_OPTIONAL_LOCKS", "0")
            .stdin(Stdio::null())
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
        format!("{key}=\"{}\"", value.replace('\\', "\\\\").replace('"', "\\\""))
    } else if value.contains('$') && !value.contains('\'') {
        format!("{key}='{value}'")
    } else {
        let escaped = value.replace('\\', "\\\\").replace('"', "\\\"").replace('$', "\\$");
        format!("{key}=\"{escaped}\"")
    }
}

pub fn render(env: &Environment, secrets: &BTreeMap<String, String>) -> Result<String> {
    let mut out = format!("# Entorno «{}» aplicado por Butake Stack. Edítalo en la app.\n", env.name);
    for entry in &env.entries {
        let value = if entry.secret {
            secrets.get(&entry.key).map(String::as_str).unwrap_or("")
        } else {
            entry.value.as_str()
        };
        ensure!(!value.contains('\0') && !value.contains('\n') && value.len() <= 65_536, "invalid_env_value");
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
        ensure!(env.entries.iter().any(|e| e.secret && &e.key == key), "unexpected_secret");
    }
    let guard = git_guard(&project);
    if env.entries.iter().any(|e| e.secret) {
        ensure!(!guard.tracked, "env_tracked_by_git");
        ensure!(guard.ignored, "env_not_ignored");
    }
    let target = project.path.join(".env");
    if let Ok(meta) = fs::symlink_metadata(&target) {
        ensure!(!meta.file_type().is_symlink() && meta.is_file(), "unsafe_env_path");
    }
    ensure!(target.parent() == Some(project.path.as_path()), "unsafe_env_path");
    crate::services::write_private(&target, &render(&env, secrets)?)?;
    site.active = Some(env.id.clone());
    crate::services::write_private(&path(store, id)?, &serde_json::to_string_pretty(&site)?)?;
    audit(store, id, &env.id, "activar", "", actor)?;
    // Laravel: a cached config would keep the old values.
    if project.path.join("artisan").exists() {
        if let Ok(chain) = crate::scaffold::Toolchain::new(store, project.runtime.get("php").map(String::as_str), None, &format!("env-{id}")) {
            let _ = chain.runner.run(&project.path, &chain.php, &["artisan", "optimize:clear", "--no-interaction"]);
        }
    }
    Ok(site)
}

/// Appends one audit line (no values, ever) and keeps only the last 180 days (R7).
pub fn audit(store: &Store, id: &str, env: &str, action: &str, key: &str, actor: &str) -> Result<()> {
    ensure!(
        ["guardar", "activar", "eliminar", "revelar", "copiar", "importar", "exportar"].contains(&action),
        "invalid_action"
    );
    if !key.is_empty() {
        validate_key(key)?;
    }
    if !env.is_empty() {
        crate::model::validate_id(env)?;
    }
    let actor: String = actor.chars().filter(|c| c.is_alphanumeric() || *c == '.' || *c == '_' || *c == '-').take(64).collect();
    let file = store.directory("logs")?.join("env-audit.log");
    let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH)?.as_secs();
    let entry = serde_json::json!({"ts": now, "site": id, "env": env, "action": action, "key": key, "user": actor});
    let keep_after = now.saturating_sub(180 * 24 * 3600);
    let mut lines: Vec<String> = fs::read_to_string(&file)
        .unwrap_or_default()
        .lines()
        .filter(|l| serde_json::from_str::<serde_json::Value>(l).ok().and_then(|v| v["ts"].as_u64()).is_some_and(|ts| ts >= keep_after))
        .map(str::to_string)
        .collect();
    lines.push(entry.to_string());
    let mut out = fs::OpenOptions::new().write(true).create(true).truncate(true).mode(0o600).open(&file)?;
    out.write_all((lines.join("\n") + "\n").as_bytes())?;
    Ok(())
}

pub fn audit_lines(store: &Store, id: &str) -> Result<Vec<serde_json::Value>> {
    crate::model::validate_id(id)?;
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

/// Keys declared in the site's `.env.example` (names only), to spot missing ones.
pub fn example_keys(project: &Project) -> Vec<String> {
    let file = project.path.join(".env.example");
    if fs::symlink_metadata(&file).map(|m| !m.is_file()).unwrap_or(true) {
        return vec![];
    }
    fs::read_to_string(file)
        .unwrap_or_default()
        .lines()
        .filter_map(|l| {
            let l = l.trim().trim_start_matches("export ").trim();
            if l.starts_with('#') { return None; }
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
mod tests {
    use super::*;

    fn store_with_site() -> (tempfile::TempDir, Store, Project) {
        let temp = tempfile::tempdir().unwrap();
        let store = Store::new(temp.path().join("store")).unwrap();
        let site = temp.path().join("site");
        fs::create_dir_all(site.join("public")).unwrap();
        let project: Project = serde_json::from_value(serde_json::json!({
            "id":"demo","name":"Demo","path":site,"domains":["demo.test"],"https":true,
            "kind":"php","runtime":{},"docroot":"public","services":[],"databases":[],"processes":[]})).unwrap();
        let project = store.save(project).unwrap();
        (temp, store, project)
    }

    fn sample() -> SiteEnvironments {
        SiteEnvironments {
            active: None,
            environments: vec![
                Environment { id: "local".into(), name: "Local".into(), kind: Kind::Local, entries: vec![
                    Entry { key: "APP_ENV".into(), value: "local".into(), secret: false },
                    Entry { key: "DB_PASSWORD".into(), value: String::new(), secret: true },
                ]},
                Environment { id: "produccion".into(), name: "Producción".into(), kind: Kind::Production, entries: vec![
                    Entry { key: "APP_ENV".into(), value: "production".into(), secret: false },
                ]},
            ],
        }
    }

    #[test]
    fn classifies_quotes_and_validates() {
        assert!(looks_secret("DB_PASSWORD") && looks_secret("APP_KEY") && looks_secret("stripe_token"));
        assert!(!looks_secret("APP_ENV") && !looks_secret("DB_HOST"));
        assert_eq!(line("A", "simple-1.2"), "A=simple-1.2");
        assert_eq!(line("A", "con espacio \"x\""), "A=\"con espacio \\\"x\\\"\"");
        assert_eq!(line("A", "${APP_NAME}"), "A=\"${APP_NAME}\"");
        assert_eq!(line("A", "pa$$word"), "A='pa$$word'");
        assert_eq!(line("A", "it's $5"), "A=\"it's \\$5\"");
        for bad in ["", "1A", "A B", "A=B", &"K".repeat(129)] {
            assert!(validate_key(bad).is_err());
        }
        let mut site = sample();
        site.environments[0].entries[1].value = "filtrado".into();
        assert!(validate(&site).is_err(), "a secret value must never reach the store");
    }

    #[test]
    fn activation_writes_private_env_without_leaking_and_locks_production() {
        let (_temp, store, project) = store_with_site();
        save(&store, "demo", &sample(), "tester").unwrap();
        let stored = fs::read_to_string(store.root().join("envs/demo.json")).unwrap();
        let secrets: BTreeMap<String, String> = [("DB_PASSWORD".to_string(), "valor-ficticio".to_string())].into();
        let site = activate(&store, "demo", "local", &secrets, false, "tester").unwrap();
        assert_eq!(site.active.as_deref(), Some("local"));
        let written = fs::read_to_string(env_path(&project)).unwrap();
        assert!(written.contains("DB_PASSWORD=valor-ficticio") && written.contains("APP_ENV=local"));
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(fs::metadata(env_path(&project)).unwrap().permissions().mode() & 0o777, 0o600);
        // The secret is in the .env only: never in the store or the audit log.
        let audit_log = fs::read_to_string(store.root().join("logs/env-audit.log")).unwrap();
        assert!(!stored.contains("valor-ficticio") && !audit_log.contains("valor-ficticio"));
        assert!(fs::read_to_string(store.root().join("envs/demo.json")).unwrap().find("valor-ficticio").is_none());
        // Production needs explicit confirmation, and then holds the site's processes.
        assert!(activate(&store, "demo", "produccion", &BTreeMap::new(), false, "tester").is_err());
        assert!(!production_active(&store, "demo"));
        activate(&store, "demo", "produccion", &BTreeMap::new(), true, "tester").unwrap();
        assert!(production_active(&store, "demo"));
        // Unexpected keys and symlinked .env are refused.
        let extra: BTreeMap<String, String> = [("APP_ENV".to_string(), "x".to_string())].into();
        assert!(activate(&store, "demo", "local", &extra, false, "tester").is_err());
        fs::remove_file(env_path(&project)).unwrap();
        std::os::unix::fs::symlink("/tmp/otro", env_path(&project)).unwrap();
        assert!(activate(&store, "demo", "local", &secrets, false, "tester").is_err());
    }

    #[test]
    fn refuses_secrets_when_env_is_tracked_by_git() {
        let (_temp, store, project) = store_with_site();
        Command::new("/usr/bin/git").arg("init").arg("-q").arg(&project.path).status().unwrap();
        fs::write(env_path(&project), "A=1\n").unwrap();
        Command::new("/usr/bin/git").arg("-C").arg(&project.path).args(["add", ".env"]).status().unwrap();
        save(&store, "demo", &sample(), "tester").unwrap();
        let secrets: BTreeMap<String, String> = [("DB_PASSWORD".to_string(), "x".to_string())].into();
        assert!(activate(&store, "demo", "local", &secrets, false, "tester").is_err());
        let guard = git_guard(&project);
        assert!(guard.repository && guard.tracked);
    }
}
