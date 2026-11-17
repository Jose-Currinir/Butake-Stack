use crate::app::plugins;
use crate::core::store::Store;
use serde_json::{json, Value};

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
    assert!(!plugins::catalog(&store)
        .unwrap()
        .iter()
        .any(|p| p.id == "skills" && p.enabled));
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
