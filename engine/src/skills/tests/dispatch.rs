use crate::app::plugins;
use crate::core::store::Store;
use serde_json::json;

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
    let home = temp.path().join("home");
    std::fs::create_dir_all(&home).unwrap();
    let store = Store::new(temp.path().join("store")).unwrap();
    let request = json!({"id": "a", "group": "personal", "template": "blank", "name": "a", "description": "d"});
    super::super::dispatch_in(&store, &home, "skillsCreate", &request).unwrap();
    assert!(crate::skills::has_data(&store));
    // `delete_all` reads the real home, which the test must not touch: it still cleans the folders.
    crate::skills::delete_all(&store).unwrap();
    assert!(!crate::skills::has_data(&store));
}
