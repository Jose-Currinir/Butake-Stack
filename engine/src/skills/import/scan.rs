//! Read-only scan of the folders of the link-mode AIs for skills that are not Stack's yet.
//! Nothing is written, no link is followed while reading a tree, and the work is bounded.
use super::tree;
use crate::skills::model::{valid_id, Ctx, Index};
use crate::skills::{agents, links, skill_file};
use serde_json::{json, Value};
use std::{
    collections::BTreeMap,
    fs,
    path::{Path, PathBuf},
};

/// Entries read per AI folder, candidates kept and bytes hashed in one scan.
const MAX_ENTRIES: usize = 500;
const MAX_CANDIDATES: usize = 500;
const MAX_TOTAL: u64 = 256 * 1024 * 1024;

#[derive(Clone)]
pub struct Source {
    pub agent: String,
    /// Where the entry is in the AI folder.
    pub path: PathBuf,
    /// A link (to a folder somewhere else), not a real folder.
    pub link: bool,
    /// What the link says as stored.
    pub target: Option<PathBuf>,
    /// The real folder holding the files (the entry itself for a real folder).
    pub real: PathBuf,
    /// Digest of the tree; `None` when it is too large to hash.
    pub hash: Option<String>,
    /// Links and special files inside the folder: an import leaves them out.
    pub skipped: Vec<String>,
}

pub struct Candidate {
    pub name: String,
    pub title: String,
    pub description: String,
    pub sources: Vec<Source>,
    pub identical: bool,
    pub valid: bool,
    pub reason: Option<String>,
    pub hidden: bool,
}

/// An entry of an AI folder that holds a SKILL.md and does not resolve into Stack's folder.
fn source_of(ctx: &Ctx, root: &Path, agent: &str, path: &Path) -> Option<Source> {
    let meta = fs::symlink_metadata(path).ok()?;
    let (link, real, target) = if meta.is_dir() {
        (false, path.to_path_buf(), None)
    } else if meta.file_type().is_symlink() {
        if links::points_into(ctx, path) {
            return None;
        }
        let real = path.canonicalize().ok()?;
        if !real.is_dir() || !real.starts_with(&ctx.home) || real.starts_with(root) {
            return None;
        }
        (true, real, fs::read_link(path).ok())
    } else {
        return None;
    };
    fs::symlink_metadata(real.join("SKILL.md"))
        .is_ok_and(|m| m.is_file())
        .then(|| Source {
            agent: agent.to_string(),
            path: path.to_path_buf(),
            link,
            target,
            real,
            hash: None,
            skipped: vec![],
        })
}

type Digests = BTreeMap<PathBuf, (Option<String>, Vec<String>)>;

fn hash_of(cache: &mut Digests, total: &mut u64, real: &Path) -> (Option<String>, Vec<String>) {
    if let Some(known) = cache.get(real) {
        return known.clone();
    }
    let digest = if *total > MAX_TOTAL {
        None
    } else {
        tree::digest(real).ok()
    };
    let found = match digest {
        Some(t) => {
            *total += t.bytes;
            (Some(t.hash), t.skipped)
        }
        None => (None, vec![]),
    };
    cache.insert(real.to_path_buf(), found.clone());
    found
}

/// Every candidate, by name: entries with the same real folder or the same bytes are one source
/// list; the same name with different bytes is one candidate with `identical: false`.
pub fn scan(ctx: &Ctx, index: &Index) -> Vec<Candidate> {
    let root = ctx.root.canonicalize().unwrap_or_else(|_| ctx.root.clone());
    let mut found: BTreeMap<String, Vec<Source>> = BTreeMap::new();
    for agent in agents::all(index) {
        let Ok(Some(folder)) = agents::folder(ctx, &agent) else {
            continue;
        };
        let Ok(read) = fs::read_dir(&folder) else {
            continue;
        };
        let mut names: Vec<String> = read
            .flatten()
            .filter_map(|i| i.file_name().to_str().map(String::from))
            .collect();
        names.sort();
        names.truncate(MAX_ENTRIES);
        for name in names {
            if let Some(source) = source_of(ctx, &root, &agent.id, &folder.join(&name)) {
                found.entry(name).or_default().push(source);
            }
        }
    }
    let (mut cache, mut total) = (BTreeMap::new(), 0u64);
    let mut list = vec![];
    for (name, mut sources) in found.into_iter().take(MAX_CANDIDATES) {
        for source in sources.iter_mut() {
            (source.hash, source.skipped) = hash_of(&mut cache, &mut total, &source.real);
        }
        let identical = sources.iter().all(|s| s.hash == sources[0].hash);
        let (meta, unreadable) = match skill_file::read_text(&sources[0].real) {
            Ok(text) => (skill_file::parse(&text), None),
            Err(error) => (skill_file::Meta::default(), Some(error.to_string())),
        };
        let reason = if !valid_id(&name) {
            Some("skills_invalid_id".to_string())
        } else if index.skills.contains_key(&name)
            || fs::symlink_metadata(ctx.skills.join(&name)).is_ok()
        {
            Some("skills_exists".to_string())
        } else if sources.iter().any(|s| s.hash.is_none()) {
            Some("skills_too_large".to_string())
        } else {
            unreadable
        };
        list.push(Candidate {
            title: if meta.name.is_empty() {
                name.clone()
            } else {
                meta.name
            },
            description: meta.description,
            hidden: name.starts_with('.'),
            valid: reason.is_none(),
            reason,
            identical,
            sources,
            name,
        });
    }
    list
}

pub fn json(list: &[Candidate]) -> Value {
    Value::Array(
        list.iter()
            .map(|c| {
                let sources: Vec<Value> = c
                    .sources
                    .iter()
                    .map(|s| {
                        let mut source = json!({
                            "agent": s.agent, "path": s.path.to_string_lossy(),
                            "kind": if s.link { "link" } else { "folder" },
                        });
                        if !s.skipped.is_empty() {
                            source["skipped"] = json!(s.skipped);
                        }
                        source
                    })
                    .collect();
                let mut item = json!({
                    "id": c.name, "name": c.title, "description": c.description,
                    "sources": sources, "identical": c.identical, "valid": c.valid,
                    "hidden": c.hidden,
                });
                if let Some(reason) = &c.reason {
                    item["reason"] = json!(reason);
                }
                item
            })
            .collect(),
    )
}
