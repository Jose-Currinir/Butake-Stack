//! The tool's own data: repositories the user added beyond Stack's projects, and the ones opened
//! lately. Only paths and dates, in `config/git/repositories.json` (0600); removing the tool with
//! «Eliminar datos» deletes the folder. Repositories themselves are never touched here.
use crate::core::{json, store::Store, time::now_secs};
use anyhow::Result;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{
    os::unix::fs::PermissionsExt,
    path::{Path, PathBuf},
};

/// Most recent repositories kept.
const RECENT_LIMIT: usize = 20;

#[derive(Debug, Default, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Saved {
    #[serde(default)]
    pub added: Vec<Entry>,
    #[serde(default)]
    pub recent: Vec<Entry>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Entry {
    pub path: PathBuf,
    /// When it was added or last opened (epoch UTC).
    pub at: u64,
}

fn folder(store: &Store) -> Result<PathBuf> {
    Ok(store.directory("config")?.join("git"))
}

fn file(store: &Store) -> Result<PathBuf> {
    let dir = folder(store)?;
    std::fs::create_dir_all(&dir)?;
    std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700))?;
    Ok(dir.join("repositories.json"))
}

pub fn load(store: &Store) -> Result<Saved> {
    let path = folder(store)?.join("repositories.json");
    if !path.exists() {
        return Ok(Saved::default());
    }
    json::read_regular(&path, Some(1_048_576))
}

fn save(store: &Store, saved: &Saved) -> Result<()> {
    json::write(&file(store)?, saved)
}

/// Whether the tool keeps anything of its own (offered for deletion when it is removed).
pub fn has_data(store: &Store) -> bool {
    load(store).is_ok_and(|s| !s.added.is_empty() || !s.recent.is_empty())
}

/// Deletes the tool's data folder; Stack's projects and the repositories stay as they are.
pub fn delete_all(store: &Store) -> Result<()> {
    let dir = folder(store)?;
    if dir.exists() {
        std::fs::remove_dir_all(dir)?;
    }
    Ok(())
}

/// Adds a repository (its top folder, already resolved) unless it is a Stack project or listed.
pub fn add(store: &Store, root: &Path) -> Result<()> {
    let mut saved = load(store)?;
    let project = store.list()?.iter().any(|p| p.path == root);
    if !project && !saved.added.iter().any(|e| e.path == root) {
        saved.added.push(Entry {
            path: root.to_path_buf(),
            at: now_secs(),
        });
        save(store, &saved)?;
    }
    Ok(())
}

/// Forgets a repository from both lists; the folder is not touched.
pub fn forget(store: &Store, path: &Path) -> Result<()> {
    let mut saved = load(store)?;
    saved.added.retain(|e| e.path != path);
    saved.recent.retain(|e| e.path != path);
    save(store, &saved)
}

/// A project now points at another folder (P-41): the recent entry of its old folder names the
/// new one. A project is never in `added` (see [`add`]); one listed there is the new folder's, so
/// it is dropped. Whether anything changed.
pub fn moved(
    journal: &mut crate::core::journal::Journal,
    store: &Store,
    from: &Path,
    to: &Path,
) -> Result<bool> {
    let path = folder(store)?.join("repositories.json");
    if !path.exists() {
        return Ok(false);
    }
    let mut saved = load(store)?;
    let before = saved.recent.clone();
    let added = saved.added.len();
    saved.added.retain(|e| e.path != to);
    saved.recent.retain(|e| e.path != to);
    for entry in &mut saved.recent {
        if entry.path == from {
            entry.path = to.to_path_buf();
        }
    }
    let changed = saved.recent != before || saved.added.len() != added;
    if changed {
        journal.write_json(&path, &saved)?;
    }
    Ok(changed)
}

/// Moves a repository to the front of the recent list.
pub fn opened(store: &Store, root: &Path) -> Result<()> {
    let mut saved = load(store)?;
    saved.recent.retain(|e| e.path != root);
    saved.recent.insert(
        0,
        Entry {
            path: root.to_path_buf(),
            at: now_secs(),
        },
    );
    saved.recent.truncate(RECENT_LIMIT);
    save(store, &saved)
}

/// The tool's repositories: Stack projects whose folder is a repository, those the user added and
/// the recent ones; a folder that is gone is marked `missing` instead of dropped.
pub fn overview(store: &Store) -> Result<Value> {
    let saved = load(store)?;
    let projects: Vec<Value> = store
        .list()?
        .into_iter()
        .filter(|p| crate::web::projects::git::is_repository(&p.path))
        .map(|p| json!({"id": p.id, "name": p.name, "path": p.path}))
        .collect();
    let describe = |entries: &[Entry]| -> Vec<Value> {
        entries
            .iter()
            .map(|e| {
                let name = e
                    .path
                    .file_name()
                    .map(|n| n.to_string_lossy().into_owned())
                    .unwrap_or_default();
                json!({"path": e.path, "name": name, "at": e.at,
                       "missing": !crate::web::projects::git::is_repository(&e.path)})
            })
            .collect()
    };
    Ok(json!({
        "projects": projects,
        "added": describe(&saved.added),
        "recent": describe(&saved.recent),
    }))
}
