use super::*;
use std::fs;
use std::os::unix::fs::symlink;

fn old(env: &Env, id: &str) -> PathBuf {
    env.link_path(".codex/skills", id)
}

fn new(env: &Env, id: &str) -> PathBuf {
    env.link_path(".agents/skills", id)
}

/// Stack links for `skills` the way the previous version did, in `~/.codex/skills`.
fn legacy(env: &Env, skills: &[&str]) {
    fs::create_dir_all(env.home.join(".codex/skills")).unwrap();
    for id in skills {
        env.create(id);
        symlink(env.skills_dir().join(id), old(env, id)).unwrap();
    }
}

fn migrate(env: &Env, extra: Value) -> Value {
    let mut request = json!({"migrate": "codex"});
    request
        .as_object_mut()
        .unwrap()
        .extend(extra.as_object().unwrap().clone());
    env.ok("skillsLinkPlan", request)
}

fn apply(env: &Env) -> Result<Value, String> {
    env.call(
        "skillsLinkApply",
        json!({"migrate": "codex", "confirmed": true}),
    )
    .map_err(|e| e.to_string())
}

#[test]
fn codex_default_folder_is_the_shared_agents_folder() {
    let env = env();
    let list = env.ok("skillsList", json!({}));
    let codex = list["agents"]
        .as_array()
        .unwrap()
        .iter()
        .find(|a| a["id"] == "codex")
        .unwrap();
    assert_eq!(codex["folder"], "~/.agents/skills");
    env.create("a");
    env.link("a", "codex");
    assert_eq!(
        fs::read_link(new(&env, "a")).unwrap(),
        env.skills_dir().join("a")
    );
    assert!(!env.home.join(".codex").exists());
}

#[test]
fn an_index_saved_with_the_old_folder_is_normalized() {
    let env = env();
    env.create("a");
    let path = env.skills_dir().join("index.json");
    let mut index: Value = serde_json::from_str(&fs::read_to_string(&path).unwrap()).unwrap();
    index["agents"]["codex"] = json!({"folder": "~/.codex/skills"});
    fs::write(&path, index.to_string()).unwrap();
    let list = env.ok("skillsList", json!({}));
    let folder = list["agents"]
        .as_array()
        .unwrap()
        .iter()
        .find(|a| a["id"] == "codex")
        .unwrap()["folder"]
        .clone();
    assert_eq!(folder, "~/.agents/skills");
}

#[test]
fn the_plan_lists_exactly_the_stack_links_and_never_foreign_entries() {
    let env = env();
    legacy(&env, &["uno", "dos"]);
    let folder = env.home.join(".codex/skills");
    // Foreign things: a bundled real folder, a link elsewhere, a link into Stack with another name.
    fs::create_dir_all(folder.join(".system")).unwrap();
    fs::write(folder.join(".system/SKILL.md"), "mio").unwrap();
    let elsewhere = env.root.as_path().join("otro");
    fs::create_dir(&elsewhere).unwrap();
    symlink(&elsewhere, folder.join("ajena")).unwrap();
    symlink(env.skills_dir().join("uno"), folder.join("alias")).unwrap();

    let plan = migrate(&env, json!({}));
    assert_eq!(
        plan["create"],
        json!([new(&env, "dos"), new(&env, "uno")].map(|p| p.to_string_lossy().to_string()))
    );
    assert_eq!(
        plan["remove"],
        json!([old(&env, "dos"), old(&env, "uno")].map(|p| p.to_string_lossy().to_string()))
    );
    assert_eq!(plan["conflicts"], json!([]));
    // Planning wrote nothing.
    assert!(!env.home.join(".agents").exists());

    let health = env.ok("skillsHealth", json!({}));
    let moved: Vec<&Value> = health
        .as_array()
        .unwrap()
        .iter()
        .filter(|i| i["kind"] == "moved_folder")
        .collect();
    assert_eq!(moved.len(), 1);
    assert_eq!(moved[0]["agent"], "codex");
    assert_eq!(moved[0]["path"], folder.to_string_lossy().as_ref());

    apply(&env).unwrap();
    assert!(folder.join(".system/SKILL.md").exists());
    assert_eq!(fs::read_link(folder.join("ajena")).unwrap(), elsewhere);
    assert!(fs::symlink_metadata(folder.join("alias")).is_ok());
}

#[test]
fn conflicts_in_the_shared_folder_are_reported_and_left_alone() {
    let env = env();
    legacy(&env, &["uno", "dos"]);
    let taken = new(&env, "uno");
    fs::create_dir_all(&taken).unwrap();
    fs::write(taken.join("de-otra-ia.txt"), "no tocar").unwrap();

    let plan = migrate(&env, json!({}));
    assert_eq!(plan["create"], json!([new(&env, "dos").to_string_lossy()]));
    assert_eq!(plan["remove"], json!([old(&env, "dos").to_string_lossy()]));
    assert_eq!(
        plan["conflicts"],
        json!([{"path": taken.to_string_lossy(), "reason": "exists"}])
    );

    let done = apply(&env).unwrap();
    assert_eq!(
        done["conflicts"][0]["path"],
        taken.to_string_lossy().as_ref()
    );
    assert_eq!(
        fs::read_to_string(taken.join("de-otra-ia.txt")).unwrap(),
        "no tocar"
    );
    // The old link of the conflicting skill stays; the other one moved.
    assert!(fs::symlink_metadata(old(&env, "uno")).is_ok());
    assert!(fs::symlink_metadata(old(&env, "dos")).is_err());
}

#[test]
fn apply_needs_confirmation_and_then_moves_the_links() {
    let env = env();
    legacy(&env, &["uno", "dos"]);
    let err = env
        .call("skillsLinkApply", json!({"migrate": "codex"}))
        .unwrap_err()
        .to_string();
    assert_eq!(err, "confirmation_required");
    assert!(fs::symlink_metadata(old(&env, "uno")).is_ok());
    assert!(!env.home.join(".agents").exists());

    let done = apply(&env).unwrap();
    assert_eq!(done["conflicts"], json!([]));
    assert_eq!(done["created"].as_array().unwrap().len(), 2);
    assert_eq!(done["removed"].as_array().unwrap().len(), 2);
    for id in ["uno", "dos"] {
        assert!(fs::symlink_metadata(old(&env, id)).is_err());
        assert_eq!(
            fs::read_link(new(&env, id)).unwrap(),
            env.skills_dir().join(id)
        );
    }
    let list = env.ok("skillsList", json!({}));
    for skill in list["skills"].as_array().unwrap() {
        assert_eq!(skill["agents"], json!(["codex"]));
    }
    // Nothing left to move: no finding, empty plan.
    assert_eq!(migrate(&env, json!({}))["remove"], json!([]));
    assert!(env
        .ok("skillsHealth", json!({}))
        .as_array()
        .unwrap()
        .iter()
        .all(|i| i["kind"] != "moved_folder"));
}

#[test]
fn only_codex_can_migrate() {
    let env = env();
    assert_eq!(
        env.code("skillsLinkPlan", json!({"migrate": "claude"})),
        "invalid_request"
    );
}
