//! Health: what is wrong with the skills and their links, without changing anything.
use super::model::{Ctx, Index};
use super::{agents, links, skill_file};
use serde_json::{Value, json};
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
        out.extend(agent_paths(ctx, index, id, &entry.agents, &dir));
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
    out
}

/// Text files of one skill read for `agent_path`: at most this many, this many bytes in total.
const PATH_FILES: usize = 100;
const PATH_BYTES: u64 = 2 * 1024 * 1024;

/// Whether `text` names `<folder>/<id>` as a whole path segment (`<id>-other` does not count).
fn names_path(text: &str, needle: &str) -> bool {
    text.match_indices(needle).any(|(at, _)| {
        text[at + needle.len()..]
            .chars()
            .next()
            .is_none_or(|c| !(c.is_ascii_alphanumeric() || c == '-' || c == '_'))
    })
}

/// A text file of the skill: a regular file (never a link) within [`MAX_TEXT`], without NUL bytes.
fn read_plain(path: &std::path::Path) -> Option<String> {
    use std::io::Read;
    use std::os::unix::fs::OpenOptionsExt;
    let file = fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(path)
        .ok()?;
    let meta = file.metadata().ok()?;
    if !meta.is_file() || meta.len() > super::model::MAX_TEXT {
        return None;
    }
    let mut bytes = Vec::new();
    file.take(super::model::MAX_TEXT + 1)
        .read_to_end(&mut bytes)
        .ok()?;
    if bytes.len() as u64 > super::model::MAX_TEXT || bytes.contains(&0) {
        return None;
    }
    Some(String::from_utf8_lossy(&bytes).into_owned())
}

/// `agent_path`: the skill's own text names `<AI folder>/<its id>` of a link-mode AI it is not
/// linked to. Only the skill's own id counts. The files are read to find those paths and nothing
/// of them is kept or returned: a finding carries the skill, the AI and its folder.
fn agent_paths(
    ctx: &Ctx,
    index: &Index,
    id: &str,
    linked: &[String],
    dir: &std::path::Path,
) -> Vec<Value> {
    let mut candidates = vec![];
    for agent in agents::all(index) {
        if linked.contains(&agent.id) {
            continue;
        }
        let Ok(Some(folder)) = agents::folder(ctx, &agent) else {
            continue;
        };
        let mut needles = vec![format!("{}/{id}", folder.to_string_lossy())];
        if let Ok(rest) = folder.strip_prefix(&ctx.home) {
            let rest = rest.to_string_lossy();
            needles.push(format!("~/{rest}/{id}"));
            needles.push(format!("$HOME/{rest}/{id}"));
            needles.push(format!("${{HOME}}/{rest}/{id}"));
        }
        if let Some(stored) = &agent.folder {
            needles.push(format!("{}/{id}", stored.trim_end_matches('/')));
        }
        candidates.push((agent.id, folder, needles));
    }
    if candidates.is_empty() {
        return vec![];
    }
    let mut found = vec![false; candidates.len()];
    let mut names = vec!["SKILL.md".to_string()];
    names.extend(skill_file::files(dir).into_iter().take(PATH_FILES));
    let mut total = 0u64;
    for name in names {
        let Some(text) = read_plain(&dir.join(&name)) else {
            continue;
        };
        total += text.len() as u64;
        for (i, (_, _, needles)) in candidates.iter().enumerate() {
            if !found[i] && needles.iter().any(|n| names_path(&text, n)) {
                found[i] = true;
            }
        }
        if total > PATH_BYTES || found.iter().all(|f| *f) {
            break;
        }
    }
    candidates
        .into_iter()
        .zip(found)
        .filter(|(_, hit)| *hit)
        .map(|((agent, folder, _), _)| {
            json!({"kind": "agent_path", "skill": id, "agent": agent, "path": folder.to_string_lossy()})
        })
        .collect()
}
