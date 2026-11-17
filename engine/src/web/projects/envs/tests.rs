use super::*;
use std::process::Command;

/// A new port of a project reaches the `.env` of the projects that name it: written again
/// without secrets, marked outdated with them (the app holds them) and when the project is
/// gone; a save never clears the mark, activating does.
#[test]
fn port_changes_reach_the_env_of_projects_that_name_it() {
    let (temp, store, _) = store_with_site();
    let folder = |name: &str| {
        let path = temp.path().join(name);
        fs::create_dir_all(&path).unwrap();
        path
    };
    let kmp = |id: &str, env: serde_json::Value| -> Project {
        serde_json::from_value(serde_json::json!({
                "id": id, "name": id, "path": folder(id), "domains": [format!("{id}.test")],
                "https": false, "kind": "kmp", "runtime": {}, "docroot": ".", "services": [],
                "databases": [], "processes": [], "env": env}))
        .unwrap()
    };
    let mut api = store.save(kmp("api", serde_json::json!({}))).unwrap();
    store
        .save(kmp("worker", serde_json::json!({"API": "{port:api}"})))
        .unwrap();
    let web = store.save(kmp("web", serde_json::json!({}))).unwrap();
    let with = |secret: bool| SiteEnvironments {
        active: None,
        environments: vec![Environment {
            id: "local".into(),
            name: "Local".into(),
            kind: Kind::Local,
            entries: vec![
                Entry {
                    key: "API_URL".into(),
                    value: "http://127.0.0.1:{port:api}".into(),
                    secret: false,
                },
                Entry {
                    key: "TOKEN".into(),
                    value: String::new(),
                    secret,
                },
            ],
        }],
        pass_to_processes: true,
        outdated: vec![],
    };
    // web: no secrets; demo: a secret.
    save(&store, "web", &with(false), "qa").unwrap();
    activate(&store, "web", "local", &BTreeMap::new(), false, "qa").unwrap();
    save(&store, "demo", &with(true), "qa").unwrap();
    let sentinel = BTreeMap::from([("TOKEN".to_string(), "centinela-p31".to_string())]);
    activate(&store, "demo", "local", &sentinel, false, "qa").unwrap();
    let mut dependents = port_dependents(&store, "api").unwrap();
    dependents.sort();
    assert_eq!(dependents, ["demo", "web", "worker"]);

    api.upstream = Some(api.upstream.unwrap() + 7);
    let port = api.upstream.unwrap();
    store.save(api).unwrap();
    let mut refreshed = refresh_port_dependents(&store, "api", "qa").unwrap();
    refreshed.sort_by(|a, b| a.id.cmp(&b.id));
    assert_eq!(
        refreshed
            .iter()
            .map(|r| (r.id.as_str(), r.state))
            .collect::<Vec<_>>(),
        [
            ("demo", "outdated"),
            ("web", "rewritten"),
            ("worker", "processes")
        ]
    );
    let written = read_stack_dotenv(&web.path.join(".env")).unwrap();
    assert_eq!(written["API_URL"], format!("http://127.0.0.1:{port}"));
    assert!(load(&store, "web").unwrap().outdated.is_empty());
    // The secret stays as it was: the engine never had it to write again.
    let demo = store.get("demo").unwrap();
    assert_eq!(
        read_stack_dotenv(&demo.path.join(".env")).unwrap()["TOKEN"],
        "centinela-p31"
    );
    assert_eq!(load(&store, "demo").unwrap().outdated, ["api"]);
    // A save from the app keeps the mark; activating with the Keychain clears it.
    save(&store, "demo", &with(true), "qa").unwrap();
    assert_eq!(load(&store, "demo").unwrap().outdated, ["api"]);
    activate(&store, "demo", "local", &sentinel, false, "qa").unwrap();
    assert!(load(&store, "demo").unwrap().outdated.is_empty());
    // The project is gone: the `.env` stays and says why.
    store.delete("api").unwrap();
    let refreshed = refresh_port_dependents(&store, "api", "qa").unwrap();
    assert!(
        refreshed
            .iter()
            .any(|r| r.id == "web" && r.state == "missing")
    );
    assert_eq!(load(&store, "web").unwrap().outdated, ["api"]);
    let audit = fs::read_to_string(store.directory("logs").unwrap().join("env-audit.log")).unwrap();
    assert!(audit.contains("\"actualizar\"") && !audit.contains("centinela"));
}

fn store_with_site() -> (tempfile::TempDir, Store, Project) {
    let temp = tempfile::tempdir().unwrap();
    let store = Store::new(temp.path().join("store")).unwrap();
    let site = temp.path().join("site");
    fs::create_dir_all(site.join("public")).unwrap();
    let project: Project = serde_json::from_value(serde_json::json!({
            "id":"demo","name":"Demo","path":site,"domains":["demo.test"],"https":true,
            "kind":"php","runtime":{},"docroot":"public","services":[],"databases":[],"processes":[]})).unwrap();
    let project = store.save(project).unwrap();
    (temp, store, project)
}

fn sample() -> SiteEnvironments {
    SiteEnvironments {
        active: None,
        environments: vec![
            Environment {
                id: "local".into(),
                name: "Local".into(),
                kind: Kind::Local,
                entries: vec![
                    Entry {
                        key: "APP_ENV".into(),
                        value: "local".into(),
                        secret: false,
                    },
                    Entry {
                        key: "DB_PASSWORD".into(),
                        value: String::new(),
                        secret: true,
                    },
                ],
            },
            Environment {
                id: "produccion".into(),
                name: "Producción".into(),
                kind: Kind::Production,
                entries: vec![Entry {
                    key: "APP_ENV".into(),
                    value: "production".into(),
                    secret: false,
                }],
            },
        ],
        pass_to_processes: true,
        outdated: vec![],
    }
}

/// The active environment reaches the processes only when on, active and written by Stack;
/// `{port:<id>}` is checked when saving and filled in the `.env`; values round-trip.
#[test]
fn active_environment_for_processes_and_project_ports() {
    let (temp, store, project) = store_with_site();
    let api = temp.path().join("api");
    fs::create_dir_all(&api).unwrap();
    let backend: Project = serde_json::from_value(serde_json::json!({
            "id":"api","name":"API","path":api,"domains":["api.test"],"https":false,
            "kind":"kmp","runtime":{},"docroot":".","services":[],"databases":[],"processes":[]}))
    .unwrap();
    let port = store.save(backend).unwrap().upstream.unwrap();
    let mut site = sample();
    site.environments[0].entries.push(Entry {
        key: "API_URL".into(),
        value: "http://127.0.0.1:{port:api}/v1".into(),
        secret: false,
    });
    let mut wrong = site.clone();
    wrong.environments[0].entries[2].value = "{port:nadie}".into();
    assert_eq!(
        save(&store, "demo", &wrong, "qa").unwrap_err().to_string(),
        "unknown_port_project"
    );
    save(&store, "demo", &site, "qa").unwrap();
    // Nothing active yet: no file for the processes.
    assert!(process_env_file(&store, &project).is_none());
    let sentinel = "centinela-91c2-no-registrar";
    let secrets = BTreeMap::from([("DB_PASSWORD".to_string(), format!("{sentinel} $x\"y"))]);
    activate(&store, "demo", "local", &secrets, false, "qa").unwrap();
    let file = process_env_file(&store, &project).unwrap();
    let values = read_stack_dotenv(&file).unwrap();
    assert_eq!(values["API_URL"], format!("http://127.0.0.1:{port}/v1"));
    assert_eq!(values["DB_PASSWORD"], format!("{sentinel} $x\"y"));
    assert_eq!(values["APP_ENV"], "local");
    // Turned off: nothing passes, and the setting survives a save.
    let mut off = load(&store, "demo").unwrap();
    off.pass_to_processes = false;
    save(&store, "demo", &off, "qa").unwrap();
    assert!(process_env_file(&store, &project).is_none());
    assert!(!load(&store, "demo").unwrap().pass_to_processes);
    // An old store without the field reads as on.
    let old: SiteEnvironments =
        serde_json::from_str(r#"{"active":null,"environments":[]}"#).unwrap();
    assert!(old.pass_to_processes);
    // A `.env` written by hand is not Stack's: never passed.
    fs::write(&file, "API_URL=x\n").unwrap();
    assert!(read_stack_dotenv(&file).is_none());
    // No value in the store, the audit log or any log of Stack.
    for dir in ["envs", "logs"] {
        for entry in fs::read_dir(store.root().join(dir)).unwrap() {
            let text = fs::read_to_string(entry.unwrap().path()).unwrap_or_default();
            assert!(!text.contains(sentinel));
        }
    }
    // `${KEY}` inside double quotes takes an earlier key; unknown ones stay as written.
    let parsed = parse_dotenv("A=uno\nB=\"${A}-${Z}\"\nC='${A}'\nD=x # nota\n");
    assert_eq!(parsed["B"], "uno-${Z}");
    assert_eq!(parsed["C"], "${A}");
    assert_eq!(parsed["D"], "x");
}

/// `{public:<id>}` (P-35): a project that does not exist fails when saving; one without a fixed
/// address leaves the variable out of the `.env` and the environment says it is pending; once
/// the address exists the `.env` is written again with it.
#[test]
fn public_addresses_fill_or_stay_pending() {
    let (temp, store, project) = store_with_site();
    let salud = temp.path().join("salud");
    fs::create_dir_all(&salud).unwrap();
    store
            .save(
                serde_json::from_value(serde_json::json!({
                "id":"salud","name":"Salud","path":salud,"domains":["salud.test"],"https":false,
                "kind":"static","runtime":{},"docroot":".","services":[],"databases":[],"processes":[]}))
                .unwrap(),
            )
            .unwrap();
    let mut site = sample();
    site.environments[0].entries.push(Entry {
        key: "APP_URL".into(),
        value: "{public:salud}".into(),
        secret: false,
    });
    let mut wrong = site.clone();
    wrong.environments[0].entries[2].value = "{public:nadie}/x".into();
    assert_eq!(
        save(&store, "demo", &wrong, "qa").unwrap_err().to_string(),
        "unknown_public_project"
    );
    // No secrets in this one, so the engine can write it again by itself.
    site.environments[0].entries.remove(1);
    save(&store, "demo", &site, "qa").unwrap();
    activate(&store, "demo", "local", &BTreeMap::new(), false, "qa").unwrap();
    let file = project.path.join(".env");
    let values = read_stack_dotenv(&file).unwrap();
    assert!(!values.contains_key("APP_URL"));
    assert_eq!(values["APP_ENV"], "local");
    assert_eq!(public_pending(&store, "demo"), ["salud"]);
    assert_eq!(port_dependents(&store, "salud").unwrap(), ["demo"]);
    json::write(
        &store.directory("tunnels").unwrap().join("addresses.json"),
        &serde_json::json!({"addresses": {"salud": {"hostname": "salud-test.example.com",
                "tunnel": "6f1c2a4e-0b7d-4c55-9a0e-3b2f1d9c8e71", "zone": "example.com"}}}),
    )
    .unwrap();
    let refreshed = refresh_port_dependents(&store, "salud", "qa").unwrap();
    assert_eq!(refreshed[0].state, "rewritten");
    let values = read_stack_dotenv(&file).unwrap();
    assert_eq!(values["APP_URL"], "https://salud-test.example.com");
    assert!(public_pending(&store, "demo").is_empty());
}

#[test]
fn classifies_quotes_and_validates() {
    assert!(looks_secret("DB_PASSWORD") && looks_secret("APP_KEY") && looks_secret("stripe_token"));
    assert!(!looks_secret("APP_ENV") && !looks_secret("DB_HOST"));
    assert_eq!(line("A", "simple-1.2"), "A=simple-1.2");
    assert_eq!(
        line("A", "con espacio \"x\""),
        "A=\"con espacio \\\"x\\\"\""
    );
    assert_eq!(line("A", "${APP_NAME}"), "A=\"${APP_NAME}\"");
    assert_eq!(line("A", "pa$$word"), "A='pa$$word'");
    assert_eq!(line("A", "it's $5"), "A=\"it's \\$5\"");
    for bad in ["", "1A", "A B", "A=B", &"K".repeat(129)] {
        assert!(validate_key(bad).is_err());
    }
    let mut site = sample();
    site.environments[0].entries[1].value = "filtrado".into();
    assert!(
        validate(&site).is_err(),
        "a secret value must never reach the store"
    );
}

#[test]
fn activation_writes_private_env_without_leaking_and_locks_production() {
    let (_temp, store, project) = store_with_site();
    save(&store, "demo", &sample(), "tester").unwrap();
    let stored = fs::read_to_string(store.root().join("envs/demo.json")).unwrap();
    let secrets: BTreeMap<String, String> =
        [("DB_PASSWORD".to_string(), "valor-ficticio".to_string())].into();
    let site = activate(&store, "demo", "local", &secrets, false, "tester").unwrap();
    assert_eq!(site.active.as_deref(), Some("local"));
    let written = fs::read_to_string(env_path(&project)).unwrap();
    assert!(written.contains("DB_PASSWORD=valor-ficticio") && written.contains("APP_ENV=local"));
    use std::os::unix::fs::PermissionsExt;
    assert_eq!(
        fs::metadata(env_path(&project))
            .unwrap()
            .permissions()
            .mode()
            & 0o777,
        0o600
    );
    // The secret is in the .env only: never in the store or the audit log.
    let audit_log = fs::read_to_string(store.root().join("logs/env-audit.log")).unwrap();
    assert!(!stored.contains("valor-ficticio") && !audit_log.contains("valor-ficticio"));
    assert!(
        fs::read_to_string(store.root().join("envs/demo.json"))
            .unwrap()
            .find("valor-ficticio")
            .is_none()
    );
    // Production needs explicit confirmation, and then holds the site's processes.
    assert!(
        activate(
            &store,
            "demo",
            "produccion",
            &BTreeMap::new(),
            false,
            "tester"
        )
        .is_err()
    );
    assert!(!production_active(&store, "demo"));
    activate(
        &store,
        "demo",
        "produccion",
        &BTreeMap::new(),
        true,
        "tester",
    )
    .unwrap();
    assert!(production_active(&store, "demo"));
    // Unexpected keys and symlinked .env are refused.
    let extra: BTreeMap<String, String> = [("APP_ENV".to_string(), "x".to_string())].into();
    assert!(activate(&store, "demo", "local", &extra, false, "tester").is_err());
    fs::remove_file(env_path(&project)).unwrap();
    std::os::unix::fs::symlink("/tmp/otro", env_path(&project)).unwrap();
    assert!(activate(&store, "demo", "local", &secrets, false, "tester").is_err());
    // Download: private file outside any repository, audited without the value.
    let out = tempfile::tempdir().unwrap();
    export(
        &store,
        "demo",
        "local",
        &secrets,
        &out.path().join(".env.local"),
        "tester",
    )
    .unwrap();
    let file = out.path().join(".env.local");
    assert!(
        fs::read_to_string(&file)
            .unwrap()
            .contains("DB_PASSWORD=valor-ficticio")
    );
    assert_eq!(
        fs::metadata(&file).unwrap().permissions().mode() & 0o777,
        0o600
    );
    assert!(
        !fs::read_to_string(store.root().join("logs/env-audit.log"))
            .unwrap()
            .contains("valor-ficticio")
    );
    assert!(
        export(
            &store,
            "demo",
            "local",
            &secrets,
            &out.path().join("otro.txt"),
            "tester"
        )
        .is_err()
    );
    // What activation writes is what a backend reads back.
    let read = read_dotenv(&file);
    assert_eq!(
        read.get("DB_PASSWORD").map(String::as_str),
        Some("valor-ficticio")
    );
    fs::write(
        out.path().join(".env.q"),
        "A=\"con \\\"comillas\\\"\"\nB='pa$$'\nC=x # nota\n# D=no\n",
    )
    .unwrap();
    let q = read_dotenv(&out.path().join(".env.q"));
    assert_eq!(
        (
            q["A"].as_str(),
            q["B"].as_str(),
            q["C"].as_str(),
            q.contains_key("D")
        ),
        ("con \"comillas\"", "pa$$", "x", false)
    );
}

#[test]
fn refuses_secrets_when_env_is_tracked_by_git() {
    let (_temp, store, project) = store_with_site();
    Command::new("/usr/bin/git")
        .arg("init")
        .arg("-q")
        .arg(&project.path)
        .status()
        .unwrap();
    fs::write(env_path(&project), "A=1\n").unwrap();
    Command::new("/usr/bin/git")
        .arg("-C")
        .arg(&project.path)
        .args(["add", ".env"])
        .status()
        .unwrap();
    save(&store, "demo", &sample(), "tester").unwrap();
    let secrets: BTreeMap<String, String> = [("DB_PASSWORD".to_string(), "x".to_string())].into();
    assert!(activate(&store, "demo", "local", &secrets, false, "tester").is_err());
    let guard = git_guard(&project);
    assert!(guard.repository && guard.tracked);
    // Downloading into the repository needs the file to be ignored.
    assert!(
        export(
            &store,
            "demo",
            "local",
            &secrets,
            &project.path.join(".env.local"),
            "tester"
        )
        .is_err()
    );
    fs::write(project.path.join(".gitignore"), ".env.*\n").unwrap();
    export(
        &store,
        "demo",
        "local",
        &secrets,
        &project.path.join(".env.local"),
        "tester",
    )
    .unwrap();
}

/// A repository the user did not write must not run its own `core.fsmonitor` program when
/// Stack asks whether the `.env` is tracked or ignored (activate, export).
#[test]
fn git_checks_never_run_the_fsmonitor_of_the_repository() {
    use std::os::unix::fs::PermissionsExt;
    let (temp, store, project) = store_with_site();
    let git = |args: &[&str]| {
        assert!(
            Command::new("/usr/bin/git")
                .arg("-C")
                .arg(&project.path)
                .args(args)
                .status()
                .unwrap()
                .success()
        );
    };
    git(&["init", "-q"]);
    let marker = temp.path().join("fsmonitor-ran");
    let script = temp.path().join("fsmonitor.sh");
    fs::write(
        &script,
        format!("#!/bin/sh\ntouch '{}'\n", marker.display()),
    )
    .unwrap();
    fs::set_permissions(&script, fs::Permissions::from_mode(0o755)).unwrap();
    git(&["config", "core.fsmonitor", script.to_str().unwrap()]);
    // Without the protection the same configuration does run the program.
    git(&["status", "--porcelain"]);
    assert!(marker.exists(), "the control run must trigger fsmonitor");
    fs::remove_file(&marker).unwrap();

    assert!(git_guard(&project).repository);
    fs::write(project.path.join(".gitignore"), ".env.*\n").unwrap();
    save(&store, "demo", &sample(), "tester").unwrap();
    let secrets: BTreeMap<String, String> = [("DB_PASSWORD".to_string(), "x".to_string())].into();
    export(
        &store,
        "demo",
        "local",
        &secrets,
        &project.path.join(".env.local"),
        "tester",
    )
    .unwrap();
    assert!(!marker.exists(), "core.fsmonitor of the repository ran");
}

#[test]
fn merging_moved_keys_keeps_the_rest_and_never_stores_values() {
    let (_temp, store, _project) = store_with_site();
    save(&store, "demo", &sample(), "tester").unwrap();
    let keys = vec![
        "APP_ENV".to_string(),
        "STRIPE_SECRET".to_string(),
        "STRIPE_SECRET".to_string(),
    ];
    let site = merge_secret_keys(&store, "demo", "local", &keys, None, "tester").unwrap();
    let local = &site.environments[0];
    // APP_ENV is replaced by a secret; DB_PASSWORD stays; the new key is added once.
    assert_eq!(local.entries.len(), 3);
    assert!(local.entries.iter().all(|e| e.secret && e.value.is_empty()));
    assert_eq!(site.environments[1], sample().environments[1]);
    // A missing environment needs its name and kind.
    assert!(merge_secret_keys(&store, "demo", "staging", &keys, None, "tester").is_err());
    let site = merge_secret_keys(
        &store,
        "demo",
        "staging",
        &keys[1..2],
        Some(("Preproducción", Kind::Staging)),
        "tester",
    )
    .unwrap();
    assert_eq!(site.environments.len(), 3);
    assert_eq!(site.environments[2].kind, Kind::Staging);
    for bad in [vec![], vec!["1A".to_string()]] {
        assert!(merge_secret_keys(&store, "demo", "local", &bad, None, "tester").is_err());
    }
    // The audit names each key once, with «mover» and no value.
    let lines = audit_lines(&store, "demo").unwrap();
    let moved: Vec<_> = lines.iter().filter(|l| l["action"] == "mover").collect();
    assert_eq!(moved.len(), 3);
    assert!(moved.iter().all(|l| l.get("value").is_none()));
    // The store holds no value for the moved keys.
    let stored: SiteEnvironments =
        serde_json::from_str(&fs::read_to_string(store.root().join("envs/demo.json")).unwrap())
            .unwrap();
    assert!(
        stored.environments[0]
            .entries
            .iter()
            .all(|e| e.value.is_empty())
    );
}

/// A `.env` that is a FIFO nobody writes to must not block the reader (the supervisor reads it
/// inside an async task): it is refused at once.
#[test]
fn a_fifo_named_env_is_refused_without_blocking() {
    let temp = tempfile::tempdir().unwrap();
    let file = temp.path().join(".env");
    let path = std::ffi::CString::new(file.to_string_lossy().as_bytes()).unwrap();
    // SAFETY: `path` is a valid NUL-terminated string that outlives the call.
    assert_eq!(unsafe { libc::mkfifo(path.as_ptr(), 0o600) }, 0);
    let (sender, receiver) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let _ = sender.send(read_stack_dotenv(&file).is_none());
    });
    let answer = receiver.recv_timeout(std::time::Duration::from_secs(10));
    assert_eq!(answer, Ok(true), "the reader waited on the FIFO");
}

/// `.env.example` is read like the other `.env` files: names only, and nothing from a file
/// over 1 MiB.
#[test]
fn example_keys_read_names_and_refuse_a_huge_file() {
    let (_temp, _store, project) = store_with_site();
    let file = project.path.join(".env.example");
    fs::write(&file, "# nota\nAPP_KEY=\nexport DB_HOST=x\nnada\n").unwrap();
    assert_eq!(example_keys(&project), ["APP_KEY", "DB_HOST"]);
    fs::write(&file, "A=1\n".repeat(300_000)).unwrap();
    assert!(example_keys(&project).is_empty());
}
