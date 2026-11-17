use super::*;
use std::fs;

/// A tool «installed» in the store the way `catalog::installed` reads it.
fn install(store: &Store, tool: &str, version: &str) {
    let dir = store.root().join("runtimes").join(tool).join(version);
    for executable in catalog::executables(tool) {
        let file = dir.join(executable);
        fs::create_dir_all(file.parent().unwrap()).unwrap();
        fs::write(file, "").unwrap();
    }
    let manifest = serde_json::json!({"tool": tool, "version": version, "url": "", "checksum_url": "",
        "sha256": "", "installed_at": 0});
    fs::write(
        dir.join("butake-manifest.json"),
        serde_json::to_vec(&manifest).unwrap(),
    )
    .unwrap();
}

fn record(folder: &std::path::Path, id: &str, extra: Value) -> Project {
    let mut value = serde_json::json!({
        "id": id, "name": format!("Proyecto {id}"), "path": folder, "domains": [format!("{id}.test")],
        "https": false, "kind": "astro", "runtime": {}, "docroot": ".", "services": [],
        "databases": [], "processes": []});
    for (key, field) in extra.as_object().unwrap() {
        value[key] = field.clone();
    }
    serde_json::from_value(value).unwrap()
}

fn items(store: &Store, id: &str) -> Vec<Attention> {
    let projects = store.list().unwrap();
    let project = projects.iter().find(|p| p.id == id).unwrap();
    of(store, &store.config().unwrap(), &projects, project)
}

fn setup() -> (tempfile::TempDir, Store) {
    let temp = tempfile::tempdir().unwrap();
    let store = Store::new(temp.path().join("store")).unwrap();
    (temp, store)
}

/// The real case: Node 22 fixed while `.nvmrc` asks for 24, and `npm run dev -- --port …` on a
/// `dev` that only calls `dev:local`. Each fix changes Stack's record and nothing of the project.
#[test]
fn a_badly_built_command_and_the_wrong_node_are_said_and_fixed() {
    let (temp, store) = setup();
    for version in ["22.23.5", "24.22.3", "26.1.0"] {
        install(&store, "node", version);
    }
    let folder = temp.path().join("web");
    fs::create_dir_all(&folder).unwrap();
    fs::write(folder.join(".nvmrc"), "24.13.0\n").unwrap();
    let package = r#"{"engines":{"node":">=22.12.0"},"scripts":{"dev":"npm run dev:local","dev:local":"astro dev"}}"#;
    fs::write(folder.join("package.json"), package).unwrap();
    let args = [
        "run",
        "dev",
        "--",
        "--host",
        "127.0.0.1",
        "--port",
        "{port}",
    ];
    store
        .save(record(
            &folder,
            "web",
            serde_json::json!({"runtime": {"node": "22"},
            "processes": [{"name": "dev", "program": "npm", "args": args, "autostart": true}]}),
        ))
        .unwrap();
    let found = items(&store, "web");
    let codes: Vec<&str> = found.iter().map(|i| i.code).collect();
    assert_eq!(codes, ["script_forwards", "node_mismatch"]);
    let node = &found[1];
    assert_eq!(node.current.as_deref(), Some("22.23.5"));
    assert_eq!(node.source, Some(".nvmrc"));
    assert_eq!(node.fix.as_ref().unwrap().value.as_deref(), Some("24"));
    assert_eq!(
        found[0].fix.as_ref().unwrap().value.as_deref(),
        Some("dev:local")
    );

    assert_eq!(
        apply(&store, "web", "otra", "").unwrap_err().to_string(),
        "unknown_fix"
    );
    let fixed = apply(&store, "web", "setNode", "").unwrap();
    assert_eq!(fixed.runtime["node"], "24");
    let fixed = apply(&store, "web", "useScript", "dev").unwrap();
    assert_eq!(
        fixed.processes[0].args,
        [
            "run",
            "dev:local",
            "--",
            "--host",
            "127.0.0.1",
            "--port",
            "{port}"
        ]
    );
    assert!(items(&store, "web").is_empty());
    assert_eq!(
        fs::read_to_string(folder.join(".nvmrc")).unwrap(),
        "24.13.0\n"
    );
    assert_eq!(
        fs::read_to_string(folder.join("package.json")).unwrap(),
        package
    );
}

/// A command whose script is not in `package.json`, or whose program is not installed.
#[test]
fn a_missing_script_or_program_is_said() {
    let (temp, store) = setup();
    install(&store, "node", "24.22.3");
    let folder = temp.path().join("app");
    fs::create_dir_all(folder.join("public")).unwrap();
    fs::write(folder.join("package.json"), r#"{"scripts":{"dev":"vite"}}"#).unwrap();
    store
        .save(record(
            &folder,
            "app",
            serde_json::json!({"kind": "php", "docroot": "public", "runtime": {"php": "8.4"}, "processes": [
                {"name": "web", "program": "npm", "args": ["run", "start"], "autostart": true},
                {"name": "queue", "program": "php", "args": ["artisan", "queue:work"], "autostart": false}]}),
        ))
        .unwrap();
    let found = items(&store, "app");
    assert_eq!(found[0].code, "script_missing");
    assert_eq!(found[0].script.as_deref(), Some("start"));
    assert_eq!(found[1].code, "program_missing");
    assert_eq!(found[1].program.as_deref(), Some("php"));
    assert!(found.iter().all(|i| i.fix.is_none()));
}

/// A project that is on and uses a service that is off: Stack offers to turn it on (and does);
/// one that is not installed is said without a fix; a project that is off says nothing.
#[test]
fn a_service_a_project_needs_is_said_and_turned_on() {
    let (temp, store) = setup();
    install(&store, "postgres", "16.16");
    let folder = temp.path().join("api");
    fs::create_dir_all(folder.join("public")).unwrap();
    store
        .save(record(
            &folder,
            "api",
            serde_json::json!({"kind": "static", "docroot": "public", "services": ["postgres", "redis"], "enabled": true}),
        ))
        .unwrap();
    let found = items(&store, "api");
    assert_eq!(
        found.iter().map(|i| i.code).collect::<Vec<_>>(),
        ["service_off", "service_missing"]
    );
    apply(&store, "api", "startService", "").unwrap();
    assert!(store.config().unwrap().engines["postgres"].enabled);
    assert_eq!(items(&store, "api")[0].code, "service_missing");
    let log = fs::read_to_string(store.root().join("logs/services.log")).unwrap();
    assert!(log.contains("\"actor\":\"project:api\""));
    let mut off = store.get("api").unwrap();
    off.enabled = false;
    store.save(off).unwrap();
    assert!(items(&store, "api").is_empty());
}

/// A static site whose served folder is a repository is said, and becomes a project without a
/// server keeping its domain; a port two records take (saved before the check) is said too.
#[test]
fn a_served_repository_and_a_shared_port_are_said() {
    let (temp, store) = setup();
    let folder = temp.path().join("libro");
    fs::create_dir_all(folder.join(".git")).unwrap();
    store
        .save(record(
            &folder,
            "libro",
            serde_json::json!({"kind": "static", "enabled": true}),
        ))
        .unwrap();
    assert_eq!(items(&store, "libro")[0].code, "serves_repository");
    let fixed = apply(&store, "libro", "makeUnserved", "").unwrap();
    assert_eq!(fixed.kind, ProjectKind::Unserved);
    assert!(!fixed.enabled);
    assert_eq!(fixed.domains, ["libro.test"]);
    assert!(items(&store, "libro").is_empty());

    for (id, port) in [("uno", 4176), ("dos", 4176)] {
        let folder = temp.path().join(id);
        fs::create_dir_all(&folder).unwrap();
        let p = record(
            &folder,
            id,
            serde_json::json!({"kind": "proxy", "upstream": port}),
        );
        fs::write(
            store.root().join(format!("projects/{id}.json")),
            serde_json::to_vec(&p).unwrap(),
        )
        .unwrap();
    }
    let found = items(&store, "uno");
    assert_eq!(found[0].code, "port_conflict");
    assert_eq!(found[0].port, Some(4176));
    assert_eq!(found[0].other.as_deref(), Some("Proyecto dos"));
}

/// A PHP or static site served from the project's own root is said (its files are all public);
/// one served from a subfolder is not.
#[test]
fn a_site_served_from_the_project_root_is_said() {
    let (temp, store) = setup();
    for (id, docroot, said) in [("raiz", ".", true), ("publico", "public", false)] {
        let folder = temp.path().join(id);
        fs::create_dir_all(folder.join("public")).unwrap();
        store
            .save(record(
                &folder,
                id,
                serde_json::json!({"kind": "php", "docroot": docroot, "enabled": false}),
            ))
            .unwrap();
        let codes: Vec<_> = items(&store, id).iter().map(|i| i.code).collect();
        assert_eq!(codes.contains(&"serves_project_root"), said, "{id}");
    }
}
