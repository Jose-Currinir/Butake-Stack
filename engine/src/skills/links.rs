//! Symlinks from the AI folders to the real copy of each skill. Planned first, applied only with
//! `confirmed`; only links that resolve into Stack's skills folder are ever removed.
use super::agents;
use super::model::{fail, valid_id, Ctx, Index};
use anyhow::Result;
use serde_json::{json, Value};
use std::{
    fs,
    path::{Component, Path, PathBuf},
};

#[derive(Clone)]
pub struct Change {
    pub skill: String,
    pub agent: String,
    pub on: bool,
}

pub struct Request {
    pub changes: Vec<Change>,
    /// `skill` + `enabled`: turns every link of a skill on or off, keeping its list of AIs.
    pub enabled: Option<(String, bool)>,
}

#[derive(PartialEq, Debug)]
pub enum Action {
    Create,
    Remove,
    Skip,
    Conflict(&'static str),
}

pub struct Op {
    pub change: Change,
    pub path: Option<PathBuf>,
    pub action: Action,
}

pub struct Plan {
    pub ops: Vec<Op>,
}

fn normalize(path: &Path) -> PathBuf {
    let mut out = PathBuf::new();
    for part in path.components() {
        match part {
            Component::ParentDir => {
                out.pop();
            }
            Component::CurDir => {}
            other => out.push(other.as_os_str()),
        }
    }
    out
}

/// Where a symlink points, made absolute and normalized (the target does not have to exist).
pub fn target_of(path: &Path) -> Option<PathBuf> {
    if !fs::symlink_metadata(path).ok()?.file_type().is_symlink() {
        return None;
    }
    let target = fs::read_link(path).ok()?;
    let target = if target.is_absolute() {
        target
    } else {
        path.parent()?.join(target)
    };
    Some(normalize(&target))
}

/// `path` is a symlink to the skill folder `id`.
pub fn is_link_to(ctx: &Ctx, path: &Path, id: &str) -> bool {
    target_of(path).is_some_and(|t| t == ctx.skills.join(id))
}

/// `path` is a symlink that resolves into the skills folder (any skill).
pub fn points_into(ctx: &Ctx, path: &Path) -> bool {
    target_of(path).is_some_and(|t| t.starts_with(&ctx.skills) && t != ctx.skills)
}

fn absent(path: &Path) -> bool {
    matches!(fs::symlink_metadata(path), Err(e) if e.kind() == std::io::ErrorKind::NotFound)
}

/// Reads the request of `skillsLinkPlan` / `skillsLinkApply`.
pub fn parse(request: &Value, index: &Index) -> Result<Request> {
    let known = |skill: &str, agent: Option<&str>| -> Result<()> {
        if !valid_id(skill) || !index.skills.contains_key(skill) {
            return fail("skills_not_found");
        }
        if agent.is_some_and(|a| agents::find(index, a).is_none()) {
            return fail("skills_not_found");
        }
        Ok(())
    };
    if let Some(list) = request["changes"].as_array() {
        if list.len() > 500 {
            return fail("skills_too_large");
        }
        let mut changes = vec![];
        for item in list {
            let skill = item["skill"].as_str().unwrap_or("");
            let agent = item["agent"].as_str().unwrap_or("");
            known(skill, Some(agent))?;
            let Some(on) = item["on"].as_bool() else {
                return fail("invalid_request");
            };
            changes.push(Change {
                skill: skill.into(),
                agent: agent.into(),
                on,
            });
        }
        return Ok(Request {
            changes,
            enabled: None,
        });
    }
    let skill = request["skill"].as_str().unwrap_or("");
    known(skill, None)?;
    let Some(enabled) = request["enabled"].as_bool() else {
        return fail("invalid_request");
    };
    let changes = index.skills[skill]
        .agents
        .iter()
        .map(|agent| Change {
            skill: skill.into(),
            agent: agent.clone(),
            on: true,
        })
        .collect();
    Ok(Request {
        changes,
        enabled: Some((skill.into(), enabled)),
    })
}

pub fn plan(ctx: &Ctx, index: &Index, request: &Request) -> Result<Plan> {
    let mut ops = vec![];
    for change in &request.changes {
        let entry = &index.skills[&change.skill];
        let enabled = match &request.enabled {
            Some((skill, on)) if *skill == change.skill => *on,
            _ => entry.enabled,
        };
        let want = change.on && enabled;
        let agent = agents::find(index, &change.agent)
            .ok_or_else(|| anyhow::anyhow!("skills_not_found"))?;
        let Some(folder) = agents::folder(ctx, &agent)? else {
            let action = if change.on {
                Action::Conflict("export_only")
            } else {
                Action::Skip
            };
            ops.push(Op {
                change: change.clone(),
                path: None,
                action,
            });
            continue;
        };
        let path = folder.join(&change.skill);
        let action = if is_link_to(ctx, &path, &change.skill) {
            if want {
                Action::Skip
            } else {
                Action::Remove
            }
        } else if absent(&path) {
            if want {
                Action::Create
            } else {
                Action::Skip
            }
        } else if want {
            Action::Conflict("exists")
        } else {
            Action::Skip
        };
        ops.push(Op {
            change: change.clone(),
            path: Some(path),
            action,
        });
    }
    Ok(Plan { ops })
}

fn strings(paths: impl Iterator<Item = PathBuf>) -> Vec<String> {
    paths.map(|p| p.to_string_lossy().to_string()).collect()
}

pub fn plan_json(plan: &Plan) -> Value {
    let paths = |wanted: &Action| {
        strings(
            plan.ops
                .iter()
                .filter(|o| &o.action == wanted)
                .filter_map(|o| o.path.clone()),
        )
    };
    json!({"create": paths(&Action::Create), "remove": paths(&Action::Remove), "conflicts": conflicts(plan)})
}

fn conflicts(plan: &Plan) -> Vec<Value> {
    plan.ops
        .iter()
        .filter_map(|o| match o.action {
            Action::Conflict(reason) => Some(json!({
                "path": o.path.as_ref().map(|p| p.to_string_lossy().to_string()).unwrap_or_default(),
                "reason": reason,
            })),
            _ => None,
        })
        .collect()
}

/// Makes the link, creating the AI folder when needed. `false` when something else is there.
fn create(ctx: &Ctx, id: &str, path: &Path) -> Result<bool> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    match std::os::unix::fs::symlink(ctx.skills.join(id), path) {
        Ok(()) => Ok(true),
        Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => Ok(false),
        Err(e) => Err(e.into()),
    }
}

/// Removes `path` only if it is still a link into the skill's folder.
fn remove(ctx: &Ctx, id: &str, path: &Path) -> bool {
    is_link_to(ctx, path, id) && fs::remove_file(path).is_ok()
}

/// Applies a plan and updates the index (`agents`, `enabled`); the caller saves it.
pub fn apply(ctx: &Ctx, index: &mut Index, request: &Request, plan: &Plan) -> Result<Value> {
    let (mut created, mut removed, mut conflicts_list) = (vec![], vec![], conflicts(plan));
    for op in &plan.ops {
        let Some(path) = &op.path else { continue };
        match op.action {
            Action::Create => {
                let made = match create(ctx, &op.change.skill, path) {
                    Ok(made) => made,
                    Err(error) => {
                        // A failure halfway: the links made so far go, so the index (not yet
                        // updated) and the disk say the same thing.
                        for earlier in &plan.ops {
                            if let Some(done) =
                                earlier.path.as_ref().filter(|p| created.contains(*p))
                            {
                                remove(ctx, &earlier.change.skill, done);
                            }
                        }
                        return Err(error);
                    }
                };
                if made {
                    created.push(path.clone());
                } else {
                    conflicts_list
                        .push(json!({"path": path.to_string_lossy(), "reason": "exists"}));
                }
            }
            Action::Remove if remove(ctx, &op.change.skill, path) => removed.push(path.clone()),
            _ => {}
        }
    }
    for op in &plan.ops {
        let blocked = matches!(op.action, Action::Conflict(_))
            || conflicts_list.iter().any(|c| {
                op.path
                    .as_ref()
                    .is_some_and(|p| c["path"] == p.to_string_lossy().as_ref())
            });
        let entry = index
            .skills
            .get_mut(&op.change.skill)
            .expect("planned skill");
        if op.change.on {
            if !blocked && !entry.agents.contains(&op.change.agent) {
                entry.agents.push(op.change.agent.clone());
            }
        } else {
            entry.agents.retain(|a| *a != op.change.agent);
        }
    }
    if let Some((skill, on)) = &request.enabled {
        index.skills.get_mut(skill).expect("planned skill").enabled = *on;
    }
    Ok(
        json!({"created": strings(created.into_iter()), "removed": strings(removed.into_iter()), "conflicts": conflicts_list}),
    )
}

/// The links to skill `id` that exist now in every agent folder.
pub fn existing(ctx: &Ctx, index: &Index, id: &str) -> Vec<PathBuf> {
    agents::all(index)
        .iter()
        .filter_map(|agent| agents::folder(ctx, agent).ok().flatten())
        .map(|folder| folder.join(id))
        .filter(|path| is_link_to(ctx, path, id))
        .collect()
}

/// Removes the links to skill `id` in every agent folder. Returns the paths removed.
pub fn remove_all(ctx: &Ctx, index: &Index, id: &str) -> Vec<PathBuf> {
    existing(ctx, index, id)
        .into_iter()
        .filter(|path| remove(ctx, id, path))
        .collect()
}

/// What `create_for` would do: the links it makes, and the paths where the name is taken.
pub fn creatable(
    ctx: &Ctx,
    index: &Index,
    id: &str,
    agent_ids: &[String],
) -> (Vec<PathBuf>, Vec<PathBuf>) {
    let (mut made, mut taken) = (vec![], vec![]);
    for agent in agent_ids {
        let Some(agent) = agents::find(index, agent) else {
            continue;
        };
        if let Ok(Some(folder)) = agents::folder(ctx, &agent) {
            let path = folder.join(id);
            if absent(&path) {
                made.push(path);
            } else {
                taken.push(path);
            }
        }
    }
    (made, taken)
}

/// `{create, remove, conflicts}` from paths (the conflicts are names already taken).
pub fn plan_value(create: &[PathBuf], remove: &[PathBuf], taken: &[PathBuf]) -> Value {
    let conflicts: Vec<Value> = taken
        .iter()
        .map(|p| json!({"path": p.to_string_lossy(), "reason": "exists"}))
        .collect();
    json!({
        "create": strings(create.iter().cloned()),
        "remove": strings(remove.iter().cloned()),
        "conflicts": conflicts,
    })
}

/// Links skill `id` in the given agents where the name is free. Returns what was created.
pub fn create_for(ctx: &Ctx, index: &Index, id: &str, agent_ids: &[String]) -> Vec<PathBuf> {
    let mut made = vec![];
    for agent in agent_ids {
        let Some(agent) = agents::find(index, agent) else {
            continue;
        };
        if let Ok(Some(folder)) = agents::folder(ctx, &agent) {
            let path = folder.join(id);
            if absent(&path) && create(ctx, id, &path).unwrap_or(false) {
                made.push(path);
            }
        }
    }
    made
}

/// Whether a path in an AI folder is absent (for Health).
pub fn is_absent(path: &Path) -> bool {
    absent(path)
}
