use super::*;
use crate::core::{journal::FAIL_AT, store::SiteGroup};
use std::collections::BTreeMap;

fn folder(root: &Path, name: &str) -> PathBuf {
    let path = root.join("projects-qa").join(name);
    fs::create_dir_all(&path).unwrap();
    path
}

fn project(root: &Path, id: &str, kind: &str, env: Value, args: Vec<&str>) -> Project {
    serde_json::from_value(json!({
        "id": id, "name": id, "path": folder(root, id), "domains": [format!("{id}.test")],
        "https": false, "kind": kind, "runtime": {}, "docroot": ".", "services": [],
        "databases": ["base_qa"], "processes": [{"name": "web", "program": "npm", "args": args, "autostart": true}],
        "env": env}))
    .unwrap()
}

/// Every file of the store, by path, with its bytes (the lock file aside).
fn snapshot(store: &Store) -> BTreeMap<PathBuf, Vec<u8>> {
    fn walk(dir: &Path, root: &Path, out: &mut BTreeMap<PathBuf, Vec<u8>>) {
        for entry in fs::read_dir(dir).unwrap().flatten() {
            let path = entry.path();
            if path.is_dir() {
                walk(&path, root, out);
            } else if path.file_name().is_some_and(|n| n != "settings.lock") {
                out.insert(
                    path.strip_prefix(root).unwrap().into(),
                    fs::read(&path).unwrap(),
                );
            }
        }
    }
    let mut out = BTreeMap::new();
    walk(store.root(), store.root(), &mut out);
    out
}

/// A store with a project `api` that every place of the table depends on.
fn fixture() -> (tempfile::TempDir, Store) {
    let temp = tempfile::tempdir().unwrap();
    let store = Store::new(temp.path().join("store")).unwrap();
    let mut api = project(temp.path(), "api", "kmp", json!({}), vec!["run", "dev"]);
    api.enabled = true;
    let api = store.save(api).unwrap();
    assert!(api.upstream.is_some());
    store
        .save(project(temp.path(), "apix", "kmp", json!({}), vec![]))
        .unwrap();
    store
        .save(project(
            temp.path(),
            "worker",
            "kmp",
            json!({"API": "http://127.0.0.1:{port:api}", "OTRO": "{port:apix}"}),
            vec!["--api={public:api}"],
        ))
        .unwrap();
    store
        .save(project(temp.path(), "web", "static", json!({}), vec![]))
        .unwrap();
    store
        .save_groups(vec![SiteGroup {
            id: "salud".into(),
            name: "Salud".into(),
            sites: vec!["api".into(), "web".into()],
            kind: SiteGroup::PROJECT.into(),
            ordered: true,
            ..Default::default()
        }])
        .unwrap();
    let envs = store.directory("envs").unwrap();
    crate::core::json::write(
        &envs.join("api.json"),
        &json!({"active": "local", "environments": [{"id": "local", "name": "Local", "kind": "local",
            "entries": [{"key": "TOKEN", "value": "", "secret": true}]}], "passToProcesses": true}),
    )
    .unwrap();
    crate::core::json::write(
        &envs.join("web.json"),
        &json!({"active": "local", "environments": [{"id": "local", "name": "Local", "kind": "local",
            "entries": [{"key": "API", "value": "http://127.0.0.1:{port:api}", "secret": false},
                        {"key": "PUBLICA", "value": "{public:api}/v1", "secret": false}]}],
            "passToProcesses": true, "outdated": ["api"]}),
    )
    .unwrap();
    let tunnels = store.directory("tunnels").unwrap();
    crate::core::json::write(
        &tunnels.join("addresses.json"),
        &json!({"zone": "ejemplo.test", "addresses": {"api": {"hostname": "api-qa.ejemplo.dev",
            "tunnel": "00000000-0000-0000-0000-000000000001", "zone": "ejemplo.dev"}}}),
    )
    .unwrap();
    fs::write(tunnels.join("api.json"), "{\"credencial\":\"ficticia\"}").unwrap();
    fs::write(tunnels.join("api.yml"), "tunnel: x\n").unwrap();
    let logs = store.directory("logs").unwrap();
    for name in [
        "api.web.log",
        "api.web.log.1",
        "python-api.log",
        "task-api.log",
        "env-api.log",
        "apix.web.log",
        "api-v2.web.log",
        "stack.caddy.log",
    ] {
        fs::write(logs.join(name), name).unwrap();
    }
    crate::web::projects::envs::audit(&store, "api", "local", "guardar", "", "qa").unwrap();
    crate::web::projects::envs::audit(&store, "web", "local", "guardar", "", "qa").unwrap();
    fs::create_dir_all(store.root().join("vault")).unwrap();
    (temp, store)
}

fn options() -> RenameOptions {
    RenameOptions {
        name: Some("Backend".into()),
        domain: true,
        keychain_moved: false,
        actor: "qa".into(),
    }
}

/// Every place of the table follows the new id; nothing stays under the old one.
#[test]
fn a_rename_reaches_every_place() {
    let (_temp, store) = fixture();
    let port = store.get("api").unwrap().upstream;
    let out = rename_project(&store, "api", "backend", &options()).unwrap();
    assert_eq!(out["restarted"], true);
    assert_eq!(out["pending"], json!(["keychain", "vault", "app"]));
    // Record: new id, title and domain; same folder, port and databases; on again.
    assert!(store.record("api").is_err());
    let backend = store.get("backend").unwrap();
    assert_eq!(backend.name, "Backend");
    assert_eq!(backend.domains, vec!["backend.test".to_string()]);
    assert_eq!(backend.upstream, port);
    assert_eq!(backend.databases, vec!["base_qa".to_string()]);
    assert!(backend.enabled);
    assert!(backend.path.ends_with("projects-qa/api"));
    // Markers of other projects: env and arguments; a marker of another project stays.
    let worker = store.get("worker").unwrap();
    assert_eq!(worker.env["API"], "http://127.0.0.1:{port:backend}");
    assert_eq!(worker.env["OTRO"], "{port:apix}");
    assert_eq!(worker.processes[0].args, vec!["--api={public:backend}"]);
    // Its place among the parts, in order.
    assert_eq!(store.groups().unwrap()[0].sites, ["backend", "web"]);
    // Environments: its own, and markers and `outdated` of the others.
    let envs = store.root().join("envs");
    assert!(!envs.join("api.json").exists() && envs.join("backend.json").exists());
    let web = crate::web::projects::envs::load(&store, "web").unwrap();
    assert_eq!(
        web.environments[0].entries[0].value,
        "http://127.0.0.1:{port:backend}"
    );
    assert_eq!(web.environments[0].entries[1].value, "{public:backend}/v1");
    assert_eq!(web.outdated, ["backend"]);
    // Fixed address and credentials; the run configuration is written again later.
    let tunnels = store.root().join("tunnels");
    assert_eq!(
        crate::web::net::tunnels::address(&store, "backend")
            .unwrap()
            .hostname,
        "api-qa.ejemplo.dev"
    );
    assert!(crate::web::net::tunnels::address(&store, "api").is_none());
    assert!(tunnels.join("backend.json").exists() && !tunnels.join("api.json").exists());
    assert!(!tunnels.join("api.yml").exists());
    // Logs: its own move; another project's with a similar name stay.
    let logs = store.root().join("logs");
    for name in [
        "backend.web.log",
        "backend.web.log.1",
        "python-backend.log",
        "task-backend.log",
        "env-backend.log",
        "apix.web.log",
        "api-v2.web.log",
        "stack.caddy.log",
    ] {
        assert!(logs.join(name).exists(), "{name}");
    }
    assert!(!logs.join("api.web.log").exists());
    // Audit history follows it, with the rename on top.
    let history = crate::web::projects::envs::audit_lines(&store, "backend").unwrap();
    assert_eq!(history[0]["action"], "renombrar");
    assert!(history.iter().any(|l| l["action"] == "guardar"));
    assert!(crate::web::projects::envs::audit_lines(&store, "api")
        .unwrap()
        .is_empty());
    // What the app finishes.
    let pending = pending(&store).unwrap();
    assert_eq!(
        (pending[0].from.as_str(), pending[0].to.as_str()),
        ("api", "backend")
    );
    step_done(&store, "api", "backend", "keychain").unwrap();
    step_done(&store, "api", "backend", "vault").unwrap();
    assert!(step_done(&store, "api", "backend", "otro").is_err());
    assert!(step_done(&store, "api", "backend", "app")
        .unwrap()
        .is_empty());
}

/// Without `domain` every domain stays; without a vault or environments there is no step for
/// them; the app that moved the Keychain says so.
#[test]
fn a_rename_keeps_the_domain_unless_asked() {
    let (_temp, store) = fixture();
    fs::remove_dir_all(store.root().join("vault")).unwrap();
    let out = rename_project(
        &store,
        "api",
        "backend",
        &RenameOptions {
            keychain_moved: true,
            ..Default::default()
        },
    )
    .unwrap();
    assert_eq!(out["pending"], json!(["app"]));
    let backend = store.get("backend").unwrap();
    assert_eq!(backend.domains, vec!["api.test".to_string()]);
    assert_eq!(backend.name, "api");
    let out = rename_project(&store, "web", "sitio", &RenameOptions::default()).unwrap();
    assert_eq!(out["pending"], json!(["keychain", "app"]));
}

/// A failure at any step leaves every file exactly as it was, and the project on.
#[test]
fn a_failed_rename_changes_nothing() {
    let (_temp, store) = fixture();
    let before = snapshot(&store);
    let mut step = 1;
    loop {
        FAIL_AT.with(|fail| fail.set(Some(step)));
        let result = rename_project(&store, "api", "backend", &options());
        FAIL_AT.with(|fail| fail.set(None));
        if result.is_ok() {
            break;
        }
        assert_eq!(result.unwrap_err().to_string(), "journal_test_failure");
        assert_eq!(snapshot(&store), before, "step {step}");
        assert!(store.get("api").unwrap().enabled);
        step += 1;
    }
    assert!(step > 10, "every place was tried ({step} steps)");
    assert!(store.get("backend").is_ok());
}

#[test]
fn a_rename_is_refused_when_it_cannot_be_whole() {
    let (temp, store) = fixture();
    let before = snapshot(&store);
    let refused = |to: &str| {
        rename_project(&store, "api", to, &options())
            .unwrap_err()
            .to_string()
    };
    assert_eq!(refused("api"), "same_id");
    assert_eq!(refused("Mal Id"), "invalid_new_id");
    assert_eq!(refused("../x"), "invalid_new_id");
    assert_eq!(refused("web"), "id_in_use");
    // Left over under the new id: environments or a tunnel of a project removed by hand.
    crate::core::json::write(&store.root().join("envs/viejo.json"), &json!({})).unwrap();
    assert_eq!(refused("viejo"), "id_in_use");
    fs::write(store.root().join("tunnels/otro.json"), "{}").unwrap();
    assert_eq!(refused("otro"), "id_in_use");
    fs::remove_file(store.root().join("envs/viejo.json")).unwrap();
    fs::remove_file(store.root().join("tunnels/otro.json")).unwrap();
    // The new domain would be another project's.
    let mut taken = project(temp.path(), "tomado", "static", json!({}), vec![]);
    taken.domains = vec!["nuevo.test".into()];
    store.save(taken).unwrap();
    let before_taken = snapshot(&store);
    assert_eq!(refused("nuevo"), "domain_in_use");
    assert_eq!(snapshot(&store), before_taken);
    store.delete("tomado").unwrap();
    assert_eq!(snapshot(&store), before);
    assert_eq!(
        rename_project(&store, "nadie", "alguien", &options())
            .unwrap_err()
            .to_string(),
        "unknown_project"
    );
}

/// A project whose folder is gone can be renamed (it keeps being missing until found).
#[test]
fn a_missing_project_can_be_renamed() {
    let (temp, store) = fixture();
    fs::remove_dir_all(temp.path().join("projects-qa/web")).unwrap();
    rename_project(&store, "web", "portal", &options()).unwrap();
    let portal = store.record("portal").unwrap();
    assert_eq!(portal.domains, vec!["portal.test".to_string()]);
    assert!(store
        .folder_missing()
        .unwrap()
        .iter()
        .any(|p| p.id == "portal"));
    assert_eq!(store.groups().unwrap()[0].sites, ["api", "portal"]);
}

#[test]
fn log_names_follow_the_project_only() {
    assert_eq!(
        renamed_log("api.web.log.2", "api", "b").as_deref(),
        Some("b.web.log.2")
    );
    assert_eq!(
        renamed_log("api.logger.log", "api", "b").as_deref(),
        Some("b.logger.log")
    );
    assert_eq!(
        renamed_log("env-api.log", "api", "b").as_deref(),
        Some("env-b.log")
    );
    for other in [
        "apix.web.log",
        "api-v2.web.log",
        "api.web.txt",
        "api.web.log.x",
        "env-apix.log",
        "api.log",
    ] {
        assert_eq!(renamed_log(other, "api", "b"), None, "{other}");
    }
}

/// Moving points the project at another folder: nothing is copied, the Git tool's recent entry
/// follows it, the project is started again there, and a failure changes nothing.
#[test]
fn a_move_points_at_the_new_folder() {
    let (temp, store) = fixture();
    let old = store.get("api").unwrap().path;
    let new = folder(temp.path(), "api-copia").canonicalize().unwrap();
    fs::write(old.join("archivo.txt"), "se queda").unwrap();
    let git = store.directory("config").unwrap().join("git");
    fs::create_dir_all(&git).unwrap();
    crate::core::json::write(
        &git.join("repositories.json"),
        &json!({"added": [{"path": new, "at": 1}], "recent": [{"path": old, "at": 2}]}),
    )
    .unwrap();
    let before = snapshot(&store);
    let mut step = 1;
    let out = loop {
        FAIL_AT.with(|fail| fail.set(Some(step)));
        let result = move_project(&store, "api", &new);
        FAIL_AT.with(|fail| fail.set(None));
        match result {
            Ok(out) => break out,
            Err(_) => assert_eq!(snapshot(&store), before, "step {step}"),
        }
        step += 1;
    };
    assert!(step > 2);
    assert_eq!(out["restarted"], true);
    assert_eq!(
        out["envReapply"], true,
        "the active environment's .env is not there yet"
    );
    let api = store.get("api").unwrap();
    assert_eq!(api.path, new.canonicalize().unwrap());
    assert!(api.enabled);
    assert!(!new.join("archivo.txt").exists() && old.join("archivo.txt").exists());
    let saved = crate::git::repositories::load(&store).unwrap();
    assert!(saved.added.is_empty());
    assert_eq!(saved.recent[0].path, new.canonicalize().unwrap());
    // Refused: the same folder, another project's, one that is not there, a relative path.
    let refused = |path: &Path| move_project(&store, "api", path).unwrap_err().to_string();
    assert_eq!(refused(&new), "same_folder");
    assert_eq!(refused(&store.get("web").unwrap().path), "folder_in_use");
    assert_eq!(refused(&temp.path().join("no-existe")), "invalid_path");
    assert_eq!(refused(Path::new("relativa")), "invalid_path");
}
