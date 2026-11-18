//! `index.json`: groups, per-skill metadata and agents. Written atomically (0600) by the engine only.
use super::agents;
use super::model::{Ctx, Entry, Group, INDEX_VERSION, Index, valid_id};
use crate::core::json;
use anyhow::Result;
use std::{collections::BTreeMap, fs};

fn default_groups() -> Vec<Group> {
    [
        ("personal", "Personal"),
        ("trabajo", "Trabajo"),
        ("butake", "Butake"),
    ]
    .iter()
    .enumerate()
    .map(|(order, (id, name))| Group {
        id: id.to_string(),
        name: name.to_string(),
        order: order as i64,
    })
    .collect()
}

/// Reads the index (or the defaults), drops what is invalid, and adopts skill folders that exist on
/// disk without an entry (put in the first group). Nothing is written.
pub fn load(ctx: &Ctx) -> Result<Index> {
    let path = ctx.skills.join("index.json");
    let fresh = || Index {
        version: INDEX_VERSION,
        groups: default_groups(),
        skills: BTreeMap::new(),
        agents: BTreeMap::new(),
    };
    let mut index: Index = if fs::symlink_metadata(&path).is_ok() {
        match json::read_regular(&path, Some(1_048_576)) {
            Ok(index) => index,
            Err(_) => {
                // An index that cannot be read (damaged by hand or by a sync, too large, not a
                // regular file) is set aside as `index.json.bad` and the tool starts from the
                // defaults: the skill folders on disk are adopted again below.
                let _ = fs::rename(&path, ctx.skills.join("index.json.bad"));
                fresh()
            }
        }
    } else {
        fresh()
    };
    index.version = INDEX_VERSION;
    index.groups.retain(|g| valid_id(&g.id));
    if index.groups.is_empty() {
        index.groups = default_groups();
    }
    index
        .groups
        .sort_by(|a, b| (a.order, &a.id).cmp(&(b.order, &b.id)));
    index.agents.retain(|id, _| valid_id(id));
    agents::normalize(&mut index);
    let first = index.groups[0].id.clone();
    let known: Vec<String> = agents::all(&index).into_iter().map(|a| a.id).collect();
    index.skills.retain(|id, _| valid_id(id));
    for entry in index.skills.values_mut() {
        if !index.groups.iter().any(|g| g.id == entry.group) {
            entry.group = first.clone();
        }
        entry.agents.retain(|a| known.contains(a));
        let mut seen = Vec::new();
        entry.agents.retain(|a| {
            let new = !seen.contains(a);
            seen.push(a.clone());
            new
        });
    }
    if let Ok(read) = fs::read_dir(&ctx.skills) {
        for item in read.flatten() {
            let name = item.file_name().to_string_lossy().to_string();
            let real_dir = item.file_type().is_ok_and(|t| t.is_dir());
            if real_dir
                && valid_id(&name)
                && !index.skills.contains_key(&name)
                && fs::symlink_metadata(item.path().join("SKILL.md")).is_ok_and(|m| m.is_file())
            {
                index.skills.insert(
                    name,
                    Entry {
                        group: first.clone(),
                        tags: vec![],
                        enabled: true,
                        agents: vec![],
                    },
                );
            }
        }
    }
    Ok(index)
}

pub fn save(ctx: &Ctx, index: &Index) -> Result<()> {
    json::write(&ctx.skills.join("index.json"), index)
}
