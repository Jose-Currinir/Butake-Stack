//! `skillsImportApply`: per skill, copy and verify, then replace each source with a link to Stack's
//! copy. A real folder is moved to the import trash (a rename, never copy + delete); anything that
//! fails rolls the skill back completely and leaves the other skills alone.
use super::plan::{conflicts_json, Item, Plan};
use super::record::{self, Saved, Stored};
use super::tree;
use crate::skills::model::{fail, Ctx, Entry, Index};
use crate::skills::{index as store_index, links, skill_file};
use anyhow::Result;
use serde_json::{json, Value};
use std::{
    fs,
    os::unix::fs::symlink,
    path::{Path, PathBuf},
};

#[cfg(test)]
thread_local! {
    /// Test hook: the id of a skill whose import fails after its first source was replaced.
    pub static FAIL_AFTER_FIRST: std::cell::RefCell<Option<String>> = const { std::cell::RefCell::new(None) };
}

fn injected(id: &str) -> bool {
    #[cfg(test)]
    {
        FAIL_AFTER_FIRST.with(|f| f.borrow().as_deref() == Some(id))
    }
    #[cfg(not(test))]
    {
        let _ = id;
        false
    }
}

/// What was done, to undo it in reverse order.
enum Done {
    Trashed { original: PathBuf, stored: PathBuf },
    Unlinked { path: PathBuf, target: PathBuf },
    Linked(PathBuf),
}

fn absent(path: &Path) -> bool {
    matches!(fs::symlink_metadata(path), Err(e) if e.kind() == std::io::ErrorKind::NotFound)
}

/// Puts back what `journal` did. `false` when something could not be restored (then nothing that
/// holds the user's files is removed).
fn undo(ctx: &Ctx, id: &str, journal: Vec<Done>) -> bool {
    let mut clean = true;
    for step in journal.into_iter().rev() {
        let done = match step {
            Done::Linked(path) => {
                !links::is_link_to(ctx, &path, id) || fs::remove_file(&path).is_ok()
            }
            Done::Trashed { original, stored } => {
                absent(&original) && fs::rename(&stored, &original).is_ok()
            }
            Done::Unlinked { path, target } => absent(&path) && symlink(&target, &path).is_ok(),
        };
        clean &= done;
    }
    clean
}

fn rollback(ctx: &Ctx, index: &mut Index, id: &str, dir: &Path, journal: Vec<Done>) {
    index.skills.remove(id);
    if undo(ctx, id, journal) {
        record::discard(dir);
        if let Ok(target) = ctx.dir(id) {
            let _ = fs::remove_dir_all(target);
        }
    }
}

/// Copies the source into a temporary folder of Stack's data folder, verifies every file, and
/// renames it to `skills/<id>`. Returns the digest of the copy.
fn copy(ctx: &Ctx, item: &Item) -> Result<String> {
    let temp_root = ctx.root.join("skills-import-tmp");
    fs::create_dir_all(&temp_root)?;
    let temp = temp_root.join(&item.id);
    if fs::symlink_metadata(&temp).is_ok() {
        fs::remove_dir_all(&temp)?;
    }
    let made = (|| {
        skill_file::copy_tree(&item.real, &temp)?;
        let (from, to) = (tree::digest(&item.real)?, tree::digest(&temp)?);
        if from.files != to.files {
            return fail("skills_import_verify");
        }
        skill_file::read_text(&temp)?;
        let target = ctx.dir(&item.id)?;
        if fs::symlink_metadata(&target).is_ok() {
            return fail("skills_exists");
        }
        fs::rename(&temp, &target)?;
        Ok(to.hash)
    })();
    if made.is_err() {
        let _ = fs::remove_dir_all(&temp);
    }
    let _ = fs::remove_dir(&temp_root);
    made
}

/// Imports one skill. `Ok` carries the sources left as they were (conflicts).
fn import_one(ctx: &Ctx, index: &mut Index, group: &str, item: &Item) -> Result<Vec<Value>> {
    if index.skills.contains_key(&item.id) {
        return fail("skills_exists");
    }
    let hash = copy(ctx, item)?;
    let (_, dir) = match record::create(ctx, &item.id) {
        Ok(made) => made,
        Err(error) => {
            let _ = fs::remove_dir_all(ctx.dir(&item.id)?);
            return Err(error);
        }
    };
    let mut saved = Saved {
        kind: "import".into(),
        id: item.id.clone(),
        created: crate::core::time::now_secs(),
        hash,
        sources: vec![],
    };
    index.skills.insert(
        item.id.clone(),
        Entry {
            group: group.to_string(),
            tags: vec![],
            enabled: true,
            agents: vec![],
        },
    );
    let (mut journal, mut conflicts) = (vec![], vec![]);
    let stack_copy = ctx.skills.join(&item.id);
    let outcome = (|| -> Result<()> {
        for (n, source) in item.replace.iter().enumerate() {
            let path = &source.path;
            let mut stored = Stored {
                agent: source.agent.clone(),
                path: path.to_string_lossy().to_string(),
                link: source.link,
                target: source
                    .target
                    .as_ref()
                    .map(|t| t.to_string_lossy().to_string()),
                stored: None,
            };
            let meta = fs::symlink_metadata(path);
            if source.link {
                let target = source.target.clone().unwrap_or_default();
                if target.as_os_str().is_empty()
                    || !meta.is_ok_and(|m| m.file_type().is_symlink())
                    || links::points_into(ctx, path)
                {
                    conflicts.push(json!({"path": stored.path, "reason": "changed"}));
                    continue;
                }
                fs::remove_file(path)?;
                journal.push(Done::Unlinked {
                    path: path.clone(),
                    target,
                });
            } else {
                let moved = dir.join("sources").join(n.to_string());
                let ready = meta.is_ok_and(|m| m.is_dir())
                    && fs::create_dir_all(dir.join("sources")).is_ok()
                    && fs::rename(path, &moved).is_ok();
                if !ready {
                    conflicts.push(json!({"path": stored.path, "reason": "cannot_move"}));
                    continue;
                }
                stored.stored = Some(format!("sources/{n}"));
                journal.push(Done::Trashed {
                    original: path.clone(),
                    stored: moved,
                });
            }
            symlink(&stack_copy, path)?;
            journal.push(Done::Linked(path.clone()));
            index
                .skills
                .get_mut(&item.id)
                .expect("inserted")
                .agents
                .push(source.agent.clone());
            saved.sources.push(stored);
            // Written after each source: whatever happens next, the entry names what is in there.
            record::write(&dir, &saved)?;
            if n == 0 && injected(&item.id) {
                return fail("skills_import_failed");
            }
        }
        store_index::save(ctx, index)
    })();
    if let Err(error) = outcome {
        rollback(ctx, index, &item.id, &dir, journal);
        return Err(error);
    }
    if saved.sources.is_empty() {
        record::discard(&dir);
    }
    Ok(conflicts)
}

/// Applies the plan; the response is `{imported, conflicts}`.
pub fn run(ctx: &Ctx, index: &mut Index, plan: &Plan) -> Result<Value> {
    let _ = fs::remove_dir_all(ctx.root.join("skills-import-tmp"));
    let mut conflicts = conflicts_json(&plan.conflicts);
    let mut imported = vec![];
    for item in &plan.items {
        match import_one(ctx, index, &plan.group, item) {
            Ok(left) => {
                conflicts.extend(left);
                if let Ok(skill) = crate::skills::skill_json(ctx, index, &item.id) {
                    imported.push(skill);
                }
            }
            Err(error) => {
                let code = error.to_string();
                let reason = if code.starts_with("skills_") {
                    code
                } else {
                    "failed".into()
                };
                conflicts.push(json!({"path": item.from.to_string_lossy(), "reason": reason}));
            }
        }
    }
    Ok(json!({"imported": imported, "conflicts": conflicts}))
}
