//! Rename, delete, restore and removing an AI are planned first (`plan: true`), then applied only
//! with `confirmed`; the plan lists exactly what the apply does.
use super::*;
use std::fs;

fn strs(value: &Value) -> Vec<String> {
    let mut list: Vec<String> = value
        .as_array()
        .unwrap()
        .iter()
        .map(|v| v.as_str().unwrap().to_string())
        .collect();
    list.sort();
    list
}

fn path(env: &Env, folder: &str, skill: &str) -> String {
    env.link_path(folder, skill).to_string_lossy().to_string()
}

#[test]
fn rename_plan_lists_links_and_conflicts_and_apply_does_the_same() {
    let env = env();
    env.create("a");
    env.link("a", "claude");
    env.link("a", "codex");
    // The new name is taken in Codex's folder by something else.
    let taken = env.link_path(".agents/skills", "b");
    fs::create_dir_all(&taken).unwrap();
    let request = json!({"id": "a", "newId": "b"});
    let plan = env.ok(
        "skillsRename",
        json!({"id": "a", "newId": "b", "plan": true}),
    );
    assert_eq!(
        strs(&plan["remove"]),
        vec![
            path(&env, ".agents/skills", "a"),
            path(&env, ".claude/skills", "a")
        ]
    );
    assert_eq!(plan["create"], json!([path(&env, ".claude/skills", "b")]));
    assert_eq!(
        plan["conflicts"],
        json!([{"path": path(&env, ".agents/skills", "b"), "reason": "exists"}])
    );
    // Planning changes nothing, and applying needs confirmation.
    assert!(env.skills_dir().join("a").exists() && !env.skills_dir().join("b").exists());
    assert!(fs::symlink_metadata(env.link_path(".claude/skills", "a")).is_ok());
    assert_eq!(
        env.code("skillsRename", request.clone()),
        "confirmation_required"
    );
    assert!(env.skills_dir().join("a").exists());

    env.ok(
        "skillsRename",
        json!({"id": "a", "newId": "b", "confirmed": true}),
    );
    assert!(fs::symlink_metadata(env.link_path(".claude/skills", "a")).is_err());
    assert!(fs::symlink_metadata(env.link_path(".agents/skills", "a")).is_err());
    assert!(env
        .link_path(".claude/skills", "b")
        .join("SKILL.md")
        .exists());
    assert!(fs::symlink_metadata(&taken).unwrap().is_dir());
}

#[test]
fn rename_plan_refuses_what_apply_refuses() {
    let env = env();
    env.create("a");
    env.create("b");
    assert_eq!(
        env.code(
            "skillsRename",
            json!({"id": "a", "newId": "b", "plan": true})
        ),
        "skills_exists"
    );
    assert_eq!(
        env.code(
            "skillsRename",
            json!({"id": "a", "newId": "../b", "plan": true})
        ),
        "skills_invalid_id"
    );
    assert_eq!(
        env.code(
            "skillsRename",
            json!({"id": "zz", "newId": "c", "plan": true})
        ),
        "skills_not_found"
    );
}

#[test]
fn delete_plan_lists_the_links_it_removes() {
    let env = env();
    env.create("a");
    env.link("a", "claude");
    // A link of someone else with the same name is not listed nor removed.
    let other = env.link_path(".agents/skills", "a");
    fs::create_dir_all(other.parent().unwrap()).unwrap();
    std::os::unix::fs::symlink(env.root.as_path(), &other).unwrap();
    let plan = env.ok("skillsDelete", json!({"id": "a", "plan": true}));
    assert_eq!(plan["remove"], json!([path(&env, ".claude/skills", "a")]));
    assert_eq!(plan["create"], json!([]));
    assert_eq!(plan["conflicts"], json!([]));
    assert!(env.skills_dir().join("a").exists());
    assert_eq!(
        env.code("skillsDelete", json!({"id": "a"})),
        "confirmation_required"
    );
    assert!(env.skills_dir().join("a").exists());
    env.ok("skillsDelete", json!({"id": "a", "confirmed": true}));
    assert!(fs::symlink_metadata(env.link_path(".claude/skills", "a")).is_err());
    assert!(fs::symlink_metadata(&other).is_ok());
}

#[test]
fn agent_remove_plan_lists_the_links_it_removes() {
    let env = env();
    env.create("a");
    env.create("b");
    env.ok(
        "skillsAgentSave",
        json!({"id": "mia", "name": "Mía", "folder": "~/.mia/skills"}),
    );
    env.link("a", "mia");
    env.link("b", "mia");
    env.link("a", "claude");
    let plan = env.ok("skillsAgentRemove", json!({"id": "mia", "plan": true}));
    assert_eq!(
        strs(&plan["remove"]),
        vec![
            path(&env, ".mia/skills", "a"),
            path(&env, ".mia/skills", "b")
        ]
    );
    assert_eq!(plan["create"], json!([]));
    assert!(env.link_path(".mia/skills", "a").exists());
    assert_eq!(
        env.code("skillsAgentRemove", json!({"id": "claude", "plan": true})),
        "skills_agent_builtin"
    );
    assert_eq!(
        env.code("skillsAgentRemove", json!({"id": "mia"})),
        "confirmation_required"
    );
    assert!(env.link_path(".mia/skills", "a").exists());
    env.ok("skillsAgentRemove", json!({"id": "mia", "confirmed": true}));
    assert!(fs::symlink_metadata(env.link_path(".mia/skills", "a")).is_err());
    assert!(fs::symlink_metadata(env.link_path(".mia/skills", "b")).is_err());
    assert!(env.link_path(".claude/skills", "a").exists());
}

#[test]
fn restore_plan_lists_the_links_it_recreates_and_the_taken_names() {
    let env = env();
    env.create("a");
    env.link("a", "claude");
    env.link("a", "codex");
    let trash = env.ok("skillsDelete", json!({"id": "a", "confirmed": true}))["trashId"]
        .as_str()
        .unwrap()
        .to_string();
    let taken = env.link_path(".agents/skills", "a");
    fs::create_dir_all(&taken).unwrap();
    let plan = env.ok("skillsRestore", json!({"trashId": trash, "plan": true}));
    assert_eq!(plan["create"], json!([path(&env, ".claude/skills", "a")]));
    assert_eq!(plan["remove"], json!([]));
    assert_eq!(
        plan["conflicts"],
        json!([{"path": path(&env, ".agents/skills", "a"), "reason": "exists"}])
    );
    // Planning leaves the trash as it was; restoring needs confirmation.
    assert!(env.store.root().join("skills-trash").join(&trash).exists());
    assert_eq!(
        env.code("skillsRestore", json!({"trashId": trash})),
        "confirmation_required"
    );
    assert!(env.store.root().join("skills-trash").join(&trash).exists());
    env.ok(
        "skillsRestore",
        json!({"trashId": trash, "confirmed": true}),
    );
    assert!(env
        .link_path(".claude/skills", "a")
        .join("SKILL.md")
        .exists());
    assert!(fs::symlink_metadata(&taken).unwrap().is_dir());
    assert_eq!(
        env.code("skillsRestore", json!({"trashId": trash, "plan": true})),
        "skills_not_found"
    );
}
