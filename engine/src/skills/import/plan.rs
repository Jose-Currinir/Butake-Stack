//! `skillsImportPlan`: what the import would do, without doing it. The apply re-reads the folders
//! and makes exactly this.
use super::scan::{self, Source};
use crate::skills::model::{fail, Ctx, Index};
use anyhow::Result;
use serde_json::{json, Value};
use std::{collections::BTreeMap, fs, os::unix::fs::MetadataExt, path::PathBuf};

pub struct Request {
    pub ids: Vec<String>,
    pub group: String,
    /// skill id -> the source path to copy from.
    pub choices: BTreeMap<String, String>,
}

pub struct Item {
    pub id: String,
    pub from: PathBuf,
    /// The real folder the copy is made from.
    pub real: PathBuf,
    /// Sources that become links to Stack's copy.
    pub replace: Vec<Source>,
}

pub struct Plan {
    pub group: String,
    pub items: Vec<Item>,
    /// `(path, reason)`: left as they are.
    pub conflicts: Vec<(String, String)>,
}

pub fn parse(request: &Value, index: &Index) -> Result<Request> {
    let Some(list) = request["ids"].as_array() else {
        return fail("invalid_request");
    };
    if list.is_empty() || list.len() > 500 {
        return fail("invalid_request");
    }
    let mut ids: Vec<String> = vec![];
    for item in list {
        let Some(id) = item.as_str() else {
            return fail("invalid_request");
        };
        if !ids.iter().any(|i| i == id) {
            ids.push(id.to_string());
        }
    }
    let group = request["group"].as_str().unwrap_or("");
    if !index.has_group(group) {
        return fail("skills_invalid_group");
    }
    let mut choices = BTreeMap::new();
    for item in request["choices"].as_array().into_iter().flatten() {
        let (Some(id), Some(from)) = (item["id"].as_str(), item["from"].as_str()) else {
            return fail("invalid_request");
        };
        choices.insert(id.to_string(), from.to_string());
    }
    Ok(Request {
        ids,
        group: group.to_string(),
        choices,
    })
}

/// A real folder can only go to the trash with a rename, which needs the same volume.
fn movable(ctx: &Ctx, source: &Source) -> bool {
    match (fs::metadata(&source.path), fs::metadata(&ctx.trash)) {
        (Ok(a), Ok(b)) => a.dev() == b.dev(),
        _ => false,
    }
}

/// Plans the listed candidates. A candidate with different copies needs its choice
/// (`skills_import_choice_required`, or `skills_import_choice_invalid` when `from` is not one of its
/// sources). Only listed ids are planned, so hidden entries are never taken by default.
pub fn build(ctx: &Ctx, index: &Index, request: &Request) -> Result<Plan> {
    let candidates = scan::scan(ctx, index);
    let mut plan = Plan {
        group: request.group.clone(),
        items: vec![],
        conflicts: vec![],
    };
    for id in &request.ids {
        let Some(candidate) = candidates.iter().find(|c| &c.name == id) else {
            plan.conflicts.push((id.clone(), "skills_not_found".into()));
            continue;
        };
        if !candidate.valid {
            let path = candidate.sources[0].path.to_string_lossy().to_string();
            let reason = candidate.reason.clone().unwrap_or_default();
            plan.conflicts.push((path, reason));
            continue;
        }
        let chosen = match request.choices.get(id) {
            Some(from) => match candidate
                .sources
                .iter()
                .find(|s| s.path.to_string_lossy() == from.as_str())
            {
                Some(source) => source,
                None => return fail("skills_import_choice_invalid"),
            },
            None if candidate.identical => &candidate.sources[0],
            None => return fail("skills_import_choice_required"),
        };
        let mut replace = vec![];
        for source in &candidate.sources {
            let path = source.path.to_string_lossy().to_string();
            if source.hash != chosen.hash {
                plan.conflicts.push((path, "not_chosen".into()));
            } else if !source.link && !movable(ctx, source) {
                plan.conflicts.push((path, "cannot_move".into()));
            } else {
                replace.push(source.clone());
            }
        }
        plan.items.push(Item {
            id: id.clone(),
            from: chosen.path.clone(),
            real: chosen.real.clone(),
            replace,
        });
    }
    Ok(plan)
}

pub fn conflicts_json(conflicts: &[(String, String)]) -> Vec<Value> {
    conflicts
        .iter()
        .map(|(path, reason)| json!({"path": path, "reason": reason}))
        .collect()
}

pub fn json(plan: &Plan) -> Value {
    let paths = |link: Option<bool>| -> Vec<String> {
        plan.items
            .iter()
            .flat_map(|i| &i.replace)
            .filter(|s| link.is_none_or(|l| s.link == l))
            .map(|s| s.path.to_string_lossy().to_string())
            .collect()
    };
    json!({
        "copy": plan.items.iter()
            .map(|i| json!({"from": i.from.to_string_lossy(), "id": i.id}))
            .collect::<Vec<_>>(),
        "replace": paths(None),
        "trash": paths(Some(false)),
        "unlink": paths(Some(true)),
        "conflicts": conflicts_json(&plan.conflicts),
    })
}
