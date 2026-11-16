//! Deleted skills wait 30 days in `skills-trash/<id>-<epoch>/` (`entry.json` + `files/`) so that
//! «Deshacer» can bring them back with their links.
use super::model::{fail, valid_id, Ctx, Entry, Index, TRASH_DAYS};
use super::{links, skill_file};
use crate::core::{json, time::now_secs};
use anyhow::Result;
use serde::{Deserialize, Serialize};
use std::fs;

#[derive(Serialize, Deserialize)]
struct Saved {
    id: String,
    entry: Entry,
}

fn parse_id(trash_id: &str) -> Option<(String, u64)> {
    let (id, epoch) = trash_id.rsplit_once('-')?;
    let epoch = epoch.parse().ok()?;
    valid_id(id).then(|| (id.to_string(), epoch))
}

/// Removes what has waited more than 30 days.
pub fn purge(ctx: &Ctx) {
    let Ok(read) = fs::read_dir(&ctx.trash) else {
        return;
    };
    let limit = now_secs().saturating_sub(TRASH_DAYS * 86_400);
    for item in read.flatten() {
        let name = item.file_name().to_string_lossy().to_string();
        let old = parse_id(&name).is_some_and(|(_, epoch)| epoch < limit);
        // The import trash is never purged: it stays until the user empties it.
        if old
            && item.file_type().is_ok_and(|t| t.is_dir())
            && !super::import::is_import(&item.path())
        {
            let _ = fs::remove_dir_all(item.path());
        }
    }
}

/// Moves the skill's folder to the trash with its entry. Returns the trash id.
pub fn put(ctx: &Ctx, id: &str, entry: &Entry) -> Result<String> {
    let mut epoch = now_secs();
    while ctx.trash.join(format!("{id}-{epoch}")).exists() {
        epoch += 1;
    }
    let trash_id = format!("{id}-{epoch}");
    let dir = ctx.trash.join(&trash_id);
    fs::create_dir(&dir)?;
    json::write(
        &dir.join("entry.json"),
        &Saved {
            id: id.into(),
            entry: entry.clone(),
        },
    )?;
    if let Err(error) = fs::rename(ctx.dir(id)?, dir.join("files")) {
        let _ = fs::remove_dir_all(&dir);
        return Err(error.into());
    }
    Ok(trash_id)
}

/// Checks that `trash_id` can be restored and returns its skill id and saved entry.
pub fn peek(ctx: &Ctx, index: &Index, trash_id: &str) -> Result<(String, Entry)> {
    let Some((id, _)) = parse_id(trash_id) else {
        return fail("skills_not_found");
    };
    let dir = ctx.trash.join(trash_id);
    let files = dir.join("files");
    if !skill_file::real_dir(&dir) || !skill_file::real_dir(&files) {
        return fail("skills_not_found");
    }
    let saved: Saved = json::read_regular(&dir.join("entry.json"), Some(1_048_576))?;
    if saved.id != id {
        return fail("skills_not_found");
    }
    let target = ctx.dir(&id)?;
    if index.skills.contains_key(&id) || fs::symlink_metadata(&target).is_ok() {
        return fail("skills_exists");
    }
    let mut entry = saved.entry;
    if !index.has_group(&entry.group) {
        entry.group = index.groups[0].id.clone();
    }
    Ok((id, entry))
}

/// Brings a skill back: its folder, its entry and the links that are still free.
pub fn restore(ctx: &Ctx, index: &mut Index, trash_id: &str) -> Result<String> {
    let (id, entry) = peek(ctx, index, trash_id)?;
    let dir = ctx.trash.join(trash_id);
    fs::rename(dir.join("files"), ctx.dir(&id)?)?;
    let wanted = entry.agents.clone();
    let enabled = entry.enabled;
    index.skills.insert(id.clone(), entry);
    if enabled {
        links::create_for(ctx, index, &id, &wanted);
    }
    let _ = fs::remove_dir_all(&dir);
    Ok(id)
}
