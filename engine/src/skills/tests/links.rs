use super::*;
use std::fs;

#[test]
fn plan_does_nothing_and_apply_needs_confirmation() {
    let env = env();
    env.create("a");
    let request = json!({"changes": [{"skill": "a", "agent": "claude", "on": true}]});
    let plan = env.ok("skillsLinkPlan", request.clone());
    let path = env.link_path(".claude/skills", "a");
    assert_eq!(plan["create"], json!([path.to_string_lossy()]));
    assert_eq!(plan["remove"], json!([]));
    assert_eq!(plan["conflicts"], json!([]));
    assert!(!env.home.join(".claude").exists());
    assert_eq!(
        env.code("skillsLinkApply", request),
        "confirmation_required"
    );
    assert!(!env.home.join(".claude").exists());
}

#[test]
fn apply_links_to_the_real_copy_and_remove_only_own_links() {
    let env = env();
    env.create("a");
    let done = env.link("a", "claude");
    let path = env.link_path(".claude/skills", "a");
    assert_eq!(done["created"], json!([path.to_string_lossy()]));
    assert_eq!(fs::read_link(&path).unwrap(), env.skills_dir().join("a"));
    assert_eq!(
        env.ok("skillsList", json!({}))["skills"][0]["agents"],
        json!(["claude"])
    );

    // Off by agent: the link goes, the real copy stays.
    let off = env.ok(
        "skillsLinkApply",
        json!({"changes": [{"skill": "a", "agent": "claude", "on": false}], "confirmed": true}),
    );
    assert_eq!(off["removed"], json!([path.to_string_lossy()]));
    assert!(!path.exists() && env.skills_dir().join("a/SKILL.md").exists());
    assert_eq!(
        env.ok("skillsList", json!({}))["skills"][0]["agents"],
        json!([])
    );

    // A link of someone else with the same name is never removed.
    let other = env.temp.path().join("otro");
    fs::create_dir(&other).unwrap();
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::os::unix::fs::symlink(&other, &path).unwrap();
    let off = env.ok(
        "skillsLinkApply",
        json!({"changes": [{"skill": "a", "agent": "claude", "on": false}], "confirmed": true}),
    );
    assert_eq!(off["removed"], json!([]));
    assert!(fs::symlink_metadata(&path).is_ok());
}

#[test]
fn a_conflict_is_left_alone_and_reported() {
    let env = env();
    env.create("a");
    let path = env.link_path(".agents/skills", "a");
    fs::create_dir_all(&path).unwrap();
    fs::write(path.join("mio.txt"), "no tocar").unwrap();
    let request =
        json!({"changes": [{"skill": "a", "agent": "codex", "on": true}], "confirmed": true});
    let plan = env.ok("skillsLinkPlan", request.clone());
    assert_eq!(plan["create"], json!([]));
    assert_eq!(plan["conflicts"][0]["reason"], "exists");
    let done = env.ok("skillsLinkApply", request);
    assert_eq!(done["created"], json!([]));
    assert_eq!(
        done["conflicts"][0]["path"],
        path.to_string_lossy().as_ref()
    );
    assert_eq!(
        fs::read_to_string(path.join("mio.txt")).unwrap(),
        "no tocar"
    );
    // Not recorded as linked, and Health says why.
    assert_eq!(
        env.ok("skillsList", json!({}))["skills"][0]["agents"],
        json!([])
    );
    // ChatGPT has no folder: export only.
    let plan = env.ok(
        "skillsLinkPlan",
        json!({"changes": [{"skill": "a", "agent": "chatgpt", "on": true}]}),
    );
    assert_eq!(plan["conflicts"][0]["reason"], "export_only");
}

#[test]
fn kiro_is_export_only_and_never_touches_its_folder() {
    let env = env();
    env.create("a");
    let list = env.ok("skillsList", json!({}));
    let kiro = list["agents"]
        .as_array()
        .unwrap()
        .iter()
        .find(|a| a["id"] == "kiro")
        .unwrap();
    assert_eq!(kiro["name"], "Kiro");
    assert_eq!(kiro["mode"], "export");
    assert_eq!(kiro["builtin"], true);
    assert!(kiro["folder"].is_null());
    // Asking to link it is refused; nothing is created and the skill is not recorded as linked.
    let request = json!({"changes": [{"skill": "a", "agent": "kiro", "on": true}]});
    let plan = env.ok("skillsLinkPlan", request.clone());
    assert_eq!(plan["conflicts"][0]["reason"], "export_only");
    assert_eq!(plan["create"], json!([]));
    let done = env.ok(
        "skillsLinkApply",
        json!({"changes": request["changes"], "confirmed": true}),
    );
    assert_eq!(done["created"], json!([]));
    assert_eq!(
        env.ok("skillsList", json!({}))["skills"][0]["agents"],
        json!([])
    );
    assert!(!env.home.join(".kiro").exists());
    // It cannot be redefined as a custom AI.
    assert_eq!(
        env.code(
            "skillsAgentSave",
            json!({"id": "kiro", "name": "Kiro", "folder": "~/.kiro/crew/skills"})
        ),
        "skills_agent_builtin"
    );
    // Export works, and an index saved before Kiro existed still lists it.
    let text = env.ok("skillsExport", json!({"id": "a", "format": "markdown"}));
    assert!(text["text"].as_str().unwrap().starts_with("# a\n"));
    let path = env.skills_dir().join("index.json");
    let mut index: Value = serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
    index["agents"] = json!({});
    std::fs::write(&path, index.to_string()).unwrap();
    let list = env.ok("skillsList", json!({}));
    assert!(list["agents"]
        .as_array()
        .unwrap()
        .iter()
        .any(|a| a["id"] == "kiro" && a["mode"] == "export"));
    assert!(!env.home.join(".kiro").exists());
}

#[test]
fn disabling_removes_links_and_enabling_brings_them_back() {
    let env = env();
    env.create("a");
    env.link("a", "claude");
    env.link("a", "gemini");
    let plan = env.ok("skillsLinkPlan", json!({"skill": "a", "enabled": false}));
    assert_eq!(plan["remove"].as_array().unwrap().len(), 2);
    let done = env.ok(
        "skillsLinkApply",
        json!({"skill": "a", "enabled": false, "confirmed": true}),
    );
    assert_eq!(done["removed"].as_array().unwrap().len(), 2);
    let skill = &env.ok("skillsList", json!({}))["skills"][0];
    assert_eq!(skill["enabled"], false);
    assert_eq!(skill["agents"], json!(["claude", "gemini"]));
    assert!(fs::symlink_metadata(env.link_path(".claude/skills", "a")).is_err());
    let done = env.ok(
        "skillsLinkApply",
        json!({"skill": "a", "enabled": true, "confirmed": true}),
    );
    assert_eq!(done["created"].as_array().unwrap().len(), 2);
    assert!(env.link_path(".gemini/skills", "a").exists());
}

#[test]
fn rename_relinks() {
    let env = env();
    env.create("a");
    env.link("a", "claude");
    let renamed = env.ok(
        "skillsRename",
        json!({"id": "a", "newId": "b", "confirmed": true}),
    );
    assert_eq!(renamed["id"], "b");
    assert_eq!(renamed["name"], "b");
    assert_eq!(renamed["agents"], json!(["claude"]));
    assert!(fs::symlink_metadata(env.link_path(".claude/skills", "a")).is_err());
    let new = env.link_path(".claude/skills", "b");
    assert_eq!(fs::read_link(&new).unwrap(), env.skills_dir().join("b"));
    assert!(new.join("SKILL.md").exists());
    assert_eq!(
        env.code(
            "skillsRename",
            json!({"id": "a", "newId": "c", "confirmed": true})
        ),
        "skills_not_found"
    );
}

#[test]
fn custom_agents_are_validated_and_removed_with_their_links() {
    let env = env();
    env.create("a");
    for bad in ["/etc/skills", "~/../x", "~/", "~", "relativa", ""] {
        assert_eq!(
            env.code(
                "skillsAgentSave",
                json!({"id": "mia", "name": "Mía", "folder": bad})
            ),
            "skills_invalid_folder",
            "{bad}"
        );
    }
    // Stack's own data folder and a link that leaves the home are refused.
    let inside = env
        .store
        .root()
        .join("skills")
        .to_string_lossy()
        .to_string();
    assert_eq!(
        env.code(
            "skillsAgentSave",
            json!({"id": "mia", "name": "Mía", "folder": inside})
        ),
        "skills_invalid_folder"
    );
    let outside = tempfile::tempdir().unwrap();
    std::os::unix::fs::symlink(outside.path(), env.home.join("fuera")).unwrap();
    assert_eq!(
        env.code(
            "skillsAgentSave",
            json!({"id": "mia", "name": "Mía", "folder": "~/fuera/skills"})
        ),
        "skills_invalid_folder"
    );
    assert_eq!(
        env.code(
            "skillsAgentSave",
            json!({"id": "claude", "name": "X", "folder": "~/x"})
        ),
        "skills_agent_builtin"
    );
    assert_eq!(
        env.code(
            "skillsAgentSave",
            json!({"id": "mia", "name": "Mía", "folder": "~/.claude/skills"})
        ),
        "skills_invalid_folder"
    );

    let agents = env.ok(
        "skillsAgentSave",
        json!({"id": "mia", "name": "Mía", "folder": "~/.mia/skills"}),
    );
    assert!(agents
        .as_array()
        .unwrap()
        .iter()
        .any(|a| a["id"] == "mia" && a["builtin"] == false && a["mode"] == "link"));
    env.link("a", "mia");
    assert!(env.link_path(".mia/skills", "a").exists());
    assert_eq!(
        env.code(
            "skillsAgentSave",
            json!({"id": "mia", "name": "Mía", "folder": "~/.otra"})
        ),
        "skills_link_conflict"
    );
    assert_eq!(
        env.code("skillsAgentRemove", json!({"id": "mia"})),
        "confirmation_required"
    );
    assert_eq!(
        env.code(
            "skillsAgentRemove",
            json!({"id": "claude", "confirmed": true})
        ),
        "skills_agent_builtin"
    );
    env.ok("skillsAgentRemove", json!({"id": "mia", "confirmed": true}));
    assert!(fs::symlink_metadata(env.link_path(".mia/skills", "a")).is_err());
    assert_eq!(
        env.ok("skillsList", json!({}))["skills"][0]["agents"],
        json!([])
    );
}
