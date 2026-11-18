//! The tool through the engine's dispatch, as the app calls it: off, every `git*` method answers
//! `plugin_disabled` and the base stays the same; on, the methods work, ask for confirmations and
//! keep the tool's own data under Stack's store.
use super::sandbox;
use crate::core::store::Store;
use crate::git::{GitError, METHODS};
use serde_json::{Value, json};

fn store() -> (tempfile::TempDir, Store) {
    let temp = tempfile::tempdir().unwrap();
    let store = Store::new(temp.path().join("store")).unwrap();
    (temp, store)
}

fn call(store: &Store, request: Value) -> anyhow::Result<Value> {
    let method = request["method"].as_str().unwrap_or("").to_string();
    crate::dispatch_with(store, &method, &request)
}

fn code(result: anyhow::Result<Value>) -> String {
    let error = result.unwrap_err();
    match error.downcast_ref::<GitError>() {
        Some(failure) => failure.code.clone(),
        None => error.to_string(),
    }
}

#[test]
fn every_method_answers_plugin_disabled_while_the_tool_is_off() {
    let (_temp, store) = store();
    let repository = tempfile::tempdir().unwrap();
    for method in METHODS {
        let request = json!({"method": method, "path": repository.path(), "confirmed": true});
        assert_eq!(code(call(&store, request)), "plugin_disabled", "{method}");
    }
    // Nothing of the tool was written to the store.
    assert!(!store.root().join("config/git").exists());
    // The base is the same: its `gitStatus` and the catalog answer as before.
    assert_eq!(
        call(&store, json!({"method": "gitStatus"})).unwrap(),
        json!({})
    );
    let catalog = call(&store, json!({"method": "pluginCatalog"})).unwrap();
    assert!(
        catalog
            .as_array()
            .unwrap()
            .iter()
            .any(|p| p["id"] == "git" && p["enabled"] == false)
    );
}

#[test]
fn methods_work_once_the_tool_is_on_and_keep_their_confirmations() {
    let (_temp, store) = store();
    crate::app::plugins::set_enabled(&store, "git", true).unwrap();
    let temp = tempfile::tempdir().unwrap();
    let parent = temp.path().canonicalize().unwrap();
    let root = parent.join("nuevo");
    let path = root.to_string_lossy().to_string();
    let created = call(
        &store,
        json!({"method": "gitInit", "path": parent, "name": "nuevo", "develop": true}),
    )
    .unwrap();
    assert_eq!(created, json!(path));
    std::fs::write(root.join("nuevo.txt"), "x\n").unwrap();
    let changes = call(&store, json!({"method": "gitChanges", "path": path})).unwrap();
    assert_eq!(changes[0]["path"], "nuevo.txt");
    assert_eq!(changes[0]["index"], "?");
    // Confirmations are checked by the dispatch, before Git runs.
    for (method, extra) in [
        (
            "gitPublish",
            json!({"url": "https://example.invalid/a.git"}),
        ),
        ("gitRewriteApply", json!({"plan": {}})),
        ("gitRewriteUndo", json!({"backup": "x"})),
        ("gitCopyCommits", json!({"target": "main", "hashes": []})),
        ("gitSetMainProtection", json!({"value": "true"})),
        ("gitResolveConflict", json!({"file": "nuevo.txt"})),
        ("gitRun", json!({"command": "status", "arguments": ""})),
        ("gitAction", json!({"action": "push"})),
    ] {
        let mut request = extra.clone();
        request["method"] = json!(method);
        request["path"] = json!(path);
        assert_eq!(
            code(call(&store, request)),
            "confirmation_required",
            "{method}"
        );
    }
    let output = call(
        &store,
        json!({"method": "gitRun", "path": path, "command": "status", "arguments": "--short", "confirmed": true}),
    )
    .unwrap();
    assert!(output.as_str().unwrap().contains("nuevo.txt"));
    let preview = call(
        &store,
        json!({"method": "gitPrepare", "path": path, "command": "push", "arguments": "--force origin x"}),
    );
    assert_eq!(code(preview), "protected_branch");
    assert_eq!(
        code(call(
            &store,
            json!({"method": "gitQuery", "path": path, "args": ["tag", "nueva"]})
        )),
        "invalid_query"
    );
    assert_eq!(
        code(call(
            &store,
            json!({"method": "gitChanges", "path": "/no/existe"})
        )),
        "invalid_path"
    );
    // Methods without a caller were removed (R-1): they are unknown now, not answered.
    for method in [
        "gitCloneName",
        "gitPullRequestUrl",
        "gitFiles",
        "gitBranchDiff",
        "gitPreviewFile",
        "gitSaveFile",
    ] {
        assert!(!crate::git::is_method(method), "{method}");
        assert_eq!(
            code(call(&store, json!({"method": method, "path": path}))),
            "unknown_method",
            "{method}"
        );
    }
    // The base still answers its own `gitStatus`, unaffected by the tool.
    assert_eq!(
        call(&store, json!({"method": "gitStatus"})).unwrap(),
        json!({})
    );
}

#[test]
fn repositories_are_remembered_under_the_store_without_credentials() {
    let (_temp, store) = store();
    crate::app::plugins::set_enabled(&store, "git", true).unwrap();
    let temp = super::super::block(sandbox());
    let root = temp.path().canonicalize().unwrap();
    super::super::block(crate::git::runner::git(
        &root,
        &[
            "remote",
            "add",
            "origin",
            "https://user:hunter2hunter2@bitbucket.org/equipo/app.git",
        ],
    ))
    .unwrap();
    std::fs::create_dir(root.join("sub")).unwrap();
    // Added from a subfolder: the repository's top folder is kept.
    let listed = call(
        &store,
        json!({"method": "gitRepositoryAdd", "path": root.join("sub")}),
    )
    .unwrap();
    assert_eq!(listed["added"][0]["path"], json!(root));
    assert_eq!(listed["added"][0]["missing"], false);
    let opened = call(&store, json!({"method": "gitOpen", "path": root})).unwrap();
    assert_eq!(opened["remote"], "https://bitbucket.org/equipo/app.git");
    let listed = call(&store, json!({"method": "gitRepositories"})).unwrap();
    assert_eq!(listed["recent"][0]["path"], json!(root));
    let saved = std::fs::read_to_string(store.root().join("config/git/repositories.json")).unwrap();
    assert!(!saved.contains("hunter2"));
    let remotes = call(
        &store,
        json!({"method": "gitQuery", "path": root, "args": ["remote", "-v"]}),
    )
    .unwrap();
    assert!(!remotes.as_str().unwrap().contains("hunter2"));
    // A folder outside any repository is refused; forgetting never touches the folder.
    let outside = tempfile::tempdir().unwrap();
    assert!(
        call(
            &store,
            json!({"method": "gitRepositoryAdd", "path": outside.path()})
        )
        .is_err()
    );
    let listed = call(
        &store,
        json!({"method": "gitRepositoryForget", "path": root}),
    )
    .unwrap();
    assert!(listed["added"].as_array().unwrap().is_empty());
    assert!(listed["recent"].as_array().unwrap().is_empty());
    assert!(root.join(".git").exists());
}
