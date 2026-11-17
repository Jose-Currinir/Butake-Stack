//! Undo of one import and «Vaciar papelera de importación». Undo puts the original folders and
//! links back and sends Stack's copy to the skills trash (30 days), only while that copy is still
//! the one imported. If the copy is gone (deleted, renamed, data removed) the originals come back
//! anyway and nothing goes to the trash; a copy that exists and changed blocks the undo. Emptying is the only permanent removal of the whole import.
use super::record::{self, Saved};
use super::{plan::conflicts_json, tree};
use crate::skills::model::{fail, Ctx, Index};
use crate::skills::{index as store_index, links, skill_file, trash};
use anyhow::Result;
use serde_json::{json, Value};
use std::{
    fs,
    os::unix::fs::symlink,
    path::{Path, PathBuf},
};

pub struct Undo {
    dir: PathBuf,
    saved: Saved,
    /// `(from in the trash, original path)`.
    restore: Vec<(PathBuf, PathBuf)>,
    /// `(original path, where the foreign link pointed)`.
    relink: Vec<(PathBuf, PathBuf)>,
    /// Links to Stack's copy that go away.
    remove: Vec<PathBuf>,
    skill: PathBuf,
    /// Stack's copy still exists and is the imported one: it goes to the skills trash. When it is
    /// gone (deleted, renamed, «Eliminar datos») there is nothing to send.
    trash_copy: bool,
    conflicts: Vec<(String, String)>,
}

fn free_for(ctx: &Ctx, id: &str, path: &Path) -> bool {
    links::is_link_to(ctx, path, id) || links::is_absent(path)
}

/// Where an import may put an original back: directly inside the folder of an AI Stack knows
/// (the trash record is a file on disk and is not trusted for the destination).
fn inside_agent_folder(ctx: &Ctx, index: &Index, path: &Path) -> bool {
    let Some((parent, name)) = path.parent().zip(path.file_name()) else {
        return false;
    };
    let Ok(parent) = parent.canonicalize() else {
        return false;
    };
    name != ".."
        && crate::skills::agents::all(index).iter().any(|agent| {
            crate::skills::agents::folder(ctx, agent)
                .ok()
                .flatten()
                .is_some_and(|folder| folder == parent)
        })
}

/// `sources/<number>`: the only shape the import writes into its trash entry.
fn valid_stored(stored: &str) -> bool {
    stored
        .strip_prefix("sources/")
        .is_some_and(|n| !n.is_empty() && n.len() <= 6 && n.bytes().all(|c| c.is_ascii_digit()))
}

pub fn plan(ctx: &Ctx, index: &Index, trash_id: &str) -> Result<Undo> {
    let (dir, saved) = record::read(ctx, trash_id)?;
    let id = saved.id.clone();
    let skill = ctx.dir(&id)?;
    let mut undo = Undo {
        dir: dir.clone(),
        saved: saved.clone(),
        restore: vec![],
        relink: vec![],
        remove: links::existing(ctx, index, &id),
        skill: skill.clone(),
        trash_copy: false,
        conflicts: vec![],
    };
    let listed = index.skills.contains_key(&id);
    let gone = !listed && fs::symlink_metadata(&skill).is_err();
    let unchanged = listed
        && skill_file::real_dir(&skill)
        && tree::digest(&skill).is_ok_and(|t| t.hash == saved.hash);
    undo.trash_copy = unchanged;
    if !unchanged && !gone {
        undo.conflicts
            .push((skill.to_string_lossy().to_string(), "changed".into()));
    }
    for source in &saved.sources {
        let original = PathBuf::from(&source.path);
        if !original.is_absolute()
            || !inside_agent_folder(ctx, index, &original)
            || source.stored.as_deref().is_some_and(|s| !valid_stored(s))
        {
            undo.conflicts.push((source.path.clone(), "changed".into()));
            continue;
        }
        if !free_for(ctx, &id, &original) {
            undo.conflicts.push((source.path.clone(), "exists".into()));
            continue;
        }
        match (&source.stored, &source.target) {
            (Some(stored), _) => {
                let from = dir.join(stored);
                if skill_file::real_dir(&from) {
                    undo.restore.push((from, original));
                } else {
                    undo.conflicts
                        .push((from.to_string_lossy().to_string(), "missing".into()));
                }
            }
            (None, Some(target)) => undo.relink.push((original, PathBuf::from(target))),
            _ => undo.conflicts.push((source.path.clone(), "missing".into())),
        }
    }
    Ok(undo)
}

fn strings(paths: &[PathBuf]) -> Vec<String> {
    paths
        .iter()
        .map(|p| p.to_string_lossy().to_string())
        .collect()
}

pub fn plan_json(undo: &Undo) -> Value {
    json!({
        "restore": undo.restore.iter()
            .map(|(from, to)| json!({"from": from.to_string_lossy(), "to": to.to_string_lossy()}))
            .collect::<Vec<_>>(),
        "relink": undo.relink.iter()
            .map(|(path, target)| json!({"path": path.to_string_lossy(), "target": target.to_string_lossy()}))
            .collect::<Vec<_>>(),
        "remove": strings(&undo.remove),
        "trash": if undo.trash_copy { vec![undo.skill.to_string_lossy()] } else { vec![] },
        "conflicts": conflicts_json(&undo.conflicts),
    })
}

/// Makes the changes of `plan_json`. With a conflict nothing is done.
pub fn apply(ctx: &Ctx, index: &mut Index, undo: &Undo) -> Result<Value> {
    if !undo.conflicts.is_empty() {
        return Ok(json!({"restored": [], "conflicts": conflicts_json(&undo.conflicts)}));
    }
    let id = undo.saved.id.clone();
    let mut removed = vec![];
    for path in &undo.remove {
        if links::is_link_to(ctx, path, &id) && fs::remove_file(path).is_ok() {
            removed.push(path.clone());
        }
    }
    let mut moved: Vec<&(PathBuf, PathBuf)> = vec![];
    let result = (|| -> Result<()> {
        for pair in &undo.restore {
            fs::rename(&pair.0, &pair.1)?;
            moved.push(pair);
        }
        if !undo.trash_copy {
            return Ok(());
        }
        let entry = index
            .skills
            .get(&id)
            .cloned()
            .ok_or_else(|| anyhow::anyhow!("skills_not_found"))?;
        trash::put(ctx, &id, &entry)?;
        index.skills.remove(&id);
        store_index::save(ctx, index)
    })();
    if let Err(error) = result {
        for pair in moved.iter().rev() {
            let _ = fs::rename(&pair.1, &pair.0);
        }
        for path in &removed {
            let _ = symlink(&undo.skill, path);
        }
        return Err(error);
    }
    let mut conflicts = vec![];
    for (path, target) in &undo.relink {
        if symlink(target, path).is_err() {
            // The target is said too: the record is discarded below, and it is all that is left.
            conflicts.push((
                format!("{} → {}", path.to_string_lossy(), target.to_string_lossy()),
                "exists".to_string(),
            ));
        }
    }
    record::discard(&undo.dir);
    Ok(json!({
        "restored": undo.restore.iter().map(|(_, to)| to.to_string_lossy()).collect::<Vec<_>>(),
        "conflicts": conflicts_json(&conflicts),
    }))
}

/// `skillsImportTrashEmpty`: `{trashIds}`; `plan: true` lists the folders, `confirmed` removes
/// exactly those and nothing else.
pub fn empty(ctx: &Ctx, request: &Value, confirmed: bool) -> Result<Value> {
    let Some(list) = request["trashIds"].as_array() else {
        return fail("invalid_request");
    };
    if list.is_empty() || list.len() > 500 {
        return fail("invalid_request");
    }
    let mut found: Vec<(String, PathBuf)> = vec![];
    for item in list {
        let id = item.as_str().unwrap_or("");
        let (dir, _) = record::read(ctx, id)?;
        if !found.iter().any(|(known, _)| known == id) {
            found.push((id.to_string(), dir));
        }
    }
    if request["plan"] == true {
        return Ok(
            json!({"delete": found.iter().map(|(_, d)| d.to_string_lossy()).collect::<Vec<_>>()}),
        );
    }
    if !confirmed {
        return fail("confirmation_required");
    }
    let mut removed = vec![];
    for (id, dir) in &found {
        if fs::remove_dir_all(dir).is_ok() {
            removed.push(id.clone());
        }
    }
    Ok(json!({"removed": removed}))
}
