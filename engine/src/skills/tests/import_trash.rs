//! Import of existing skills: failure rollback, no data loss, the import trash and emptying it.
use super::import::*;
use super::*;
use crate::skills::import::FAIL_AFTER_FIRST;
use std::{collections::BTreeMap, fs, os::unix::fs::symlink};

#[test]
fn the_copy_is_byte_identical_and_inner_links_are_not_followed() {
    let env = env();
    let files = [
        ("scripts/run.sh", "echo hi\n"),
        ("deep/er/data.txt", "datos"),
    ];
    let real = folder(&env, ".claude/skills", "a", &files);
    fs::write(real.join("bin.dat"), [0u8, 255, 1, 2, 254]).unwrap();
    let secret = env.home.join("secretos");
    fs::create_dir_all(&secret).unwrap();
    fs::write(secret.join("clave.txt"), "no copiar").unwrap();
    symlink(&secret, real.join("fuera")).unwrap();
    symlink(secret.join("clave.txt"), real.join("clave.txt")).unwrap();
    let mut expected = snap(&real);
    expected.retain(|_, v| !v.starts_with("->"));
    apply(&env, &["a"]);
    let copy = env.skills_dir().join("a");
    assert_eq!(snap(&copy), expected);
    assert_eq!(
        fs::read(copy.join("bin.dat")).unwrap(),
        [0u8, 255, 1, 2, 254]
    );
    assert!(fs::symlink_metadata(copy.join("fuera")).is_err());
    assert!(fs::symlink_metadata(copy.join("clave.txt")).is_err());
    assert_eq!(
        fs::read_to_string(secret.join("clave.txt")).unwrap(),
        "no copiar"
    );
}

#[test]
fn folders_go_to_the_import_trash_and_undo_brings_everything_back() {
    let env = env();
    let real = folder(&env, ".claude/skills", "a", &[("n.md", "n")]);
    let target = elsewhere(&env, "a");
    let foreign = link(&env, ".agents/skills", "a", &target);
    apply(&env, &["a"]);
    let trash_id = first_trash_id(&env);
    assert!(trash_id.starts_with("import-a-"));
    let dir = trash_dir(&env).join(&trash_id);
    assert_eq!(fs::read_to_string(dir.join("sources/0/n.md")).unwrap(), "n");
    let entry: Value = serde_json::from_slice(&fs::read(dir.join("entry.json")).unwrap()).unwrap();
    assert_eq!(entry["sources"][0]["path"], text(&real));
    assert_eq!(entry["sources"][0]["agent"], "claude");
    assert!(env.link_path(".claude/skills", "a").join("n.md").exists());
    assert_eq!(fs::read_link(&foreign).unwrap(), env.skills_dir().join("a"));
    assert_eq!(fs::read_to_string(target.join("n.md")).unwrap(), "n");
    // Undo: needs confirmation; the plan lists what it does.
    let ask = json!({"trashId": trash_id});
    assert_eq!(env.code("skillsImportUndo", ask), "confirmation_required");
    let plan = env.ok(
        "skillsImportUndo",
        json!({"trashId": trash_id, "plan": true}),
    );
    let restore = json!([{"from": text(&dir.join("sources/0")), "to": text(&real)}]);
    assert_eq!(plan["restore"], restore);
    let relink = json!([{"path": text(&foreign), "target": text(&target)}]);
    assert_eq!(plan["relink"], relink);
    assert_eq!(
        paths(&plan["remove"]),
        paths(&json!([text(&real), text(&foreign)]))
    );
    assert_eq!(plan["conflicts"], json!([]));
    assert!(env.skills_dir().join("a").exists());
    let done = env.ok(
        "skillsImportUndo",
        json!({"trashId": trash_id, "confirmed": true}),
    );
    assert_eq!(done["conflicts"], json!([]));
    assert!(fs::symlink_metadata(&real).unwrap().is_dir());
    assert_eq!(fs::read_to_string(real.join("n.md")).unwrap(), "n");
    assert_eq!(fs::read_link(&foreign).unwrap(), target);
    assert!(!env.skills_dir().join("a").exists());
    assert!(!dir.exists());
    assert_eq!(env.ok("skillsImportTrashList", json!({})), json!([]));
    assert_eq!(env.ok("skillsList", json!({}))["skills"], json!([]));
}

#[test]
fn undo_with_a_changed_copy_does_nothing() {
    let env = env();
    let real = folder(&env, ".claude/skills", "a", &[]);
    apply(&env, &["a"]);
    let trash_id = first_trash_id(&env);
    fs::write(env.skills_dir().join("a/SKILL.md"), "editado").unwrap();
    let before = snap(env.root.as_path());
    let done = env.ok(
        "skillsImportUndo",
        json!({"trashId": trash_id, "confirmed": true}),
    );
    assert_eq!(done["restored"], json!([]));
    assert_eq!(done["conflicts"][0]["reason"], "changed");
    assert_eq!(snap(env.root.as_path()), before);
    assert!(fs::symlink_metadata(&real)
        .unwrap()
        .file_type()
        .is_symlink());
}

#[test]
fn a_failure_midway_rolls_that_skill_back_and_the_others_are_imported() {
    let env = env();
    let real = folder(&env, ".claude/skills", "a", &[("n.md", "n")]);
    let target = elsewhere(&env, "a");
    let foreign = link(&env, ".agents/skills", "a", &target);
    folder(&env, ".claude/skills", "b", &[]);
    let before = snap(&env.home);
    FAIL_AFTER_FIRST.with(|f| *f.borrow_mut() = Some("a".into()));
    let done = apply(&env, &["a", "b"]);
    FAIL_AFTER_FIRST.with(|f| *f.borrow_mut() = None);
    assert_eq!(done["imported"].as_array().unwrap().len(), 1);
    assert_eq!(done["imported"][0]["id"], "b");
    let failed = json!([{"path": text(&real), "reason": "skills_import_failed"}]);
    assert_eq!(done["conflicts"], failed);
    // `a` is as it was: folder, link, no copy, no entry, no trash entry.
    assert!(fs::symlink_metadata(&real).unwrap().is_dir());
    assert_eq!(fs::read_link(&foreign).unwrap(), target);
    assert!(!env.skills_dir().join("a").exists());
    let list = env.ok("skillsList", json!({}));
    assert_eq!(list["skills"].as_array().unwrap().len(), 1);
    let trashed = env.ok("skillsImportTrashList", json!({}));
    assert_eq!(trashed.as_array().unwrap().len(), 1);
    assert_eq!(trashed[0]["id"], "b");
    let after = snap(&env.home);
    for (key, value) in &before {
        if key.starts_with(".claude/skills/a")
            || key.starts_with(".agents/skills/a")
            || key.starts_with("elsewhere")
        {
            assert_eq!(after.get(key), Some(value), "{key}");
        }
    }
}

#[test]
fn no_file_is_ever_deleted() {
    let env = env();
    folder(
        &env,
        ".claude/skills",
        "a",
        &[("x/y.md", "y"), ("z.md", "z")],
    );
    folder(
        &env,
        ".gemini/skills",
        "a",
        &[("x/y.md", "y"), ("z.md", "z")],
    );
    folder(&env, ".agents/skills", "b", &[("w.md", "w")]);
    let before: Vec<(String, String)> = snap(&env.home)
        .into_iter()
        .filter(|(_, v)| v != "dir")
        .collect();
    assert_eq!(before.len(), 8);
    apply(&env, &["a", "b"]);
    // Every original file is in the import trash with the same bytes, at its folder's slot.
    let mut kept: Vec<String> = snap(&trash_dir(&env))
        .into_iter()
        .filter(|(k, v)| k.contains("/sources/") && v != "dir")
        .map(|(_, v)| v)
        .collect();
    let mut wanted: Vec<String> = before.into_iter().map(|(_, v)| v).collect();
    kept.sort();
    wanted.sort();
    assert_eq!(kept, wanted);
}

#[test]
fn the_import_trash_is_not_purged_by_age_but_deleted_skills_are() {
    let env = env();
    folder(&env, ".claude/skills", "a", &[("n.md", "n")]);
    apply(&env, &["a"]);
    let trash_id = first_trash_id(&env);
    let old = trash_dir(&env).join("import-a-1000");
    fs::rename(trash_dir(&env).join(&trash_id), &old).unwrap();
    // A deleted skill whose id starts with `import-` is purged like any other.
    env.create("import-x");
    let gone = env.ok("skillsDelete", json!({"id": "import-x", "confirmed": true}));
    let aged = trash_dir(&env).join("import-x-1000");
    fs::rename(
        trash_dir(&env).join(gone["trashId"].as_str().unwrap()),
        &aged,
    )
    .unwrap();
    env.ok("skillsList", json!({}));
    assert!(old.join("sources/0/n.md").exists());
    assert!(!aged.exists());
    assert_eq!(first_trash_id(&env), "import-a-1000");
    // «Borrar los datos» of the tool leaves it too.
    crate::skills::delete_all(&env.store).unwrap();
    assert!(old.join("sources/0/n.md").exists());
}

#[test]
fn emptying_the_import_trash_needs_confirmed_and_removes_only_the_listed_folders() {
    let env = env();
    folder(&env, ".claude/skills", "a", &[]);
    folder(&env, ".claude/skills", "b", &[]);
    apply(&env, &["a", "b"]);
    env.create("gone");
    env.ok("skillsDelete", json!({"id": "gone", "confirmed": true}));
    let list = env.ok("skillsImportTrashList", json!({}));
    let ids: Vec<String> = list
        .as_array()
        .unwrap()
        .iter()
        .map(|e| e["trashId"].as_str().unwrap().to_string())
        .collect();
    assert_eq!(ids.len(), 2);
    let a = ids
        .iter()
        .find(|i| i.starts_with("import-a-"))
        .unwrap()
        .clone();
    let b = ids
        .iter()
        .find(|i| i.starts_with("import-b-"))
        .unwrap()
        .clone();
    let before = snap(&trash_dir(&env));
    let code = |request: Value| env.code("skillsImportTrashEmpty", request);
    assert_eq!(code(json!({"trashIds": [a]})), "confirmation_required");
    assert_eq!(
        code(json!({"trashIds": [], "confirmed": true})),
        "invalid_request"
    );
    assert_eq!(
        code(json!({"trashIds": ["gone-1"], "confirmed": true})),
        "skills_not_found"
    );
    assert_eq!(
        code(json!({"trashIds": ["../x"], "confirmed": true})),
        "skills_not_found"
    );
    let plan = env.ok(
        "skillsImportTrashEmpty",
        json!({"trashIds": [a], "plan": true}),
    );
    assert_eq!(plan["delete"], json!([text(&trash_dir(&env).join(&a))]));
    assert_eq!(snap(&trash_dir(&env)), before);
    let done = env.ok(
        "skillsImportTrashEmpty",
        json!({"trashIds": [a], "confirmed": true}),
    );
    assert_eq!(done["removed"], json!([a]));
    assert!(!trash_dir(&env).join(&a).exists());
    assert!(trash_dir(&env).join(&b).join("sources/0/SKILL.md").exists());
    let expected: BTreeMap<String, String> = before
        .into_iter()
        .filter(|(k, _)| !k.starts_with(&a))
        .collect();
    assert_eq!(snap(&trash_dir(&env)), expected);
    assert!(env.skills_dir().join("a").exists());
}
