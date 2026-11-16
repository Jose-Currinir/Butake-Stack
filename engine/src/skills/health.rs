//! Health: what is wrong with the skills and their links, without changing anything.
use super::model::{Ctx, Index};
use super::{agents, links, skill_file};
use serde_json::{json, Value};
use std::{collections::BTreeMap, fs};

pub fn check(ctx: &Ctx, index: &Index) -> Vec<Value> {
    let mut out = vec![];
    let mut names: BTreeMap<String, Vec<String>> = BTreeMap::new();
    for (id, entry) in &index.skills {
        let Ok(dir) = ctx.dir(id) else { continue };
        if !skill_file::real_dir(&dir) {
            out.push(json!({"kind": "missing_folder", "skill": id}));
            continue;
        }
        let meta = skill_file::read_text(&dir)
            .map(|t| skill_file::parse(&t))
            .unwrap_or_default();
        if meta.description.trim().is_empty() {
            out.push(json!({"kind": "no_description", "skill": id}));
        }
        let name = if meta.name.is_empty() {
            id.clone()
        } else {
            meta.name
        };
        names.entry(name).or_default().push(id.clone());
        if entry.agents.is_empty() {
            out.push(json!({"kind": "unused", "skill": id}));
        }
        if !entry.enabled {
            continue;
        }
        for agent_id in &entry.agents {
            let Some(agent) = agents::find(index, agent_id) else {
                continue;
            };
            let Ok(Some(folder)) = agents::folder(ctx, &agent) else {
                continue;
            };
            let path = folder.join(id);
            let shown = path.to_string_lossy();
            if links::is_link_to(ctx, &path, id) {
                continue;
            }
            let kind = if links::is_absent(&path) {
                "broken_link"
            } else {
                "conflict"
            };
            out.push(json!({"kind": kind, "skill": id, "agent": agent_id, "path": shown}));
        }
    }
    for ids in names.values().filter(|ids| ids.len() > 1) {
        for id in ids {
            out.push(json!({"kind": "duplicate_name", "skill": id}));
        }
    }
    for agent in agents::all(index) {
        let Ok(Some(folder)) = agents::folder(ctx, &agent) else {
            continue;
        };
        if !skill_file::real_dir(&folder) {
            if !agent.builtin {
                out.push(json!({"kind": "missing_folder", "agent": agent.id, "path": folder.to_string_lossy()}));
            }
            continue;
        }
        let Ok(read) = fs::read_dir(&folder) else {
            continue;
        };
        for item in read.flatten() {
            let path = item.path();
            // A link into Stack's skills whose skill is gone.
            if links::points_into(ctx, &path)
                && !links::target_of(&path).is_some_and(|t| t.exists())
            {
                out.push(json!({"kind": "broken_link", "agent": agent.id, "path": path.to_string_lossy()}));
            }
        }
    }
    // Links left in a former built-in folder (`~/.codex/skills`): `skillsLinkPlan` with `migrate`.
    if let Ok((moves, _)) = links::migration(ctx, index, agents::LEGACY_CODEX.0) {
        if let Some(first) = moves.first().and_then(|m| m.old.parent()) {
            out.push(json!({"kind": "moved_folder", "agent": agents::LEGACY_CODEX.0, "path": first.to_string_lossy()}));
        }
    }
    out
}
