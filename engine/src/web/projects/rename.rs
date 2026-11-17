//! Renaming a project (its id) and pointing it at another folder, without leaving anything behind
//! (P-41). Everything Stack keeps under a project's id or folder changes in one step that is
//! applied whole or rolled back ([`Journal`]); a project that is on is stopped first and started
//! again at the end. See `docs/architecture.md`, «Renombrar y mover un proyecto», for the full
//! list of places.
//!
//! The engine never reads the Keychain: the secrets of the project's environments (one item per
//! environment, account `<id>/<env>`) are moved by the app. A rename leaves a pending entry in
//! `renames.json` with the steps only the app can do (`keychain`, `vault`, `app`); the app
//! completes them when it starts or right after asking for the rename itself.
use crate::{
    core::{
        journal::Journal,
        model::{Project, rename_references, validate_id},
        store::Store,
        time::now_secs,
    },
    daemon, web,
};
use anyhow::{Result, ensure};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{
    fs,
    path::{Path, PathBuf},
};

/// What a rename asks for besides the new id.
#[derive(Debug, Default)]
pub struct RenameOptions {
    /// A new title; `None` keeps it.
    pub name: Option<String>,
    /// The first local domain becomes `<newId>.<its tld>`; otherwise every domain stays.
    pub domain: bool,
    /// The app already moved the Keychain items of the environments.
    pub keychain_moved: bool,
    pub actor: String,
}

/// A rename whose steps outside the engine are not done yet.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct Pending {
    pub from: String,
    pub to: String,
    pub at: u64,
    /// `keychain` (secrets of Entornos), `vault` (apps of the vault linked to it), `app` (the
    /// app's own preferences: favorites, last branch seen).
    pub steps: Vec<String>,
}

const STEPS: [&str; 3] = ["keychain", "vault", "app"];
const MAX_PENDING: usize = 100;

fn pending_file(store: &Store) -> PathBuf {
    store.root().join("renames.json")
}

pub fn pending(store: &Store) -> Result<Vec<Pending>> {
    store.document("renames")
}

/// Marks one step of a pending rename as done; the entry goes once it has none left.
pub fn step_done(store: &Store, from: &str, to: &str, step: &str) -> Result<Vec<Pending>> {
    ensure!(STEPS.contains(&step), "invalid_rename_step");
    let _lock = store.mutation_lock()?;
    let mut list = pending(store)?;
    for entry in list.iter_mut().filter(|e| e.from == from && e.to == to) {
        entry.steps.retain(|s| s != step);
    }
    list.retain(|e| !e.steps.is_empty());
    store.save_document("renames", &list)?;
    Ok(list)
}

/// The domain a rename with `domain: true` gives the project: `<to>.<tld of its first domain>`.
pub fn renamed_domain(project: &Project, to: &str, tlds: &[String]) -> String {
    let tld = project
        .domains
        .first()
        .and_then(|d| d.rsplit('.').next())
        .map(str::to_string)
        .or_else(|| tlds.first().cloned())
        .unwrap_or_default();
    format!("{to}.{tld}")
}

/// The record checked as `save` would, also when its folder is not there (a missing project can
/// be renamed too: its folder is found later).
fn check(store: &Store, project: &mut Project, others: &[Project]) -> Result<()> {
    let config = store.config()?;
    if project.path.is_dir() {
        project.validate(&config)?;
    } else {
        validate_id(&project.id)?;
        ensure!(
            crate::core::validate::printable(project.name.trim(), 200)
                && !project.name.trim().is_empty(),
            "invalid_name"
        );
        for domain in &project.domains {
            config.validate_domain(domain)?;
        }
    }
    for other in others.iter().filter(|o| o.id != project.id) {
        ensure!(
            !other.domains.iter().any(|d| project.domains.contains(d)),
            "domain_in_use"
        );
    }
    Ok(())
}

/// Turns a project off (or on) as `setSiteEnabled` does and asks the daemon to apply it right
/// away: its processes stop (or start) before this returns.
fn set_enabled(store: &Store, id: &str, enabled: bool) -> Result<()> {
    let mut project = store.get(id)?;
    if project.enabled != enabled {
        project.enabled = enabled;
        store.save(project)?;
    }
    let _ = daemon::request_sync(store, "reload", json!({}), false);
    Ok(())
}

/// Process logs and step logs named after the project: `<id>.<process>.log` (and its rotations),
/// `python-<id>.log`, `task-<id>.log` and `env-<id>.log`.
const LOG_PREFIXES: [&str; 3] = ["python-", "task-", "env-"];

/// `name` without its `.log` or `.log.<n>` (a rotation), and that ending.
fn log_base(name: &str) -> Option<(&str, &str)> {
    if let Some(base) = name.strip_suffix(".log") {
        return Some((base, &name[base.len()..]));
    }
    let (head, number) = name.rsplit_once('.')?;
    if number.is_empty() || !number.bytes().all(|c| c.is_ascii_digit()) {
        return None;
    }
    let base = head.strip_suffix(".log")?;
    Some((base, &name[base.len()..]))
}

/// The name a log of `from` takes for `to`; `None` when it is not one of `from`'s.
fn renamed_log(name: &str, from: &str, to: &str) -> Option<String> {
    let (base, ending) = log_base(name)?;
    if let Some(process) = base.strip_prefix(from).and_then(|p| p.strip_prefix('.')) {
        return validate_id(process)
            .is_ok()
            .then(|| format!("{to}.{process}{ending}"));
    }
    LOG_PREFIXES
        .iter()
        .find(|prefix| base.strip_prefix(**prefix) == Some(from))
        .map(|prefix| format!("{prefix}{to}{ending}"))
}

/// The logs of `from` (regular files only) with the name each takes for `to`.
fn log_names(store: &Store, from: &str, to: &str) -> Result<Vec<(String, String)>> {
    let mut out = vec![];
    for entry in fs::read_dir(store.directory("logs")?)? {
        let entry = entry?;
        let name = entry.file_name().to_string_lossy().into_owned();
        if let Some(new) = renamed_log(&name, from, to)
            .filter(|_| fs::symlink_metadata(entry.path()).is_ok_and(|m| m.file_type().is_file()))
        {
            out.push((name, new));
        }
    }
    out.sort();
    Ok(out)
}

/// Every change of a rename, inside `journal`. Returns the places that changed.
fn apply_rename(
    journal: &mut Journal,
    store: &Store,
    renamed: &Project,
    from: &str,
    options: &RenameOptions,
) -> Result<Vec<String>> {
    let to = renamed.id.as_str();
    let mut places = vec![];
    // Its record, under the new name; the old one goes.
    journal.write_json(&store.project_path(to)?, renamed)?;
    journal.remove(&store.project_path(from)?)?;
    places.push("projects".to_string());
    // `{port:<from>}` and `{public:<from>}` in the `env` and arguments of every project.
    for mut other in store.records()? {
        let before = other.clone();
        for value in other.env.values_mut() {
            *value = rename_references(value, from, to);
        }
        for process in &mut other.processes {
            for arg in &mut process.args {
                *arg = rename_references(arg, from, to);
            }
        }
        if other != before {
            journal.write_json(&store.project_path(&other.id)?, &other)?;
            places.push(format!("markers:{}", other.id));
        }
    }
    // Its place in its folder or project of several parts (the order of the parts stays).
    let mut groups = store.groups()?;
    let before = groups.clone();
    for group in &mut groups {
        group.sites.retain(|s| s != to);
        for site in &mut group.sites {
            if site == from {
                *site = to.to_string();
            }
        }
    }
    if groups != before {
        journal.write_json(&store.root().join("groups.json"), &groups)?;
        places.push("groups".to_string());
    }
    // Its environments, and the markers and `outdated` marks that name it in any of them.
    for id in web::projects::envs::rename_project(journal, store, from, to)? {
        places.push(format!("envs:{id}"));
    }
    // Its fixed address and its tunnel's credentials.
    if web::net::tunnels::rename_project(journal, store, from, to)? {
        places.push("tunnels".to_string());
    }
    // Logs named after it, and the audit lines of its environments.
    let logs = store.directory("logs")?;
    for (name, new) in log_names(store, from, to)? {
        journal.rename(&logs.join(&name), &logs.join(&new))?;
        places.push(format!("logs:{new}"));
    }
    web::projects::envs::rename_audit(journal, store, from, to)?;
    // What only the app can finish.
    let mut steps = vec![];
    if !options.keychain_moved && web::projects::envs::exists(store, to) {
        steps.push("keychain".to_string());
    }
    if store.root().join("vault").exists() {
        steps.push("vault".to_string());
    }
    steps.push("app".to_string());
    let mut list = pending(store)?;
    list.push(Pending {
        from: from.to_string(),
        to: to.to_string(),
        at: now_secs(),
        steps,
    });
    let excess = list.len().saturating_sub(MAX_PENDING);
    list.drain(..excess);
    journal.write_json(&pending_file(store), &list)?;
    Ok(places)
}

/// `renameProject`: project `from` becomes `to` (see the module's documentation). A project that
/// is on is stopped first and started again at the end; sharing it (temporary or fixed address)
/// stops and is turned on again by the user. Anything that fails leaves everything as it was.
pub fn rename_project(
    store: &Store,
    from: &str,
    to: &str,
    options: &RenameOptions,
) -> Result<Value> {
    validate_id(from)?;
    validate_id(to).map_err(|_| anyhow::anyhow!("invalid_new_id"))?;
    ensure!(from != to, "same_id");
    let current = store.record(from)?;
    ensure!(
        store.record(to).is_err() && !store.project_path(to)?.exists(),
        "id_in_use"
    );
    ensure!(
        !web::projects::envs::exists(store, to) && !web::net::tunnels::holds(store, to),
        "id_in_use"
    );
    let config = store.config()?;
    let mut renamed = current.clone();
    renamed.id = to.to_string();
    if let Some(name) = &options.name {
        renamed.name = name.trim().to_string();
    }
    if options.domain {
        let domain = renamed_domain(&current, to, &config.tld);
        match renamed.domains.first_mut() {
            Some(first) => *first = domain,
            None => renamed.domains.push(domain),
        }
        let mut seen = std::collections::HashSet::new();
        renamed.domains.retain(|d| seen.insert(d.clone()));
    }
    for value in renamed.env.values_mut() {
        *value = rename_references(value, from, to);
    }
    for process in &mut renamed.processes {
        for arg in &mut process.args {
            *arg = rename_references(arg, from, to);
        }
    }
    let mut others = store.records()?;
    others.retain(|p| p.id != from);
    check(store, &mut renamed, &others)?;
    // Stopped first: nothing of it may run (or write its logs) while its files move.
    let running = current.enabled && current.path.is_dir();
    if running {
        set_enabled(store, from, false)?;
        renamed.enabled = false;
    }
    let result = {
        let _lock = store.mutation_lock()?;
        let mut journal = Journal::new();
        match apply_rename(&mut journal, store, &renamed, from, options) {
            Ok(places) => Ok(places),
            Err(error) => {
                journal.rollback();
                Err(error)
            }
        }
    };
    let places = match result {
        Ok(places) => places,
        Err(error) => {
            if running {
                let _ = set_enabled(store, from, true);
            }
            return Err(error);
        }
    };
    let _ = web::projects::envs::audit(store, to, "", "renombrar", "", &options.actor);
    if running {
        set_enabled(store, to, true)?;
    } else {
        let _ = daemon::request_sync(store, "reload", json!({}), false);
    }
    let project = store.record(to)?;
    let pending = pending(store)?
        .into_iter()
        .rfind(|p| p.from == from && p.to == to);
    Ok(json!({
        "project": project,
        "from": from,
        "to": to,
        "restarted": running,
        "places": places,
        "pending": pending.map(|p| p.steps).unwrap_or_default(),
    }))
}

/// `moveProject`: project `id` points at `path`, an existing folder no other project uses. No
/// file is moved or copied. A project that is on is stopped and started again in the new folder.
/// `envReapply` says the active environment's `.env` is not in the new folder yet (Stack writes it
/// when the environment is applied again).
pub fn move_project(store: &Store, id: &str, path: &Path) -> Result<Value> {
    ensure!(path.is_absolute(), "invalid_path");
    let current = store.record(id)?;
    let target = path
        .canonicalize()
        .map_err(|_| anyhow::anyhow!("invalid_path"))?;
    ensure!(target.is_dir(), "invalid_path");
    let previous = current
        .path
        .canonicalize()
        .unwrap_or_else(|_| current.path.clone());
    ensure!(target != previous, "same_folder");
    let records = store.records()?;
    ensure!(
        !records.iter().any(|p| p.id != id
            && (p.path == target || p.path.canonicalize().is_ok_and(|c| c == target))),
        "folder_in_use"
    );
    let mut moved = current.clone();
    moved.path = target.clone();
    check(store, &mut moved, &records)?;
    let running = current.enabled && current.path.is_dir();
    if running {
        set_enabled(store, id, false)?;
        moved.enabled = false;
    }
    let result = {
        let _lock = store.mutation_lock()?;
        let mut journal = Journal::new();
        let applied = (|| -> Result<Vec<String>> {
            let mut places = vec!["projects".to_string()];
            journal.write_json(&store.project_path(id)?, &moved)?;
            if crate::git::repositories::moved(&mut journal, store, &previous, &target)? {
                places.push("git".to_string());
            }
            // A repository of a project of several parts that was this folder.
            let mut groups = store.groups()?;
            let before = groups.clone();
            for group in &mut groups {
                for repository in &mut group.repositories {
                    if Path::new(repository) == previous {
                        *repository = target.to_string_lossy().into_owned();
                    }
                }
            }
            if groups != before {
                journal.write_json(&store.root().join("groups.json"), &groups)?;
                places.push("groups".to_string());
            }
            Ok(places)
        })();
        match applied {
            Ok(places) => Ok(places),
            Err(error) => {
                journal.rollback();
                Err(error)
            }
        }
    };
    let places = match result {
        Ok(places) => places,
        Err(error) => {
            if running {
                let _ = set_enabled(store, id, true);
            }
            return Err(error);
        }
    };
    if running {
        set_enabled(store, id, true)?;
    } else {
        let _ = daemon::request_sync(store, "reload", json!({}), false);
    }
    let environments = web::projects::envs::load(store, id).unwrap_or_default();
    let reapply = environments.active.is_some()
        && !web::projects::envs::written_by_stack(&target.join(".env"));
    Ok(json!({
        "project": store.record(id)?,
        "previous": previous,
        "restarted": running,
        "places": places,
        "envReapply": reapply,
    }))
}

#[cfg(test)]
#[path = "rename_tests.rs"]
mod tests;
