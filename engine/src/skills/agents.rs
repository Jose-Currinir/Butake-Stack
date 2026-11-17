//! The AIs that get skills: built-in ones, custom ones, and the validation of their folders.
use super::model::{fail, valid_id, AgentCfg, Ctx, Index};
use crate::core::validate;
use anyhow::Result;
use serde_json::{json, Value};
use std::path::{Component, Path, PathBuf};

/// id, name, folder (`None` = export only). Kiro is export only: Kiro Crew's skill scanner drops a
/// link in `~/.kiro/crew/skills` that resolves outside its own roots (unless the user lists the folder in
/// its own settings), so Stack neither links there nor reads `~/.kiro`. The Codex folder is the shared `~/.agents/skills` (other
/// AIs install real skill folders there; those are conflicts and stay untouched).
const BUILTIN: &[(&str, &str, Option<&str>)] = &[
    ("claude", "Claude", Some("~/.claude/skills")),
    ("codex", "Codex", Some("~/.agents/skills")),
    ("gemini", "Gemini", Some("~/.gemini/skills")),
    ("chatgpt", "ChatGPT", None),
    ("kiro", "Kiro", None),
];

pub struct Agent {
    pub id: String,
    pub name: String,
    /// The folder as stored (`~/…`); `None` for export-only agents.
    pub folder: Option<String>,
    pub builtin: bool,
}

pub fn is_builtin(id: &str) -> bool {
    BUILTIN.iter().any(|(b, _, _)| *b == id)
}

/// Built-in agents always carry their own folder; only valid custom ones stay.
pub fn normalize(index: &mut Index) {
    index.agents.retain(|id, cfg| {
        !is_builtin(id) && validate::printable(&cfg.name, 40) && !cfg.name.is_empty()
    });
    for (id, _, folder) in BUILTIN {
        if let Some(folder) = folder {
            index.agents.insert(
                id.to_string(),
                AgentCfg {
                    folder: folder.to_string(),
                    name: String::new(),
                },
            );
        }
    }
}

pub fn all(index: &Index) -> Vec<Agent> {
    let mut list: Vec<Agent> = BUILTIN
        .iter()
        .map(|(id, name, folder)| Agent {
            id: id.to_string(),
            name: name.to_string(),
            folder: folder.map(String::from),
            builtin: true,
        })
        .collect();
    for (id, cfg) in &index.agents {
        if !is_builtin(id) {
            list.push(Agent {
                id: id.clone(),
                name: cfg.name.clone(),
                folder: Some(cfg.folder.clone()),
                builtin: false,
            });
        }
    }
    list
}

pub fn find(index: &Index, id: &str) -> Option<Agent> {
    all(index).into_iter().find(|a| a.id == id)
}

fn lexical(path: &Path) -> Option<PathBuf> {
    let mut out = PathBuf::new();
    for part in path.components() {
        match part {
            Component::ParentDir | Component::CurDir => return None,
            other => out.push(other.as_os_str()),
        }
    }
    Some(out)
}

/// A folder the user chose, validated: `~/…` or absolute, no `..`, under the home (canonical, after
/// resolving links), never the home itself, never Stack's data folder or something that holds it.
pub fn resolve(ctx: &Ctx, raw: &str) -> Result<PathBuf> {
    if raw.is_empty() || raw.len() > 1024 || raw.contains('\0') {
        return fail("skills_invalid_folder");
    }
    let expanded = match raw.strip_prefix("~/") {
        Some(rest) => ctx.home.join(rest),
        None => PathBuf::from(raw),
    };
    let Some(expanded) = lexical(&expanded).filter(|p| p.is_absolute()) else {
        return fail("skills_invalid_folder");
    };
    // The deepest ancestor that exists is canonicalized; the rest is appended as written.
    let mut base = expanded.clone();
    let mut rest = Vec::new();
    let canonical = loop {
        match base.canonicalize() {
            Ok(path) => break path,
            Err(_) => {
                let Some(name) = base.file_name().map(|n| n.to_owned()) else {
                    return fail("skills_invalid_folder");
                };
                rest.push(name);
                if !base.pop() {
                    return fail("skills_invalid_folder");
                }
            }
        }
    };
    let resolved = rest.iter().rev().fold(canonical, |p, n| p.join(n));
    let inside = resolved.starts_with(&ctx.home) && resolved != ctx.home;
    if !inside || resolved.starts_with(&ctx.root) || ctx.root.starts_with(&resolved) {
        return fail("skills_invalid_folder");
    }
    Ok(resolved)
}

/// The folder of an agent on disk; `None` when it only exports.
pub fn folder(ctx: &Ctx, agent: &Agent) -> Result<Option<PathBuf>> {
    agent.folder.as_deref().map(|f| resolve(ctx, f)).transpose()
}

pub fn list_json(ctx: &Ctx, index: &Index) -> Vec<Value> {
    all(index)
        .into_iter()
        .map(|a| {
            let exists = folder(ctx, &a)
                .ok()
                .flatten()
                .is_some_and(|p| super::skill_file::real_dir(&p));
            json!({
                "id": a.id, "name": a.name, "folder": a.folder,
                "mode": if a.folder.is_some() { "link" } else { "export" },
                "builtin": a.builtin, "exists": exists,
            })
        })
        .collect()
}

/// Creates or edits a custom agent.
pub fn save(ctx: &Ctx, index: &mut Index, id: &str, name: &str, raw_folder: &str) -> Result<()> {
    if !valid_id(id) {
        return fail("skills_invalid_id");
    }
    if is_builtin(id) {
        return fail("skills_agent_builtin");
    }
    if name.is_empty() || !validate::printable(name, 40) {
        return fail("invalid_name");
    }
    let path = resolve(ctx, raw_folder)?;
    for other in all(index) {
        if other.id != id {
            if let Ok(Some(existing)) = folder(ctx, &other) {
                if existing == path {
                    return fail("skills_invalid_folder");
                }
            }
        }
    }
    if let Some(old) = index.agents.get(id) {
        let same = resolve(ctx, &old.folder).is_ok_and(|p| p == path);
        let linked = index
            .skills
            .values()
            .any(|e| e.agents.iter().any(|a| a == id));
        // Moving the folder of an agent with linked skills would leave its links behind.
        if !same && linked {
            return fail("skills_link_conflict");
        }
    }
    index.agents.insert(
        id.to_string(),
        AgentCfg {
            folder: raw_folder.to_string(),
            name: name.to_string(),
        },
    );
    Ok(())
}
