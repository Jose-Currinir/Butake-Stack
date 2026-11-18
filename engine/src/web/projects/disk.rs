//! The sidebar follows the folders of the disk. The projects folder (`~/Stack/Projects`, or the
//! one the user chose) is the tree: every subfolder is a folder of the sidebar, at any depth; a
//! repository is a project. A «project of several parts» is a folder of the disk marked as such,
//! saved by its relative path in `groups.json` (`SiteGroup.path`).
//!
//! - The daemon looks at the folder several times a second ([`watch_loop`]): a change makes it
//!   follow the projects that moved (`reconcile`) and tell the app (`disk.changed`).
//! - A project that moved is recognized by the file identifier of its folder (it survives a move
//!   in the same volume), or by its first Git commit and remote, and its path is updated; its
//!   domain, environments and processes are not touched.
//! - Nothing is added or removed by itself: a repository that is not a project is offered
//!   («Nuevo»), a project without folder is marked («No encontrado»).
//! - Moving, renaming, creating and removing (empty) folders act on the disk.
//! - The first time, the groups of `groups.json` are compared with the disk (`plan`): what
//!   matches is converted, the rest is proposed. `groups.json` keeps being a plain file the
//!   previous version reads (a copy of the original stays in `groups.pre-disk.json`).
use crate::{
    core::{
        model::Project,
        store::{SiteGroup, Store},
        time::now_secs,
    },
    daemon, web,
};
use anyhow::{Result, ensure};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{
    collections::{BTreeMap, BTreeSet},
    fs,
    os::unix::fs::MetadataExt,
    path::{Path, PathBuf},
    process::{Command, Stdio},
};

const MAX_DEPTH: usize = 6;
const MAX_NODES: usize = 5000;
const MAX_MOVES: usize = 20;
/// Folders that never hold projects of the user, whatever they are named.
const SKIP: [&str; 8] = [
    "node_modules",
    "vendor",
    "build",
    "dist",
    "target",
    "Library",
    "Pods",
    "DerivedData",
];

/// What identifies a project's folder apart from its path.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
#[serde(default)]
pub struct Identity {
    /// `<device>:<inode>`: the same after the folder is moved within its volume.
    pub file: Option<String>,
    pub first_commit: Option<String>,
    pub remote: Option<String>,
}

/// A project followed to its new folder.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Moved {
    pub id: String,
    pub name: String,
    pub from: PathBuf,
    pub to: PathBuf,
    pub at: u64,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
#[serde(default)]
pub struct Disk {
    /// The sidebar follows the disk (after the first comparison with `groups.json`).
    pub enabled: bool,
    /// The projects folder the user chose; none is `~/Stack/Projects`.
    pub root: Option<PathBuf>,
    pub identities: BTreeMap<String, Identity>,
    pub moves: Vec<Moved>,
}

pub fn load(store: &Store) -> Result<Disk> {
    store.document("disk")
}

/// Changes the document under the store's lock (the daemon and the app both write it).
fn update<T>(store: &Store, change: impl FnOnce(&mut Disk) -> T) -> Result<T> {
    let _lock = store.mutation_lock()?;
    let mut disk = load(store)?;
    let before = disk.clone();
    let out = change(&mut disk);
    if disk != before {
        store.save_document("disk", &disk)?;
    }
    Ok(out)
}

/// The projects folder, canonical; `None` while it does not exist.
pub fn root(store: &Store) -> Result<Option<PathBuf>> {
    let disk = load(store)?;
    let path = disk
        .root
        .or_else(|| dirs::home_dir().map(|home| home.join("Stack/Projects")));
    Ok(path
        .and_then(|p| p.canonicalize().ok())
        .filter(|p| p.is_dir()))
}

/// Keeps the folder the app says is the projects folder.
fn set_root(store: &Store, path: &Path) -> Result<()> {
    ensure!(path.is_absolute(), "invalid_path");
    let path = path.canonicalize().unwrap_or_else(|_| path.to_path_buf());
    update(store, |disk| {
        if disk.root.as_deref() != Some(&path) {
            disk.root = Some(path);
        }
    })
}

// ---- The tree -------------------------------------------------------------------------------

#[derive(Debug, Clone, PartialEq)]
pub struct Folder {
    pub rel: String,
    pub name: String,
    pub parent: Option<String>,
    pub inode: u64,
}

#[derive(Debug, Default)]
pub struct Walked {
    pub folders: Vec<Folder>,
    /// Repositories (or folders of a project) with their inode, parent folder (relative) included.
    pub repos: Vec<(PathBuf, u64, Option<String>)>,
}

fn skipped(name: &str) -> bool {
    name.starts_with('.') || SKIP.contains(&name)
}

/// The folders and repositories under `root`. Real folders only (a link could point anywhere),
/// hidden and dependency folders skipped; a repository (or a folder that is already a project)
/// is a leaf.
pub fn walk(root: &Path, known: &BTreeSet<PathBuf>) -> Walked {
    fn visit(
        dir: &Path,
        rel: Option<&str>,
        depth: usize,
        known: &BTreeSet<PathBuf>,
        out: &mut Walked,
    ) {
        let mut children: Vec<(String, PathBuf, u64)> = fs::read_dir(dir)
            .map(|entries| {
                entries
                    .flatten()
                    .filter_map(|e| {
                        let name = e.file_name().to_string_lossy().into_owned();
                        let meta = fs::symlink_metadata(e.path()).ok()?;
                        (meta.is_dir() && !skipped(&name)).then(|| (name, e.path(), meta.ino()))
                    })
                    .collect()
            })
            .unwrap_or_default();
        children.sort_by_key(|(name, _, _)| (name.to_lowercase(), name.clone()));
        for (name, path, inode) in children {
            if out.folders.len() + out.repos.len() >= MAX_NODES {
                return;
            }
            let child = match rel {
                Some(rel) => format!("{rel}/{name}"),
                None => name.clone(),
            };
            if path.join(".git").exists() || known.contains(&path) {
                out.repos.push((path, inode, rel.map(str::to_string)));
            } else {
                out.folders.push(Folder {
                    rel: child.clone(),
                    name,
                    parent: rel.map(str::to_string),
                    inode,
                });
                if depth < MAX_DEPTH {
                    visit(&path, Some(&child), depth + 1, known, out);
                }
            }
        }
    }
    let mut out = Walked::default();
    visit(root, None, 1, known, &mut out);
    out
}

/// Where each project's folder is, canonical when it exists (a missing one keeps its path).
fn known_paths(records: &[Project]) -> BTreeSet<PathBuf> {
    records
        .iter()
        .map(|p| p.path.canonicalize().unwrap_or_else(|_| p.path.clone()))
        .collect()
}

/// Changes only when a folder or a repository is created, removed, moved or renamed.
pub fn fingerprint(store: &Store) -> Result<String> {
    use sha2::{Digest, Sha256};
    let Some(root) = root(store)? else {
        return Ok(String::new());
    };
    let records = store.records()?;
    let walked = walk(&root, &known_paths(&records));
    let mut text = String::new();
    for folder in &walked.folders {
        text.push_str(&format!("d {} {}\n", folder.rel, folder.inode));
    }
    for (path, inode, _) in &walked.repos {
        text.push_str(&format!("r {} {inode}\n", path.display()));
    }
    for project in &records {
        text.push_str(&format!("p {} {}\n", project.id, project.path.is_dir()));
    }
    Ok(Sha256::digest(text.as_bytes())
        .iter()
        .take(8)
        .map(|b| format!("{b:02x}"))
        .collect())
}

/// The id of a plain folder: stable for its path.
pub fn folder_id(rel: &str) -> String {
    use sha2::{Digest, Sha256};
    let slug: String = rel
        .to_lowercase()
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() { c } else { '-' })
        .collect();
    let slug = slug
        .split('-')
        .filter(|s| !s.is_empty())
        .collect::<Vec<_>>()
        .join("-");
    let hash: String = Sha256::digest(rel.as_bytes())
        .iter()
        .take(3)
        .map(|b| format!("{b:02x}"))
        .collect();
    let head: String = slug.chars().take(24).collect();
    if head.is_empty() {
        hash
    } else {
        format!("{}-{hash}", head.trim_end_matches('-'))
    }
}

fn under(path: &Path, folder: &Path) -> bool {
    path != folder && path.starts_with(folder)
}

fn canonical(path: &Path) -> PathBuf {
    path.canonicalize().unwrap_or_else(|_| path.to_path_buf())
}

/// Whether site `site` is a project inside the folder `rel` (used by the folders of several
/// parts: its parts are whatever repositories are in it).
pub fn holds(store: &Store, rel: &str, site: &str) -> bool {
    let (Ok(Some(root)), Ok(project)) = (root(store), store.record(site)) else {
        return false;
    };
    under(&canonical(&project.path), &root.join(rel))
}

/// The folders of the sidebar, as the disk has them: parents before their children. A project
/// of several parts is the folder its stored group points at.
pub fn groups_view(store: &Store) -> Result<Vec<SiteGroup>> {
    let Some(root) = root(store)? else {
        return Ok(vec![]);
    };
    let records = store.list()?;
    let walked = walk(&root, &known_paths(&records));
    let stored: BTreeMap<String, SiteGroup> = store
        .groups()?
        .into_iter()
        .filter(|g| g.is_project())
        .filter_map(|g| g.path.clone().map(|path| (path, g)))
        .collect();
    let ids: BTreeMap<&str, String> = walked
        .folders
        .iter()
        .map(|f| {
            let id = stored
                .get(&f.rel)
                .map(|g| g.id.clone())
                .unwrap_or_else(|| folder_id(&f.rel));
            (f.rel.as_str(), id)
        })
        .collect();
    let by_path: BTreeMap<PathBuf, &Project> =
        records.iter().map(|p| (canonical(&p.path), p)).collect();
    let mut out = vec![];
    for folder in &walked.folders {
        let directory = root.join(&folder.rel);
        let saved = stored.get(&folder.rel);
        let mut members: Vec<String> = by_path
            .iter()
            .filter(|(path, _)| {
                if saved.is_some() {
                    under(path, &directory)
                } else {
                    path.parent() == Some(directory.as_path())
                }
            })
            .map(|(_, p)| p.id.clone())
            .collect();
        members.sort();
        if let Some(saved) = saved {
            // Its order is the saved one; parts that are new go at the end.
            let mut ordered: Vec<String> = saved
                .sites
                .iter()
                .filter(|s| members.contains(s))
                .cloned()
                .collect();
            let rest: Vec<String> = members
                .iter()
                .filter(|m| !ordered.contains(m))
                .cloned()
                .collect();
            ordered.extend(rest);
            members = ordered;
        }
        out.push(SiteGroup {
            id: ids[folder.rel.as_str()].clone(),
            name: folder.name.clone(),
            sites: members,
            kind: if saved.is_some() {
                SiteGroup::PROJECT.into()
            } else {
                String::new()
            },
            repositories: saved.map(|g| g.repositories.clone()).unwrap_or_default(),
            ordered: saved.is_some_and(|g| g.ordered),
            gcp: saved.and_then(|g| g.gcp.clone()),
            path: Some(folder.rel.clone()),
            parent: folder.parent.as_deref().and_then(|p| ids.get(p)).cloned(),
        });
    }
    Ok(out)
}

/// Saves what the app changed of the folders: only the projects of several parts are kept (the
/// rest is the disk). Groups of `groups.json` that never got a place on the disk stay as they
/// were, so going back to the previous version loses nothing.
pub fn save_groups(store: &Store, incoming: Vec<SiteGroup>) -> Result<Vec<SiteGroup>> {
    let mine: Vec<SiteGroup> = incoming
        .into_iter()
        .filter(|g| g.is_project() && g.path.is_some())
        .collect();
    let mut all = mine.clone();
    // Everything else stays as it was: groups that never got a place, and folders that stopped
    // being a project of several parts (their link and order wait for when they are one again).
    all.extend(
        store
            .groups()?
            .into_iter()
            .filter(|g| !mine.iter().any(|m| m.id == g.id)),
    );
    store.save_groups(all)?;
    groups_view(store)
}

/// Marks a folder as a project of several parts (or back to a plain folder).
pub fn set_multipart(store: &Store, rel: &str, on: bool) -> Result<Vec<SiteGroup>> {
    ensure!(SiteGroup::valid_relative(rel), "invalid_path");
    let root = root(store)?.ok_or_else(|| anyhow::anyhow!("invalid_path"))?;
    ensure!(root.join(rel).is_dir(), "invalid_path");
    let mut groups = store.groups()?;
    let existing = groups.iter().position(|g| g.path.as_deref() == Some(rel));
    match (on, existing) {
        (true, Some(index)) => groups[index].kind = SiteGroup::PROJECT.into(),
        (true, None) => {
            let name = rel.rsplit('/').next().unwrap_or(rel);
            let mut id = folder_id(rel);
            if groups.iter().any(|g| g.id == id) {
                id = format!("{}-{}", &id[..id.len().min(30)], groups.len());
            }
            groups.push(SiteGroup {
                id,
                name: name.into(),
                kind: SiteGroup::PROJECT.into(),
                path: Some(rel.into()),
                ..Default::default()
            });
        }
        // Its Google Cloud link and order stay in the file, unused, for when it is one again.
        (false, Some(index)) => groups[index].kind = String::new(),
        _ => {}
    }
    store.save_groups(groups)?;
    groups_view(store)
}

// ---- Identity and following what moved ---------------------------------------------------------

fn file_identity(path: &Path) -> Option<String> {
    let meta = fs::symlink_metadata(path).ok()?;
    meta.is_dir()
        .then(|| format!("{}:{}", meta.dev(), meta.ino()))
}

fn git(path: &Path, args: &[&str]) -> Option<String> {
    let output = Command::new("git")
        .arg("-C")
        .arg(path)
        .args(args)
        .env("GIT_TERMINAL_PROMPT", "0")
        .env("GIT_OPTIONAL_LOCKS", "0")
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output()
        .ok()?;
    let text = String::from_utf8(output.stdout).ok()?;
    let line = text
        .lines()
        .map(str::trim)
        .filter(|l| !l.is_empty())
        .min()?;
    output.status.success().then(|| line.to_string())
}

/// The first commit and remote of a repository: what survives a copy of the folder.
fn git_identity(path: &Path) -> (Option<String>, Option<String>) {
    if !path.join(".git").exists() {
        return (None, None);
    }
    (
        git(path, &["rev-list", "--max-parents=0", "HEAD"]),
        git(path, &["config", "--get", "remote.origin.url"]),
    )
}

/// Remembers who each project's folder is while it is there.
fn learn_identities(store: &Store, records: &[Project]) -> Result<()> {
    let mut learned: BTreeMap<String, Identity> = BTreeMap::new();
    let disk = load(store)?;
    for project in records.iter().filter(|p| p.path.is_dir()) {
        let file = file_identity(&project.path);
        let known = disk.identities.get(&project.id);
        if known.is_some_and(|k| {
            k.file == file && (k.first_commit.is_some() || !project.path.join(".git").exists())
        }) {
            continue;
        }
        let (first_commit, remote) = git_identity(&project.path);
        learned.insert(
            project.id.clone(),
            Identity {
                file,
                first_commit,
                remote,
            },
        );
    }
    if learned.is_empty() {
        return Ok(());
    }
    update(store, |disk| disk.identities.extend(learned))
}

/// Whether `candidate` is the folder a project had, given what was known of it. When nothing
/// was known (a project of before this feature), the name of its folder decides.
fn same_folder(known: Option<&Identity>, old: &Path, candidate: &Path, other: &Identity) -> bool {
    match known {
        Some(known) => {
            if known.file.is_some() && known.file == other.file {
                return true;
            }
            known.first_commit.is_some()
                && known.first_commit == other.first_commit
                && (known.remote.is_none()
                    || other.remote.is_none()
                    || known.remote == other.remote)
        }
        None => {
            let name = |p: &Path| p.file_name().map(|n| n.to_string_lossy().to_lowercase());
            name(old).is_some() && name(old) == name(candidate)
        }
    }
}

/// Points the projects whose folder is gone at the folder they moved to, when exactly one
/// repository that is not a project is the same one. Returns the ones followed.
pub fn reconcile(store: &Store) -> Result<Vec<Moved>> {
    let Some(root) = root(store)? else {
        return Ok(vec![]);
    };
    let records = store.records()?;
    learn_identities(store, &records)?;
    let missing: Vec<&Project> = records.iter().filter(|p| !p.path.is_dir()).collect();
    let mut followed = vec![];
    if !missing.is_empty() {
        let disk = load(store)?;
        let known = known_paths(&records);
        let candidates: Vec<(PathBuf, Identity)> = walk(&root, &known)
            .repos
            .into_iter()
            .filter(|(path, _, _)| !known.contains(path))
            .map(|(path, _, _)| {
                let (first_commit, remote) = git_identity(&path);
                let identity = Identity {
                    file: file_identity(&path),
                    first_commit,
                    remote,
                };
                (path, identity)
            })
            .collect();
        let mut taken: BTreeSet<PathBuf> = BTreeSet::new();
        for project in missing {
            let known = disk.identities.get(&project.id);
            let found: Vec<&(PathBuf, Identity)> = candidates
                .iter()
                .filter(|(path, identity)| {
                    !taken.contains(path) && same_folder(known, &project.path, path, identity)
                })
                .collect();
            // Two folders that could be it: the user decides («Ubicar…»).
            let [(path, _)] = found.as_slice() else {
                continue;
            };
            if web::projects::rename::move_project(store, &project.id, path).is_err() {
                continue;
            }
            taken.insert(path.clone());
            followed.push(Moved {
                id: project.id.clone(),
                name: project.name.clone(),
                from: project.path.clone(),
                to: path.clone(),
                at: now_secs(),
            });
        }
    }
    follow_folders(store, &root)?;
    if !followed.is_empty() {
        let log = followed.clone();
        update(store, |disk| {
            disk.moves.extend(log);
            let excess = disk.moves.len().saturating_sub(MAX_MOVES);
            disk.moves.drain(..excess);
        })?;
        let _ = daemon::request_sync(store, "reload", json!({}), false);
    }
    Ok(followed)
}

/// A folder of several parts that moved with its parts: its place is where they are now.
fn follow_folders(store: &Store, root: &Path) -> Result<()> {
    let groups = store.groups()?;
    let records = store.list()?;
    let mut changed = false;
    let mut next = groups.clone();
    for group in next.iter_mut().filter(|g| g.is_project()) {
        let Some(path) = group.path.clone() else {
            continue;
        };
        if root.join(&path).is_dir() {
            continue;
        }
        let parents: BTreeSet<PathBuf> = group
            .sites
            .iter()
            .filter_map(|s| records.iter().find(|p| &p.id == s))
            .filter_map(|p| canonical(&p.path).parent().map(Path::to_path_buf))
            .collect();
        if let [parent] = parents.iter().collect::<Vec<_>>().as_slice()
            && let Ok(rel) = parent.strip_prefix(root)
            && let Some(rel) = rel.to_str()
            && SiteGroup::valid_relative(rel)
        {
            group.path = Some(rel.to_string());
            changed = true;
        }
    }
    if changed {
        store.save_groups(next)?;
    }
    Ok(())
}

// ---- What the app shows besides the folders ------------------------------------------------------

fn same_prefix(names: &[String], folder: &str) -> Vec<String> {
    let lower: Vec<String> = names.iter().map(|n| n.to_lowercase()).collect();
    let mut bases: Vec<String> = lower.clone();
    bases.push(folder.to_lowercase());
    let mut best: Vec<String> = vec![];
    for base in bases {
        let parts: Vec<String> = names
            .iter()
            .zip(&lower)
            .filter(|(_, l)| **l == base || l.starts_with(&format!("{base}-")))
            .map(|(n, _)| n.clone())
            .collect();
        if parts.len() > best.len() {
            best = parts;
        }
    }
    best
}

/// The state of the disk for the app: repositories that are not projects, folders that look like
/// a project of several parts, what was followed, and the migration if it is pending.
pub fn state(store: &Store, root_hint: Option<&Path>) -> Result<Value> {
    if let Some(path) = root_hint {
        set_root(store, path)?;
    }
    if !load(store)?.enabled && store.groups()?.is_empty() {
        update(store, |disk| disk.enabled = true)?;
    }
    let disk = load(store)?;
    let Some(root) = root(store)? else {
        return Ok(
            json!({"enabled": disk.enabled, "root": null, "newRepos": [],
            "suggestions": [], "moves": disk.moves, "migration": null}),
        );
    };
    if !disk.enabled {
        let plan = plan(store)?;
        if plan["proposals"].as_array().is_some_and(Vec::is_empty) {
            migrate(store, false)?;
        } else {
            return Ok(
                json!({"enabled": false, "root": root, "newRepos": [], "suggestions": [],
                "moves": [], "migration": plan}),
            );
        }
    }
    reconcile(store)?;
    let disk = load(store)?;
    let records = store.records()?;
    let known = known_paths(&records);
    let walked = walk(&root, &known);
    let groups = groups_view(store)?;
    let id_of = |rel: &Option<String>| {
        rel.as_ref()
            .and_then(|r| groups.iter().find(|g| g.path.as_deref() == Some(r)))
            .map(|g| g.id.clone())
    };
    let new_repos: Vec<Value> = walked
        .repos
        .iter()
        .filter(|(path, _, _)| !known.contains(path))
        .map(|(path, _, parent)| {
            json!({
                "path": path,
                "name": path.file_name().map(|n| n.to_string_lossy().into_owned()),
                "folder": id_of(parent),
            })
        })
        .collect();
    let mut suggestions = vec![];
    for folder in &walked.folders {
        if groups
            .iter()
            .any(|g| g.path.as_deref() == Some(&folder.rel) && g.is_project())
        {
            continue;
        }
        let names: Vec<String> = walked
            .repos
            .iter()
            .filter(|(_, _, parent)| parent.as_deref() == Some(&folder.rel))
            .filter_map(|(p, _, _)| p.file_name().map(|n| n.to_string_lossy().into_owned()))
            .collect();
        let parts = same_prefix(&names, &folder.name);
        if parts.len() >= 2 {
            suggestions.push(json!({
                "path": folder.rel, "folder": id_of(&Some(folder.rel.clone())),
                "name": folder.name, "parts": parts,
            }));
        }
    }
    Ok(json!({
        "enabled": true, "root": root, "newRepos": new_repos, "suggestions": suggestions,
        "moves": disk.moves, "migration": null,
    }))
}

// ---- Acting on the disk ------------------------------------------------------------------------

fn valid_name(name: &str) -> bool {
    !name.is_empty()
        && name.chars().count() <= 100
        && !name.starts_with('.')
        && !name.contains(['/', '\\', ':'])
        && !name.chars().any(char::is_control)
        && name.trim() == name
}

fn inside(root: &Path, path: &Path) -> Result<PathBuf> {
    let path = path
        .canonicalize()
        .map_err(|_| anyhow::anyhow!("invalid_path"))?;
    ensure!(path == root || path.starts_with(root), "invalid_path");
    Ok(path)
}

/// Moves the folder `from` to `destination` (a path that does not exist yet), with the projects
/// in it: each is turned off, pointed at its new folder (Git, groups…) and turned on again.
fn relocate_dir(store: &Store, root: &Path, from: &Path, destination: &Path) -> Result<Value> {
    ensure!(from != root && from.starts_with(root), "invalid_path");
    ensure!(!destination.starts_with(from), "move_into_itself");
    ensure!(fs::symlink_metadata(destination).is_err(), "folder_exists");
    let records = store.records()?;
    let affected: Vec<&Project> = records
        .iter()
        .filter(|p| {
            let path = canonical(&p.path);
            path == from || path.starts_with(from)
        })
        .collect();
    let mut was_on = vec![];
    for project in &affected {
        if project.enabled && project.path.is_dir() {
            web::projects::rename::set_enabled(store, &project.id, false)?;
            was_on.push(project.id.clone());
        }
    }
    let back_on = |ids: &[String]| {
        for id in ids {
            let _ = web::projects::rename::set_enabled(store, id, true);
        }
    };
    if fs::rename(from, destination).is_err() {
        back_on(&was_on);
        anyhow::bail!("folder_move_failed");
    }
    let mut moved = vec![];
    for project in &affected {
        let old = canonical(&project.path);
        let new = match old.strip_prefix(from) {
            Ok(rest) => destination.join(rest),
            Err(_) => continue,
        };
        if web::projects::rename::move_project(store, &project.id, &new).is_ok() {
            moved.push(project.id.clone());
        }
    }
    // Folders of several parts inside what moved keep their parts.
    let (from_rel, to_rel) = (from.strip_prefix(root)?, destination.strip_prefix(root));
    if let (Some(old), Ok(new)) = (from_rel.to_str(), to_rel.map(|p| p.to_str())) {
        let mut groups = store.groups()?;
        let mut changed = false;
        for group in &mut groups {
            if let (Some(path), Some(new)) = (group.path.clone(), new) {
                if path == old || path.starts_with(&format!("{old}/")) {
                    group.path = Some(format!("{new}{}", &path[old.len()..]));
                    changed = true;
                }
            }
        }
        if changed {
            store.save_groups(groups)?;
        }
    }
    back_on(&was_on);
    let _ = daemon::request_sync(store, "reload", json!({}), false);
    Ok(json!({"from": from, "to": destination, "projects": moved}))
}

/// Moves a folder or repository into another folder of the projects folder.
pub fn move_into(store: &Store, from: &Path, into: &Path) -> Result<Value> {
    let root = root(store)?.ok_or_else(|| anyhow::anyhow!("invalid_path"))?;
    let from = inside(&root, from)?;
    let into = inside(&root, into)?;
    ensure!(from != root, "invalid_path");
    ensure!(from.parent() != Some(into.as_path()), "same_folder");
    let name = from
        .file_name()
        .ok_or_else(|| anyhow::anyhow!("invalid_path"))?;
    relocate_dir(store, &root, &from, &into.join(name))
}

pub fn rename_folder(store: &Store, path: &Path, name: &str) -> Result<Value> {
    ensure!(valid_name(name), "invalid_folder");
    let root = root(store)?.ok_or_else(|| anyhow::anyhow!("invalid_path"))?;
    let path = inside(&root, path)?;
    let parent = path
        .parent()
        .ok_or_else(|| anyhow::anyhow!("invalid_path"))?;
    ensure!(path.file_name().is_some_and(|n| n != name), "same_folder");
    relocate_dir(store, &root, &path, &parent.join(name))
}

pub fn create_folder(store: &Store, parent: &Path, name: &str) -> Result<Value> {
    ensure!(valid_name(name), "invalid_folder");
    let root = root(store)?.ok_or_else(|| anyhow::anyhow!("invalid_path"))?;
    let parent = inside(&root, parent)?;
    let path = parent.join(name);
    ensure!(fs::symlink_metadata(&path).is_err(), "folder_exists");
    fs::create_dir(&path)?;
    Ok(json!({"path": path}))
}

/// Removes a folder only when it is empty (a `.DS_Store` of Finder aside): never a project.
pub fn remove_folder(store: &Store, path: &Path) -> Result<Value> {
    let root = root(store)?.ok_or_else(|| anyhow::anyhow!("invalid_path"))?;
    let path = inside(&root, path)?;
    ensure!(path != root, "invalid_path");
    let entries: Vec<_> = fs::read_dir(&path)?.flatten().collect();
    ensure!(
        entries.iter().all(|e| e.file_name() == ".DS_Store"),
        "folder_not_empty"
    );
    for entry in entries {
        fs::remove_file(entry.path())?;
    }
    fs::remove_dir(&path)?;
    Ok(json!({"path": path}))
}

// ---- The first comparison with groups.json --------------------------------------------------------

fn normalized(name: &str) -> String {
    name.chars()
        .filter(|c| c.is_alphanumeric())
        .flat_map(char::to_lowercase)
        .collect()
}

/// What each group of `groups.json` would become on the disk: the ones whose projects are
/// already together in a folder of the same name match; for the others, the moves that would
/// put their projects in a folder of that name (nothing is moved until the user accepts).
pub fn plan(store: &Store) -> Result<Value> {
    let root = root(store)?.ok_or_else(|| anyhow::anyhow!("invalid_path"))?;
    let records = store.list()?;
    let mut matches = vec![];
    let mut proposals = vec![];
    for group in store.groups()?.into_iter().filter(|g| g.path.is_none()) {
        let present: Vec<&Project> = group
            .sites
            .iter()
            .filter_map(|s| records.iter().find(|p| &p.id == s))
            .collect();
        if present.is_empty() {
            continue;
        }
        let parents: BTreeSet<PathBuf> = present
            .iter()
            .filter_map(|p| canonical(&p.path).parent().map(Path::to_path_buf))
            .collect();
        let together = match parents.iter().collect::<Vec<_>>().as_slice() {
            [dir] if dir.starts_with(&root) && **dir != root => Some((*dir).clone()),
            _ => None,
        };
        let name_matches = |dir: &Path| {
            dir.file_name()
                .is_some_and(|n| normalized(&n.to_string_lossy()) == normalized(&group.name))
        };
        if let Some(dir) = together.filter(|d| name_matches(d)) {
            let rel = dir.strip_prefix(&root)?.to_string_lossy().into_owned();
            matches.push(
                json!({"group": group.id, "name": group.name, "kind": group.kind, "path": rel}),
            );
            continue;
        }
        let clean: String = group
            .name
            .chars()
            .map(|c| if c.is_control() || c == '/' { '-' } else { c })
            .collect::<String>()
            .trim()
            .trim_start_matches('.')
            .to_string();
        let target = root.join(if clean.is_empty() { &group.id } else { &clean });
        let moves: Vec<Value> = present
            .iter()
            .filter(|p| canonical(&p.path).parent() != Some(target.as_path()))
            .map(|p| {
                let name = p.path.file_name().unwrap_or_default();
                json!({"site": p.id, "title": p.name, "from": canonical(&p.path),
                    "to": target.join(name), "conflict": target.join(name).exists()})
            })
            .collect();
        proposals.push(json!({
            "group": group.id, "name": group.name, "kind": group.kind,
            "path": target.strip_prefix(&root)?, "moves": moves,
        }));
    }
    Ok(json!({"matches": matches, "proposals": proposals}))
}

/// Converts the groups that match and, when `accept`, moves the projects of the rest into a
/// folder of the group's name. Either way the sidebar follows the disk from then on.
pub fn migrate(store: &Store, accept: bool) -> Result<Value> {
    let root = root(store)?.ok_or_else(|| anyhow::anyhow!("invalid_path"))?;
    reconcile(store)?;
    let original = store.root().join("groups.json");
    let backup = store.root().join("groups.pre-disk.json");
    if original.is_file() && !backup.exists() {
        fs::copy(&original, &backup)?;
    }
    let plan = plan(store)?;
    let mut groups = store.groups()?;
    let mut place = |id: &str, rel: &str| {
        if let Some(group) = groups.iter_mut().find(|g| g.id == id)
            && group.is_project()
        {
            group.path = Some(rel.to_string());
        }
    };
    for item in plan["matches"].as_array().into_iter().flatten() {
        place(
            item["group"].as_str().unwrap_or(""),
            item["path"].as_str().unwrap_or(""),
        );
    }
    if accept {
        for item in plan["proposals"].as_array().into_iter().flatten() {
            let rel = item["path"].as_str().unwrap_or("");
            if !SiteGroup::valid_relative(rel) {
                continue;
            }
            let target = root.join(rel);
            fs::create_dir_all(&target)?;
            for step in item["moves"].as_array().into_iter().flatten() {
                if step["conflict"] == true {
                    continue;
                }
                let from = PathBuf::from(step["from"].as_str().unwrap_or(""));
                let _ = move_into(store, &from, &target);
            }
            place(item["group"].as_str().unwrap_or(""), rel);
        }
    }
    // `place` borrowed `groups`; the moves may have rewritten the file, so merge on what is there.
    let fresh = store.groups()?;
    let placed: BTreeMap<String, String> = groups
        .iter()
        .filter_map(|g| g.path.clone().map(|p| (g.id.clone(), p)))
        .collect();
    let merged: Vec<SiteGroup> = fresh
        .into_iter()
        .map(|mut g| {
            if g.path.is_none()
                && let Some(path) = placed.get(&g.id)
            {
                g.path = Some(path.clone());
            }
            g
        })
        .collect();
    store.save_groups(merged)?;
    update(store, |disk| disk.enabled = true)?;
    Ok(json!({"plan": plan}))
}

/// Goes back to the groups of `groups.json` (the disk keeps being what it is).
pub fn set_enabled(store: &Store, enabled: bool) -> Result<()> {
    update(store, |disk| disk.enabled = enabled)
}

// ---- The daemon's side -----------------------------------------------------------------------------

/// How many changes of the folder this daemon has seen: what a watching client compares.
static REVISION: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);

pub fn revision() -> u64 {
    REVISION.load(std::sync::atomic::Ordering::SeqCst)
}

/// Looks at the projects folder every 400 ms and tells the subscribers when it changed. The
/// folder is a few dozen entries: reading it costs less than keeping a watcher alive across
/// volumes, and a change reaches the sidebar in well under a second.
pub async fn watch_loop(events: tokio::sync::broadcast::Sender<Value>) {
    let mut last: Option<String> = None;
    loop {
        tokio::time::sleep(std::time::Duration::from_millis(400)).await;
        let step = tokio::task::spawn_blocking(|| -> Result<Option<String>> {
            let store = Store::from_environment()?;
            if !load(&store)?.enabled {
                return Ok(None);
            }
            let print = fingerprint(&store)?;
            Ok(Some(print))
        })
        .await;
        let Ok(Ok(Some(print))) = step else {
            last = None;
            continue;
        };
        if last.as_ref() == Some(&print) {
            continue;
        }
        last = Some(print);
        let _ = tokio::task::spawn_blocking(|| {
            Store::from_environment().and_then(|store| reconcile(&store))
        })
        .await;
        let revision = REVISION.fetch_add(1, std::sync::atomic::Ordering::SeqCst) + 1;
        let _ = events.send(json!({"event": "disk.changed", "revision": revision}));
    }
}

#[cfg(test)]
#[path = "disk_tests.rs"]
mod tests;
