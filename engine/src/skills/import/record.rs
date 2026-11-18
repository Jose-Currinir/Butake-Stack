//! The import trash: `skills-trash/import-<id>-<epoch>/` holds `entry.json` and, in `sources/<n>`,
//! the real folders an import replaced with links. Nothing here is purged by age: it stays until
//! the user empties it.
use crate::core::{json, time::now_secs};
use crate::skills::model::{Ctx, fail, valid_id};
use crate::skills::skill_file;
use anyhow::Result;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{
    fs,
    path::{Path, PathBuf},
};

const PREFIX: &str = "import-";

#[derive(Serialize, Deserialize, Clone)]
pub struct Stored {
    pub agent: String,
    /// The original path in the AI folder.
    pub path: String,
    pub link: bool,
    /// Where a foreign link pointed, to put it back.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub target: Option<String>,
    /// Folder inside the trash entry (`sources/<n>`), for real folders.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub stored: Option<String>,
}

#[derive(Serialize, Deserialize, Clone)]
pub struct Saved {
    pub kind: String,
    pub id: String,
    pub created: u64,
    /// Digest of Stack's copy when it was imported: undo only goes on while it is the same.
    pub hash: String,
    pub sources: Vec<Stored>,
}

/// The skill id of an import trash id (`import-<id>-<epoch>`).
fn parse_id(trash_id: &str) -> Option<String> {
    let (id, epoch) = trash_id.strip_prefix(PREFIX)?.rsplit_once('-')?;
    epoch.parse::<u64>().ok()?;
    valid_id(id).then(|| id.to_string())
}

/// A folder of the trash that the 30-day purge must leave alone: named like an import entry and not
/// the entry of a deleted skill that happens to be called `import-…`.
pub fn is_import(dir: &Path) -> bool {
    let named = dir
        .file_name()
        .is_some_and(|n| n.to_string_lossy().starts_with(PREFIX));
    let deleted_skill = json::read_regular::<Value>(&dir.join("entry.json"), Some(1_048_576))
        .is_ok_and(|v| v.get("entry").is_some() && v.get("kind").is_none());
    named && !deleted_skill
}

/// Makes a new entry folder for skill `id`.
pub fn create(ctx: &Ctx, id: &str) -> Result<(String, PathBuf)> {
    let mut epoch = now_secs();
    while fs::symlink_metadata(ctx.trash.join(format!("{PREFIX}{id}-{epoch}"))).is_ok() {
        epoch += 1;
    }
    let trash_id = format!("{PREFIX}{id}-{epoch}");
    let dir = ctx.trash.join(&trash_id);
    fs::create_dir(&dir)?;
    Ok((trash_id, dir))
}

pub fn write(dir: &Path, saved: &Saved) -> Result<()> {
    json::write(&dir.join("entry.json"), saved)
}

/// Removes an entry folder that holds nothing but its own `entry.json` and empty folders. Never
/// recursive: a folder that still has something in it stays.
pub fn discard(dir: &Path) {
    let _ = fs::remove_file(dir.join("entry.json"));
    let _ = fs::remove_dir(dir.join("sources"));
    let _ = fs::remove_dir(dir);
}

/// The entry `trash_id` names: its folder and what it saved.
pub fn read(ctx: &Ctx, trash_id: &str) -> Result<(PathBuf, Saved)> {
    let Some(id) = parse_id(trash_id) else {
        return fail("skills_not_found");
    };
    let dir = ctx.trash.join(trash_id);
    if !skill_file::real_dir(&dir) {
        return fail("skills_not_found");
    }
    let saved: Saved = json::read_regular(&dir.join("entry.json"), Some(1_048_576))
        .map_err(|_| anyhow::anyhow!("skills_not_found"))?;
    if saved.kind != "import" || saved.id != id {
        return fail("skills_not_found");
    }
    Ok((dir, saved))
}

/// `skillsImportTrashList`: the entries, newest first.
pub fn list(ctx: &Ctx) -> Value {
    let mut entries: Vec<(String, PathBuf, Saved)> = vec![];
    if let Ok(read_dir) = fs::read_dir(&ctx.trash) {
        for item in read_dir.flatten() {
            let name = item.file_name().to_string_lossy().to_string();
            if let Ok((dir, saved)) = read(ctx, &name) {
                entries.push((name, dir, saved));
            }
        }
    }
    entries.sort_by(|a, b| (b.2.created, &b.0).cmp(&(a.2.created, &a.0)));
    Value::Array(
        entries
            .iter()
            .map(|(trash_id, dir, saved)| {
                let sources: Vec<Value> = saved
                    .sources
                    .iter()
                    .map(|s| {
                        json!({
                            "agent": s.agent, "path": s.path,
                            "kind": if s.link { "link" } else { "folder" },
                        })
                    })
                    .collect();
                json!({
                    "trashId": trash_id, "id": saved.id, "created": saved.created,
                    "path": dir.to_string_lossy(), "sources": sources,
                })
            })
            .collect(),
    )
}
