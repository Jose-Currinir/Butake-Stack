//! Import of existing skills: scan, plan, apply, undo and the import trash, all in a temporary home.
use super::*;
use std::{
    collections::BTreeMap,
    fs,
    os::unix::fs::symlink,
    path::{Path, PathBuf},
};

pub(super) const SKILL: &str = "---\nname: Hace algo\ndescription: Una prueba\n---\ncuerpo\n";

/// Every entry under `root`: files by content, links by target, folders by name.
pub(super) fn snap(root: &Path) -> BTreeMap<String, String> {
    fn go(base: &Path, dir: &Path, out: &mut BTreeMap<String, String>) {
        let Ok(read) = fs::read_dir(dir) else { return };
        for item in read.flatten() {
            let path = item.path();
            let rel = path
                .strip_prefix(base)
                .unwrap()
                .to_string_lossy()
                .to_string();
            let meta = fs::symlink_metadata(&path).unwrap();
            if meta.file_type().is_symlink() {
                out.insert(
                    rel,
                    format!("->{}", fs::read_link(&path).unwrap().display()),
                );
            } else if meta.is_dir() {
                out.insert(rel, "dir".into());
                go(base, &path, out);
            } else {
                let bytes = fs::read(&path).unwrap();
                out.insert(rel, String::from_utf8_lossy(&bytes).to_string());
            }
        }
    }
    let mut out = BTreeMap::new();
    go(root, root, &mut out);
    out
}

/// A real skill folder at `home/<folder>/<name>` with SKILL.md and the given support files.
pub(super) fn folder(env: &Env, folder: &str, name: &str, files: &[(&str, &str)]) -> PathBuf {
    let dir = env.home.join(folder).join(name);
    fs::create_dir_all(&dir).unwrap();
    fs::write(dir.join("SKILL.md"), SKILL).unwrap();
    for (rel, text) in files {
        let path = dir.join(rel);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(path, text).unwrap();
    }
    dir
}

pub(super) fn link(env: &Env, folder: &str, name: &str, target: &Path) -> PathBuf {
    let dir = env.home.join(folder);
    fs::create_dir_all(&dir).unwrap();
    let path = dir.join(name);
    symlink(target, &path).unwrap();
    path
}

/// A skill folder outside every AI folder, to link to.
pub(super) fn elsewhere(env: &Env, name: &str) -> PathBuf {
    let dir = env.home.join("elsewhere").join(name);
    fs::create_dir_all(&dir).unwrap();
    fs::write(dir.join("SKILL.md"), SKILL).unwrap();
    fs::write(dir.join("n.md"), "n").unwrap();
    dir
}

pub(super) fn find<'a>(scan: &'a Value, id: &str) -> &'a Value {
    scan.as_array()
        .unwrap()
        .iter()
        .find(|c| c["id"] == id)
        .unwrap()
}

pub(super) fn paths(value: &Value) -> Vec<String> {
    let mut list: Vec<String> = value
        .as_array()
        .unwrap()
        .iter()
        .map(|v| v.as_str().unwrap().to_string())
        .collect();
    list.sort();
    list
}

pub(super) fn text(path: &Path) -> String {
    path.to_string_lossy().to_string()
}

pub(super) fn trash_dir(env: &Env) -> PathBuf {
    env.store.root().join("skills-trash")
}

pub(super) fn apply(env: &Env, ids: &[&str]) -> Value {
    env.ok(
        "skillsImportApply",
        json!({"ids": ids, "group": "personal", "confirmed": true}),
    )
}

pub(super) fn first_trash_id(env: &Env) -> String {
    let list = env.ok("skillsImportTrashList", json!({}));
    list[0]["trashId"].as_str().unwrap().to_string()
}

#[test]
fn scan_writes_nothing() {
    let env = env();
    env.create("mine");
    folder(&env, ".claude/skills", "a", &[("x.md", "x")]);
    let real = folder(&env, ".agents/skills", "b", &[]);
    link(&env, ".gemini/skills", "b", &real);
    env.ok("skillsList", json!({}));
    let before = snap(env.temp.path());
    let found = env.ok("skillsImportScan", json!({}));
    assert_eq!(found.as_array().unwrap().len(), 2);
    let ask = json!({"ids": ["a", "b"], "group": "personal"});
    env.ok("skillsImportPlan", ask);
    env.ok("skillsImportTrashList", json!({}));
    assert_eq!(snap(env.temp.path()), before);
}

#[test]
fn a_real_folder_and_two_links_to_it_are_one_candidate_with_three_sources() {
    let env = env();
    let real = folder(&env, ".claude/skills", "a", &[("notes.md", "n")]);
    link(&env, ".agents/skills", "a", &real);
    link(&env, ".gemini/skills", "a", &real);
    // Export-only folders and Stack's own links are never candidates.
    folder(&env, ".kiro/skills", "k", &[]);
    env.create("own");
    env.link("own", "claude");
    let found = env.ok("skillsImportScan", json!({}));
    assert_eq!(found.as_array().unwrap().len(), 1);
    let item = find(&found, "a");
    assert_eq!(item["identical"], true);
    assert_eq!(item["valid"], true);
    assert_eq!(item["hidden"], false);
    assert_eq!(item["name"], "Hace algo");
    assert_eq!(item["description"], "Una prueba");
    let sources = item["sources"].as_array().unwrap();
    assert_eq!(sources.len(), 3);
    let kinds: Vec<(&str, &str)> = sources
        .iter()
        .map(|s| (s["agent"].as_str().unwrap(), s["kind"].as_str().unwrap()))
        .collect();
    assert!(kinds.contains(&("claude", "folder")));
    assert!(kinds.contains(&("codex", "link")));
    assert!(kinds.contains(&("gemini", "link")));
}

#[test]
fn different_copies_need_a_choice_and_the_others_stay() {
    let env = env();
    let first = folder(&env, ".claude/skills", "a", &[("v.md", "uno")]);
    let second = folder(&env, ".agents/skills", "a", &[("v.md", "dos")]);
    let found = env.ok("skillsImportScan", json!({}));
    assert_eq!(find(&found, "a")["identical"], false);
    let ask = json!({"ids": ["a"], "group": "personal"});
    assert_eq!(
        env.code("skillsImportPlan", ask.clone()),
        "skills_import_choice_required"
    );
    let mut run = ask;
    run["confirmed"] = json!(true);
    assert_eq!(
        env.code("skillsImportApply", run),
        "skills_import_choice_required"
    );
    let bad =
        json!({"ids": ["a"], "group": "personal", "choices": [{"id": "a", "from": "/nowhere"}]});
    assert_eq!(
        env.code("skillsImportPlan", bad),
        "skills_import_choice_invalid"
    );
    let chosen =
        json!({"ids": ["a"], "group": "personal", "choices": [{"id": "a", "from": text(&second)}]});
    let plan = env.ok("skillsImportPlan", chosen.clone());
    assert_eq!(plan["copy"], json!([{"from": text(&second), "id": "a"}]));
    assert_eq!(plan["trash"], json!([text(&second)]));
    assert_eq!(
        plan["conflicts"],
        json!([{"path": text(&first), "reason": "not_chosen"}])
    );
    let mut run = chosen;
    run["confirmed"] = json!(true);
    let done = env.ok("skillsImportApply", run);
    assert_eq!(done["imported"][0]["id"], "a");
    let copied = fs::read_to_string(env.skills_dir().join("a/v.md")).unwrap();
    assert_eq!(copied, "dos");
    assert_eq!(fs::read_to_string(first.join("v.md")).unwrap(), "uno");
    assert!(fs::symlink_metadata(&first).unwrap().is_dir());
}

#[test]
fn invalid_names_and_names_in_stack_are_not_valid() {
    let env = env();
    env.create("taken");
    folder(&env, ".claude/skills", "Mi Skill", &[]);
    folder(&env, ".claude/skills", "taken", &[]);
    folder(&env, ".claude/skills", "fine", &[]);
    let found = env.ok("skillsImportScan", json!({}));
    assert_eq!(find(&found, "Mi Skill")["valid"], false);
    assert_eq!(find(&found, "Mi Skill")["reason"], "skills_invalid_id");
    assert_eq!(find(&found, "taken")["valid"], false);
    assert_eq!(find(&found, "taken")["reason"], "skills_exists");
    assert_eq!(find(&found, "fine")["valid"], true);
    assert!(find(&found, "fine").get("reason").is_none());
    let done = apply(&env, &["Mi Skill", "taken", "fine"]);
    assert_eq!(done["imported"].as_array().unwrap().len(), 1);
    let reasons: Vec<&str> = done["conflicts"]
        .as_array()
        .unwrap()
        .iter()
        .map(|c| c["reason"].as_str().unwrap())
        .collect();
    assert!(reasons.contains(&"skills_invalid_id") && reasons.contains(&"skills_exists"));
}

#[test]
fn hidden_entries_are_listed_and_only_planned_when_named() {
    let env = env();
    let hidden = folder(&env, ".agents/skills", ".system", &[]);
    folder(&env, ".agents/skills", "plain", &[]);
    let found = env.ok("skillsImportScan", json!({}));
    assert_eq!(find(&found, ".system")["hidden"], true);
    assert_eq!(find(&found, "plain")["hidden"], false);
    let ask = json!({"ids": ["plain"], "group": "personal"});
    let plan = env.ok("skillsImportPlan", ask);
    assert_eq!(plan["copy"].as_array().unwrap().len(), 1);
    assert_eq!(plan["conflicts"], json!([]));
    // Named explicitly, its name still breaks the id rule: a conflict, left untouched.
    let ask = json!({"ids": [".system"], "group": "personal"});
    let named = env.ok("skillsImportPlan", ask);
    assert_eq!(named["copy"], json!([]));
    assert_eq!(
        named["conflicts"],
        json!([{"path": text(&hidden), "reason": "skills_invalid_id"}])
    );
    apply(&env, &[".system"]);
    assert!(fs::symlink_metadata(&hidden).unwrap().is_dir());
}

#[test]
fn the_plan_lists_exactly_what_the_apply_does() {
    let env = env();
    let real = folder(&env, ".claude/skills", "a", &[("n.md", "n")]);
    let twin = folder(&env, ".gemini/skills", "a", &[("n.md", "n")]);
    let outside = elsewhere(&env, "a");
    let foreign = link(&env, ".agents/skills", "a", &outside);
    let request = json!({"ids": ["a"], "group": "trabajo"});
    let plan = env.ok("skillsImportPlan", request.clone());
    assert_eq!(plan["copy"], json!([{"from": text(&real), "id": "a"}]));
    let mut folders = vec![text(&twin), text(&real)];
    folders.sort();
    assert_eq!(paths(&plan["trash"]), folders);
    assert_eq!(plan["unlink"], json!([text(&foreign)]));
    let mut all = vec![text(&real), text(&twin), text(&foreign)];
    all.sort();
    assert_eq!(paths(&plan["replace"]), all);
    assert_eq!(plan["conflicts"], json!([]));
    let before = snap(env.temp.path());
    let mut run = request;
    run["confirmed"] = json!(true);
    let done = env.ok("skillsImportApply", run);
    assert_eq!(done["conflicts"], json!([]));
    assert_eq!(done["imported"][0]["group"], "trabajo");
    assert_eq!(
        paths(&done["imported"][0]["agents"]),
        vec!["claude", "codex", "gemini"]
    );
    // Each planned path is now a link to Stack's copy; the foreign target is intact.
    let after = snap(env.temp.path());
    let stack = format!("->{}", env.skills_dir().join("a").display());
    for path in &all {
        let rel = Path::new(path).strip_prefix(env.temp.path()).unwrap();
        assert_eq!(after[&rel.to_string_lossy().to_string()], stack);
    }
    assert_eq!(fs::read_to_string(outside.join("n.md")).unwrap(), "n");
    // Nothing else outside Stack's data folder changed.
    let changed: Vec<&String> = before
        .iter()
        .filter(|(k, v)| after.get(*k) != Some(v))
        .map(|(k, _)| k)
        .filter(|k| k.starts_with("home/"))
        .collect();
    let mut expected: Vec<String> = all
        .iter()
        .map(|p| {
            let rel = Path::new(p).strip_prefix(env.temp.path()).unwrap();
            rel.to_string_lossy().to_string()
        })
        .collect();
    // The two moved folders also lose their files.
    expected.extend(
        before
            .keys()
            .filter(|k| {
                k.starts_with("home/.claude/skills/a/") || k.starts_with("home/.gemini/skills/a/")
            })
            .cloned(),
    );
    expected.sort();
    let mut changed: Vec<String> = changed.into_iter().cloned().collect();
    changed.sort();
    assert_eq!(changed, expected);
    let list = env.ok("skillsImportTrashList", json!({}));
    let sources = list[0]["sources"].as_array().unwrap();
    assert_eq!(sources.len(), 3);
    assert_eq!(sources.iter().filter(|s| s["kind"] == "folder").count(), 2);
}

#[test]
fn apply_without_confirmed_is_refused() {
    let env = env();
    let real = folder(&env, ".claude/skills", "a", &[]);
    let request = json!({"ids": ["a"], "group": "personal"});
    env.ok("skillsList", json!({}));
    let before = snap(&env.home);
    assert_eq!(
        env.code("skillsImportApply", request),
        "confirmation_required"
    );
    let off = json!({"ids": ["a"], "group": "personal", "confirmed": false});
    assert_eq!(env.code("skillsImportApply", off), "confirmation_required");
    assert!(fs::symlink_metadata(&real).unwrap().is_dir());
    assert_eq!(snap(&env.home), before);
    let missing = json!({"group": "personal", "confirmed": true});
    assert_eq!(env.code("skillsImportApply", missing), "invalid_request");
    let group = json!({"ids": ["a"], "group": "nada", "confirmed": true});
    assert_eq!(env.code("skillsImportApply", group), "skills_invalid_group");
}
