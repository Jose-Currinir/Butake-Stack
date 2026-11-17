//! The skills tool: one real copy of each skill in Stack's data folder, a symlink to it in the
//! folder of each AI that uses it (see docs/herramientas/skills.md).
//!
//! What it never does: copy a skill into an AI folder, follow a symlink while reading a skill,
//! remove anything that does not resolve into Stack's skills folder, create links outside a
//! validated folder under the home, or log the text of a skill (only `skillsRead` and
//! `skillsExport` return it).

mod agents;
mod export;
mod health;
mod import;
mod index;
mod links;
mod model;
mod skill_file;
mod templates;
mod trash;

#[cfg(test)]
mod tests;

use crate::core::{store::Store, validate};
use anyhow::Result;
use model::{fail, valid_id, Ctx, Entry, Group, Index};
use serde_json::{json, Value};
use std::{fs, path::Path};

/// Requests of the skills tool (`skills*`). The caller checked that the tool is on.
pub fn dispatch(store: &Store, method: &str, request: &Value) -> Result<Value> {
    let home = Store::home().ok_or_else(|| anyhow::anyhow!("home_unavailable"))?;
    dispatch_in(store, &home, method, request)
}

/// Removes every link into Stack's skills folder and then the skills themselves (what «Borrar los
/// datos» of the tool does). Links of other origin are never touched, nor is the import trash.
pub fn delete_all(store: &Store) -> Result<()> {
    if let Some(home) = Store::home() {
        if let Ok(ctx) = Ctx::new(store, &home) {
            if let Ok(index) = index::load(&ctx) {
                for id in index.skills.keys() {
                    links::remove_all(&ctx, &index, id);
                }
            }
        }
    }
    for name in ["skills", "skills-trash"] {
        let dir = store.directory(name)?;
        for item in fs::read_dir(&dir)?.flatten() {
            let path = item.path();
            // The import trash holds the user's original folders: only «Vaciar papelera» removes it.
            if name == "skills-trash" && import::is_import(&path) {
                continue;
            }
            if item.file_type()?.is_dir() {
                fs::remove_dir_all(&path)?;
            } else {
                fs::remove_file(&path)?;
            }
        }
    }
    Ok(())
}

pub fn has_data(store: &Store) -> bool {
    store
        .directory("skills")
        .ok()
        .and_then(|d| fs::read_dir(d).ok())
        .is_some_and(|mut d| d.next().is_some())
}

/// A request that only asks for a plan (`plan: true`) never writes, so it takes no lock.
fn mutates(method: &str, request: &Value) -> bool {
    if method.starts_with("skillsImport") {
        return import::mutates(method, request);
    }
    if request["plan"] == true && is_planned(method) {
        return false;
    }
    !matches!(
        method,
        "skillsList" | "skillsRead" | "skillsLinkPlan" | "skillsHealth" | "skillsExport"
    )
}

/// Methods that change an AI folder: each answers `plan: true` with `{create, remove, conflicts}`
/// (the shape of `skillsLinkPlan`) and applies only with `confirmed`.
fn is_planned(method: &str) -> bool {
    matches!(
        method,
        "skillsRename" | "skillsDelete" | "skillsAgentRemove" | "skillsRestore"
    )
}

pub(crate) fn dispatch_in(
    store: &Store,
    home: &Path,
    method: &str,
    request: &Value,
) -> Result<Value> {
    let ctx = Ctx::new(store, home)?;
    let _lock = if mutates(method, request) {
        Some(store.mutation_lock()?)
    } else {
        None
    };
    let mut index = index::load(&ctx)?;
    let text = |key: &str| request[key].as_str().unwrap_or("").to_string();
    let id = text("id");
    let confirmed = request["confirmed"] == true;
    if request["plan"] == true && is_planned(method) {
        return plan_of(&ctx, &index, method, request);
    }
    match method {
        "skillsList" => {
            trash::purge(&ctx);
            Ok(list(&ctx, &index))
        }
        "skillsRead" => {
            ensure_skill(&index, &id)?;
            Ok(json!({"id": id, "text": skill_file::read_text(&ctx.dir(&id)?)?}))
        }
        "skillsCreate" => create(&ctx, &mut index, request),
        "skillsSave" => {
            ensure_skill(&index, &id)?;
            let body = request["text"].as_str().unwrap_or("");
            skill_file::write_text(&ctx.dir(&id)?, body)?;
            skill_json(&ctx, &index, &id)
        }
        "skillsUpdate" => update(&ctx, &mut index, request),
        "skillsDuplicate" => duplicate(&ctx, &mut index, &id, &text("newId")),
        "skillsRename" => {
            require(confirmed)?;
            rename(&ctx, &mut index, &id, &text("newId"))
        }
        "skillsDelete" => {
            require(confirmed)?;
            delete(&ctx, &mut index, &id)
        }
        "skillsRestore" => {
            require(confirmed)?;
            let restored = trash::restore(&ctx, &mut index, &text("trashId"))?;
            index::save(&ctx, &index)?;
            skill_json(&ctx, &index, &restored)
        }
        m if m.starts_with("skillsImport") => import::dispatch(&ctx, &mut index, m, request),
        "skillsGroupSave" => group_save(&ctx, &mut index, request),
        "skillsGroupDelete" => group_delete(&ctx, &mut index, &id, &text("moveTo")),
        "skillsAgentSave" => {
            agents::save(&ctx, &mut index, &id, &text("name"), &text("folder"))?;
            index::save(&ctx, &index)?;
            Ok(json!(agents::list_json(&ctx, &index)))
        }
        "skillsAgentRemove" => {
            require(confirmed)?;
            agent_remove(&ctx, &mut index, &id)
        }
        "skillsLinkPlan" => {
            let parsed = links::parse(request, &index)?;
            Ok(links::plan_json(&links::plan(&ctx, &index, &parsed)?))
        }
        "skillsLinkApply" => {
            require(confirmed)?;
            let parsed = links::parse(request, &index)?;
            let plan = links::plan(&ctx, &index, &parsed)?;
            let result = links::apply(&ctx, &mut index, &parsed, &plan)?;
            index::save(&ctx, &index)?;
            Ok(result)
        }
        "skillsHealth" => Ok(json!(health::check(&ctx, &index))),
        "skillsExport" => {
            if request["format"].as_str().unwrap_or("markdown") != "markdown" {
                return fail("invalid_request");
            }
            let ids: Vec<String> = match request["ids"].as_array() {
                Some(list) => list
                    .iter()
                    .filter_map(|v| v.as_str().map(String::from))
                    .collect(),
                None => vec![id],
            };
            Ok(json!({"text": export::markdown(&ctx, &index, &ids)?}))
        }
        _ => anyhow::bail!("unknown_method"),
    }
}

/// What `skillsRename`, `skillsDelete`, `skillsAgentRemove` and `skillsRestore` would do to the
/// AI folders, without doing it: `{create, remove, conflicts}` as `skillsLinkPlan` answers. The
/// apply (same request with `confirmed` instead of `plan`) makes exactly these changes.
fn plan_of(ctx: &Ctx, index: &Index, method: &str, request: &Value) -> Result<Value> {
    let text = |key: &str| request[key].as_str().unwrap_or("");
    let (create, remove, conflicts) = match method {
        "skillsRename" => {
            let id = text("id");
            ensure_skill(index, id)?;
            free(ctx, index, text("newId"))?;
            let entry = &index.skills[id];
            let (create, conflicts) = if entry.enabled {
                links::creatable(ctx, index, text("newId"), &entry.agents)
            } else {
                (vec![], vec![])
            };
            (create, links::existing(ctx, index, id), conflicts)
        }
        "skillsDelete" => {
            let id = text("id");
            ensure_skill(index, id)?;
            (vec![], links::existing(ctx, index, id), vec![])
        }
        "skillsAgentRemove" => (vec![], agent_links(ctx, index, text("id"))?, vec![]),
        _ => {
            let (id, entry) = trash::peek(ctx, index, text("trashId"))?;
            let (create, conflicts) = if entry.enabled {
                links::creatable(ctx, index, &id, &entry.agents)
            } else {
                (vec![], vec![])
            };
            (create, vec![], conflicts)
        }
    };
    Ok(links::plan_value(&create, &remove, &conflicts))
}

/// The links of every skill in the folder of custom assistant `id` that `skillsAgentRemove` removes.
fn agent_links(ctx: &Ctx, index: &Index, id: &str) -> Result<Vec<std::path::PathBuf>> {
    if agents::is_builtin(id) {
        return fail("skills_agent_builtin");
    }
    let Some(agent) = agents::find(index, id) else {
        return fail("skills_not_found");
    };
    let mut found = vec![];
    if let Ok(Some(folder)) = agents::folder(ctx, &agent) {
        for skill in index.skills.keys() {
            let path = folder.join(skill);
            if links::is_link_to(ctx, &path, skill) {
                found.push(path);
            }
        }
    }
    Ok(found)
}

fn require(confirmed: bool) -> Result<()> {
    if !confirmed {
        return fail("confirmation_required");
    }
    Ok(())
}

fn ensure_skill(index: &Index, id: &str) -> Result<()> {
    if !valid_id(id) {
        return fail("skills_invalid_id");
    }
    if !index.skills.contains_key(id) {
        return fail("skills_not_found");
    }
    Ok(())
}

fn skill_json(ctx: &Ctx, index: &Index, id: &str) -> Result<Value> {
    ensure_skill(index, id)?;
    let entry = &index.skills[id];
    let dir = ctx.dir(id)?;
    if !skill_file::real_dir(&dir) {
        return fail("skills_not_found");
    }
    let meta = skill_file::read_text(&dir)
        .map(|t| skill_file::parse(&t))
        .unwrap_or_default();
    Ok(json!({
        "id": id,
        "name": if meta.name.is_empty() { id.to_string() } else { meta.name },
        "description": meta.description,
        "group": entry.group, "tags": entry.tags, "enabled": entry.enabled, "agents": entry.agents,
        "files": skill_file::files(&dir),
        "modified": skill_file::modified(&dir),
    }))
}

fn list(ctx: &Ctx, index: &Index) -> Value {
    let skills: Vec<Value> = index
        .skills
        .keys()
        .filter_map(|id| skill_json(ctx, index, id).ok())
        .collect();
    let mut tags: Vec<&String> = index.skills.values().flat_map(|e| &e.tags).collect();
    tags.sort();
    tags.dedup();
    json!({"groups": index.groups, "skills": skills, "agents": agents::list_json(ctx, index), "tags": tags})
}

fn clean_tags(request: &Value) -> Result<Vec<String>> {
    let Some(list) = request["tags"].as_array() else {
        return fail("invalid_request");
    };
    let mut tags: Vec<String> = vec![];
    for tag in list {
        let tag = tag.as_str().unwrap_or("").trim().to_lowercase();
        if tag.is_empty() || tag.contains(',') || !validate::printable(&tag, 32) {
            return fail("invalid_name");
        }
        if !tags.contains(&tag) {
            tags.push(tag);
        }
    }
    if tags.len() > 20 {
        return fail("invalid_name");
    }
    Ok(tags)
}

fn create(ctx: &Ctx, index: &mut Index, request: &Value) -> Result<Value> {
    let id = request["id"].as_str().unwrap_or("");
    let group = request["group"].as_str().unwrap_or("");
    let name = request["name"].as_str().unwrap_or("").trim();
    let description = request["description"].as_str().unwrap_or("").trim();
    let dir = ctx.dir(id)?;
    if index.skills.contains_key(id) || fs::symlink_metadata(&dir).is_ok() {
        return fail("skills_exists");
    }
    if !index.has_group(group) {
        return fail("skills_invalid_group");
    }
    if !validate::printable(name, 100) || !validate::printable(description, 1024) {
        return fail("invalid_name");
    }
    let name = if name.is_empty() { id } else { name };
    let body = templates::render(
        request["template"].as_str().unwrap_or("blank"),
        name,
        description,
    )?;
    fs::create_dir(&dir)?;
    let made = (|| {
        skill_file::write_text(&dir, &body)?;
        index.skills.insert(
            id.to_string(),
            Entry {
                group: group.to_string(),
                tags: vec![],
                enabled: true,
                agents: vec![],
            },
        );
        index::save(ctx, index)
    })();
    if let Err(error) = made {
        index.skills.remove(id);
        let _ = fs::remove_dir_all(&dir);
        return Err(error);
    }
    skill_json(ctx, index, id)
}

fn update(ctx: &Ctx, index: &mut Index, request: &Value) -> Result<Value> {
    let id = request["id"].as_str().unwrap_or("");
    ensure_skill(index, id)?;
    if let Some(group) = request["group"].as_str() {
        if !index.has_group(group) {
            return fail("skills_invalid_group");
        }
    }
    let tags = if request.get("tags").is_some_and(|t| !t.is_null()) {
        Some(clean_tags(request)?)
    } else {
        None
    };
    let entry = index.skills.get_mut(id).expect("checked");
    if let Some(group) = request["group"].as_str() {
        entry.group = group.to_string();
    }
    if let Some(tags) = tags {
        entry.tags = tags;
    }
    index::save(ctx, index)?;
    skill_json(ctx, index, id)
}

fn free(ctx: &Ctx, index: &Index, new_id: &str) -> Result<()> {
    let dir = ctx.dir(new_id)?;
    if index.skills.contains_key(new_id) || fs::symlink_metadata(&dir).is_ok() {
        return fail("skills_exists");
    }
    Ok(())
}

fn duplicate(ctx: &Ctx, index: &mut Index, id: &str, new_id: &str) -> Result<Value> {
    ensure_skill(index, id)?;
    free(ctx, index, new_id)?;
    let from = ctx.dir(id)?;
    if !skill_file::real_dir(&from) {
        return fail("skills_not_found");
    }
    let to = ctx.dir(new_id)?;
    let copied = skill_file::copy_tree(&from, &to).and_then(|skipped| {
        let text = skill_file::read_text(&to)?;
        skill_file::write_text(&to, &skill_file::rename_in_text(&text, id, new_id))?;
        Ok(skipped)
    });
    let skipped = match copied {
        Ok(skipped) => skipped,
        Err(error) => {
            let _ = fs::remove_dir_all(&to);
            return Err(error);
        }
    };
    let mut entry = index.skills[id].clone();
    entry.agents.clear();
    entry.enabled = true;
    index.skills.insert(new_id.to_string(), entry);
    index::save(ctx, index)?;
    let mut skill = skill_json(ctx, index, new_id)?;
    // Links and special files are never copied: the answer says which ones were left out.
    if !skipped.is_empty() {
        skill["skipped"] = json!(skipped);
    }
    Ok(skill)
}

fn rename(ctx: &Ctx, index: &mut Index, id: &str, new_id: &str) -> Result<Value> {
    ensure_skill(index, id)?;
    free(ctx, index, new_id)?;
    fs::rename(ctx.dir(id)?, ctx.dir(new_id)?)?;
    links::remove_all(ctx, index, id);
    let entry = index.skills.remove(id).expect("checked");
    index.skills.insert(new_id.to_string(), entry.clone());
    let dir = ctx.dir(new_id)?;
    if let Ok(text) = skill_file::read_text(&dir) {
        let _ = skill_file::write_text(&dir, &skill_file::rename_in_text(&text, id, new_id));
    }
    // Names already taken in an AI folder are skipped by `create_for`; they are answered too.
    let mut taken = vec![];
    if entry.enabled {
        taken = links::creatable(ctx, index, new_id, &entry.agents).1;
        links::create_for(ctx, index, new_id, &entry.agents);
    }
    index::save(ctx, index)?;
    let conflicts: Vec<Value> = taken
        .iter()
        .map(|p| json!({"path": p.to_string_lossy(), "reason": "exists"}))
        .collect();
    Ok(json!({"skill": skill_json(ctx, index, new_id)?, "conflicts": conflicts}))
}

fn delete(ctx: &Ctx, index: &mut Index, id: &str) -> Result<Value> {
    ensure_skill(index, id)?;
    let entry = index.skills[id].clone();
    let trash_id = if skill_file::real_dir(&ctx.dir(id)?) {
        trash::put(ctx, id, &entry)?
    } else {
        return fail("skills_not_found");
    };
    links::remove_all(ctx, index, id);
    index.skills.remove(id);
    index::save(ctx, index)?;
    Ok(json!({"trashId": trash_id}))
}

fn group_save(ctx: &Ctx, index: &mut Index, request: &Value) -> Result<Value> {
    let Some(list) = request["groups"].as_array() else {
        return fail("invalid_request");
    };
    let mut groups: Vec<Group> = vec![];
    for item in list {
        let group = Group {
            id: item["id"].as_str().unwrap_or("").to_string(),
            name: item["name"].as_str().unwrap_or("").trim().to_string(),
            order: item["order"].as_i64().unwrap_or(groups.len() as i64),
        };
        if !valid_id(&group.id)
            || groups.iter().any(|g| g.id == group.id)
            || group.name.is_empty()
            || !validate::printable(&group.name, 60)
        {
            return fail("skills_invalid_group");
        }
        groups.push(group);
    }
    if groups.is_empty()
        || groups.len() > 100
        || index
            .skills
            .values()
            .any(|e| !groups.iter().any(|g| g.id == e.group))
    {
        return fail("skills_invalid_group");
    }
    groups.sort_by(|a, b| (a.order, &a.id).cmp(&(b.order, &b.id)));
    index.groups = groups;
    index::save(ctx, index)?;
    Ok(json!(index.groups))
}

fn group_delete(ctx: &Ctx, index: &mut Index, id: &str, move_to: &str) -> Result<Value> {
    if !index.has_group(id) {
        return fail("skills_invalid_group");
    }
    let used = index.skills.values().any(|e| e.group == id);
    if used && move_to.is_empty() {
        return fail("skills_group_not_empty");
    }
    if used && (move_to == id || !index.has_group(move_to)) {
        return fail("skills_invalid_group");
    }
    if index.groups.len() == 1 {
        return fail("skills_invalid_group");
    }
    for entry in index.skills.values_mut().filter(|e| e.group == id) {
        entry.group = move_to.to_string();
    }
    index.groups.retain(|g| g.id != id);
    index::save(ctx, index)?;
    Ok(json!(index.groups))
}

fn agent_remove(ctx: &Ctx, index: &mut Index, id: &str) -> Result<Value> {
    for path in agent_links(ctx, index, id)? {
        let _ = fs::remove_file(&path);
    }
    for entry in index.skills.values_mut() {
        entry.agents.retain(|a| a != id);
    }
    index.agents.remove(id);
    index::save(ctx, index)?;
    Ok(json!(agents::list_json(ctx, index)))
}
