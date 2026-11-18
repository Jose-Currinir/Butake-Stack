use crate::app::plugins;
use crate::core::store::Store;
use serde_json::{Value, json};

#[test]
fn every_method_answers_plugin_disabled_while_off_and_the_tool_registers() {
    let temp = tempfile::tempdir().unwrap();
    let store = Store::new(temp.path().join("store")).unwrap();
    for method in [
        "skillsList",
        "skillsRead",
        "skillsCreate",
        "skillsSave",
        "skillsUpdate",
        "skillsDuplicate",
        "skillsRename",
        "skillsDelete",
        "skillsRestore",
        "skillsGroupSave",
        "skillsGroupDelete",
        "skillsAgentSave",
        "skillsAgentRemove",
        "skillsLinkPlan",
        "skillsLinkApply",
        "skillsTrashList",
        "skillsHealth",
        "skillsExport",
        "skillsImportScan",
        "skillsImportPlan",
        "skillsImportApply",
        "skillsImportTrashList",
        "skillsImportUndo",
        "skillsImportTrashEmpty",
    ] {
        assert_eq!(plugins::tool_of(method), Some("skills"), "{method}");
        let request = json!({"id": "x", "confirmed": true});
        let error = crate::dispatch_with(&store, method, &request).unwrap_err();
        assert_eq!(error.to_string(), "plugin_disabled", "{method}");
    }
    // Nothing was written while it was off.
    assert!(!store.root().join("skills").exists());
    assert!(
        !plugins::catalog(&store)
            .unwrap()
            .iter()
            .any(|p| p.id == "skills" && p.enabled)
    );
    plugins::set_enabled(&store, "skills", true).unwrap();
    plugins::require(&store, "skills").unwrap();
}

#[test]
fn deleting_the_tool_data_removes_own_links_only() {
    let temp = tempfile::tempdir().unwrap();
    let root = temp.path().canonicalize().unwrap();
    let home = root.join("home");
    std::fs::create_dir_all(&home).unwrap();
    let store = Store::new(root.join("store")).unwrap();
    let call = |method: &str, request: Value| {
        super::super::dispatch_in(&store, &home, method, &request).unwrap()
    };
    call(
        "skillsCreate",
        json!({"id": "a", "group": "personal", "template": "blank", "name": "a", "description": "d"}),
    );
    let change =
        json!({"changes": [{"skill": "a", "agent": "claude", "on": true}], "confirmed": true});
    call("skillsLinkApply", change);
    let own = home.join(".claude/skills/a");
    assert!(own.symlink_metadata().unwrap().file_type().is_symlink());
    let foreign = home.join(".claude/skills/otra");
    std::fs::create_dir_all(&foreign).unwrap();
    assert!(crate::skills::has_data(&store));
    // The temporary home, never the owner's: Stack's own link goes, the foreign folder stays.
    crate::skills::delete_all_in(&store, &home).unwrap();
    assert!(!crate::skills::has_data(&store));
    assert!(own.symlink_metadata().is_err());
    assert!(foreign.is_dir());
}

/// An `index.json` that cannot be read does not stop the tool: it is set aside as `index.json.bad`,
/// the skills on disk are adopted again, and «Eliminar datos» still removes Stack's own links.
#[test]
fn an_unreadable_index_is_set_aside_and_deleting_the_data_still_removes_the_links() {
    let temp = tempfile::tempdir().unwrap();
    let root = temp.path().canonicalize().unwrap();
    let home = root.join("home");
    std::fs::create_dir_all(&home).unwrap();
    let store = Store::new(root.join("store")).unwrap();
    let call = |method: &str, request: Value| {
        super::super::dispatch_in(&store, &home, method, &request).unwrap()
    };
    call(
        "skillsCreate",
        json!({"id": "a", "group": "personal", "template": "blank", "name": "a", "description": "d"}),
    );
    call(
        "skillsLinkApply",
        json!({"changes": [{"skill": "a", "agent": "claude", "on": true}], "confirmed": true}),
    );
    let own = home.join(".claude/skills/a");
    assert!(own.symlink_metadata().unwrap().file_type().is_symlink());
    let index = store.root().join("skills/index.json");
    std::fs::write(&index, "{ esto no es JSON").unwrap();
    // The tool keeps working: the folder `a` is adopted from disk.
    let listed = call("skillsList", json!({}));
    assert!(listed.to_string().contains("\"a\""), "{listed}");
    assert!(store.root().join("skills/index.json.bad").is_file());
    // Damaged again, then «Eliminar datos»: the link Stack made goes with the data.
    std::fs::write(&index, "{ otra vez").unwrap();
    crate::skills::delete_all_in(&store, &home).unwrap();
    assert!(own.symlink_metadata().is_err());
    assert!(!crate::skills::has_data(&store));
}

/// When the index cannot be saved, delete and rename leave the disk, the links and the entry as
/// they were (a save that fails must not lose the group, the tags or the folder).
#[test]
fn a_failed_index_save_undoes_delete_and_rename() {
    use crate::skills::{index, model::Ctx};
    let temp = tempfile::tempdir().unwrap();
    let root = temp.path().canonicalize().unwrap();
    let home = root.join("home");
    std::fs::create_dir_all(&home).unwrap();
    let store = Store::new(root.join("store")).unwrap();
    let call = |method: &str, request: Value| {
        super::super::dispatch_in(&store, &home, method, &request).unwrap()
    };
    call(
        "skillsCreate",
        json!({"id": "a", "group": "trabajo", "template": "blank", "name": "a", "description": "d"}),
    );
    call(
        "skillsLinkApply",
        json!({"changes": [{"skill": "a", "agent": "claude", "on": true}], "confirmed": true}),
    );
    let ctx = Ctx::new(&store, &home).unwrap();
    let mut loaded = index::load(&ctx).unwrap();
    // A non-empty folder where `index.json` goes: the atomic rename over it fails.
    let file = store.root().join("skills/index.json");
    std::fs::remove_file(&file).unwrap();
    std::fs::create_dir_all(file.join("x")).unwrap();
    let link = home.join(".claude/skills/a");
    assert!(link.symlink_metadata().unwrap().file_type().is_symlink());

    assert!(super::super::delete(&ctx, &mut loaded, "a").is_err());
    assert!(loaded.skills.contains_key("a") && loaded.skills["a"].group == "trabajo");
    assert!(store.root().join("skills/a/SKILL.md").is_file());
    assert!(link.symlink_metadata().unwrap().file_type().is_symlink());

    assert!(super::super::rename(&ctx, &mut loaded, "a", "b").is_err());
    assert!(loaded.skills.contains_key("a") && !loaded.skills.contains_key("b"));
    assert!(store.root().join("skills/a/SKILL.md").is_file());
    assert!(!store.root().join("skills/b").exists());
    assert!(link.symlink_metadata().unwrap().file_type().is_symlink());
    assert_eq!(
        std::fs::read_link(&link).unwrap(),
        store.root().join("skills/a")
    );
}
