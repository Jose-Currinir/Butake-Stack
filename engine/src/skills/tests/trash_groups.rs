use super::*;
use std::fs;

#[test]
fn delete_and_restore_bring_the_links_back() {
    let env = env();
    env.create("a");
    fs::write(env.skills_dir().join("a/extra.md"), "x").unwrap();
    env.link("a", "claude");
    let trash = env.ok("skillsDelete", json!({"id": "a", "confirmed": true}))["trashId"]
        .as_str()
        .unwrap()
        .to_string();
    assert!(trash.starts_with("a-"));
    assert!(!env.skills_dir().join("a").exists());
    assert!(fs::symlink_metadata(env.link_path(".claude/skills", "a")).is_err());
    assert_eq!(env.ok("skillsList", json!({}))["skills"], json!([]));
    assert!(
        env.store
            .root()
            .join("skills-trash")
            .join(&trash)
            .join("files/extra.md")
            .exists()
    );

    let back = env.ok(
        "skillsRestore",
        json!({"trashId": trash, "confirmed": true}),
    );
    assert_eq!(back["id"], "a");
    assert_eq!(back["agents"], json!(["claude"]));
    assert!(
        env.link_path(".claude/skills", "a")
            .join("extra.md")
            .exists()
    );
    assert!(!env.store.root().join("skills-trash").join(&trash).exists());
    assert_eq!(
        env.code(
            "skillsRestore",
            json!({"trashId": trash, "confirmed": true})
        ),
        "skills_not_found"
    );
    assert_eq!(
        env.code(
            "skillsRestore",
            json!({"trashId": "../x", "confirmed": true})
        ),
        "skills_not_found"
    );
}

#[test]
fn restore_leaves_a_taken_link_name_alone_and_refuses_a_taken_id() {
    let env = env();
    env.create("a");
    env.link("a", "claude");
    let trash = env.ok("skillsDelete", json!({"id": "a", "confirmed": true}))["trashId"]
        .as_str()
        .unwrap()
        .to_string();
    let taken = env.link_path(".claude/skills", "a");
    fs::create_dir_all(&taken).unwrap();
    env.create("a");
    assert_eq!(
        env.code(
            "skillsRestore",
            json!({"trashId": trash, "confirmed": true})
        ),
        "skills_exists"
    );
    env.ok("skillsDelete", json!({"id": "a", "confirmed": true}));
    let back = env.ok(
        "skillsRestore",
        json!({"trashId": trash, "confirmed": true}),
    );
    assert_eq!(back["id"], "a");
    assert!(taken.is_dir() && fs::symlink_metadata(&taken).unwrap().is_dir());
}

#[test]
fn old_trash_is_purged_on_list() {
    let env = env();
    let old = env.store.root().join("skills-trash/a-1000");
    fs::create_dir_all(old.join("files")).unwrap();
    let fresh = env
        .store
        .root()
        .join(format!("skills-trash/b-{}", crate::core::time::now_secs()));
    fs::create_dir_all(&fresh).unwrap();
    env.ok("skillsList", json!({}));
    assert!(!old.exists() && fresh.exists());
}

#[test]
fn groups_are_saved_in_one_call_and_deleted_moving_their_skills() {
    let env = env();
    env.create("a");
    let groups = env.ok(
        "skillsGroupSave",
        json!({"groups": [
            {"id": "trabajo", "name": "Oficina", "order": 0},
            {"id": "personal", "name": "Personal", "order": 1},
            {"id": "butake", "name": "Butake", "order": 2},
            {"id": "nuevo", "name": "Nuevo", "order": 3}]}),
    );
    assert_eq!(groups[0]["id"], "trabajo");
    assert_eq!(groups[0]["name"], "Oficina");
    assert_eq!(groups.as_array().unwrap().len(), 4);
    // A group that holds skills cannot be left out of the list.
    assert_eq!(
        env.code(
            "skillsGroupSave",
            json!({"groups": [{"id": "nuevo", "name": "Nuevo", "order": 0}]})
        ),
        "skills_invalid_group"
    );
    assert_eq!(
        env.code(
            "skillsGroupSave",
            json!({"groups": [{"id": "Mal", "name": "x", "order": 0}]})
        ),
        "skills_invalid_group"
    );
    assert_eq!(
        env.code("skillsGroupDelete", json!({"id": "personal"})),
        "skills_group_not_empty"
    );
    assert_eq!(
        env.code(
            "skillsGroupDelete",
            json!({"id": "personal", "moveTo": "personal"})
        ),
        "skills_invalid_group"
    );
    assert_eq!(
        env.code(
            "skillsGroupDelete",
            json!({"id": "personal", "moveTo": "zzz"})
        ),
        "skills_invalid_group"
    );
    let groups = env.ok(
        "skillsGroupDelete",
        json!({"id": "personal", "moveTo": "nuevo"}),
    );
    assert_eq!(groups.as_array().unwrap().len(), 3);
    assert_eq!(
        env.ok("skillsList", json!({}))["skills"][0]["group"],
        "nuevo"
    );
    // An empty group goes without a destination.
    env.ok("skillsGroupDelete", json!({"id": "butake"}));
}
