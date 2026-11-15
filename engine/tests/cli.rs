use serde_json::{json, Value};
use std::{
    io::Write,
    process::{Command, Stdio},
};

fn call(home: &std::path::Path, request: Value) -> Value {
    let mut child = Command::new(env!("CARGO_BIN_EXE_butake-stack"))
        .env("BUTAKE_STACK_HOME", home)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
    child
        .stdin
        .take()
        .unwrap()
        .write_all(request.to_string().as_bytes())
        .unwrap();
    let result = child.wait_with_output().unwrap();
    assert!(result.status.success());
    serde_json::from_slice(&result.stdout).unwrap()
}

fn call_with_agent(home: &std::path::Path, agent: &std::path::Path, request: Value) -> Value {
    let mut child = Command::new(env!("CARGO_BIN_EXE_butake-stack"))
        .env("BUTAKE_STACK_HOME", home)
        .env("SSH_AUTH_SOCK", agent)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
    child
        .stdin
        .take()
        .unwrap()
        .write_all(request.to_string().as_bytes())
        .unwrap();
    serde_json::from_slice(&child.wait_with_output().unwrap().stdout).unwrap()
}

/// Keys with a passphrase go through the engine's own askpass (never an argument), load into a
/// private agent, and stay usable without the SSH terminal plugin (they belong to the base).
#[test]
fn ssh_keys_with_passphrase_use_askpass_and_a_private_agent() {
    let temp = tempfile::Builder::new().prefix("bsk").tempdir().unwrap();
    let home = temp.path().join("store");
    let socket = temp.path().join("a.sock");
    let mut agent = Command::new("/usr/bin/ssh-agent")
        .arg("-D")
        .arg("-a")
        .arg(&socket)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    for _ in 0..50 {
        if socket.exists() {
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(100));
    }
    // Plugin off: hosts are refused, keys are not.
    assert_eq!(
        call(&home, json!({"method":"sshHosts"}))["error"]["code"],
        "plugin_disabled"
    );
    let generated = call_with_agent(
        &home,
        &socket,
        json!({"method":"sshKeyGenerate","name":"Nueva","comment":"qa@stack","passphrase":"frase de prueba"}),
    );
    assert_eq!(generated["value"]["encrypted"], true, "{generated}");
    assert!(
        call(&home, json!({"method":"sshKeyPublic","id":"nueva"}))["value"]
            .as_str()
            .unwrap()
            .starts_with("ssh-ed25519 ")
    );
    let locked = temp.path().join("locked");
    assert!(Command::new("/usr/bin/ssh-keygen")
        .args(["-q", "-t", "ed25519", "-N", "otra frase", "-f"])
        .arg(&locked)
        .status()
        .unwrap()
        .success());
    let path = locked.to_string_lossy();
    assert_eq!(
        call(
            &home,
            json!({"method":"sshKeyImport","path":path,"name":"Bloqueada"})
        )["error"]["code"],
        "ssh_key_passphrase"
    );
    assert_eq!(
        call(
            &home,
            json!({"method":"sshKeyImport","path":path,"name":"Bloqueada","passphrase":"mala"})
        )["error"]["code"],
        "ssh_key_passphrase"
    );
    assert_eq!(
        call(
            &home,
            json!({"method":"sshKeyImport","path":path,"name":"Bloqueada","passphrase":"otra frase"})
        )["value"]["encrypted"],
        true
    );
    assert_eq!(
        call_with_agent(
            &home,
            &socket,
            json!({"method":"sshKeyAgentLoad","id":"nueva","passphrase":"mala"})
        )["error"]["code"],
        "ssh_key_passphrase"
    );
    assert_eq!(
        call_with_agent(
            &home,
            &socket,
            json!({"method":"sshKeyAgentLoad","id":"nueva"})
        )["error"]["code"],
        "ssh_key_passphrase"
    );
    assert_eq!(
        call_with_agent(
            &home,
            &socket,
            json!({"method":"sshKeyAgentLoad","id":"nueva","passphrase":"frase de prueba"})
        )["value"],
        true
    );
    assert_eq!(
        call_with_agent(&home, &socket, json!({"method":"sshKeyAgent"}))["value"]["loaded"],
        json!(["nueva"])
    );
    assert_eq!(
        call_with_agent(
            &home,
            &socket,
            json!({"method":"sshKeyAgentUnload","id":"nueva"})
        )["value"],
        true
    );
    assert_eq!(
        call_with_agent(&home, &socket, json!({"method":"sshKeyAgent"}))["value"]["loaded"],
        json!([])
    );
    // The stored keys are private.
    for entry in std::fs::read_dir(home.join("config/ssh/keys")).unwrap() {
        let meta = entry.unwrap().metadata().unwrap();
        assert_eq!(
            std::os::unix::fs::PermissionsExt::mode(&meta.permissions()) & 0o077,
            0
        );
    }
    let _ = agent.kill();
    let _ = agent.wait();
}

/// A project whose folder was moved outside Stack stays in the list, marked and off; it does not
/// start, and pointing it at a project folder brings it back as it was.
#[test]
fn a_project_whose_folder_is_gone_is_listed_marked_and_never_starts() {
    let temp = tempfile::tempdir().unwrap();
    let home = temp.path().join("store");
    let folder = temp.path().join("Web").join("tienda");
    std::fs::create_dir_all(&folder).unwrap();
    std::fs::write(folder.join("index.html"), "<p>QA</p>").unwrap();
    let project = json!({"id":"tienda","name":"Tienda","path":folder,"domains":["tienda.test"],"https":false,"kind":"static","runtime":{},"docroot":".","services":[],"databases":[],"processes":[],"enabled":true});
    assert_eq!(
        call(&home, json!({"method":"saveProject","project":project}))["ok"],
        true
    );
    let moved = temp.path().join("App").join("tienda-movida");
    std::fs::create_dir_all(moved.parent().unwrap()).unwrap();
    std::fs::rename(&folder, &moved).unwrap();

    let listed = call(&home, json!({"method":"listProjects"}))["value"].clone();
    assert_eq!(listed.as_array().unwrap().len(), 1);
    assert_eq!(listed[0]["id"], "tienda");
    assert_eq!(listed[0]["missing"], true);
    assert_eq!(listed[0]["enabled"], false);

    let start = call(
        &home,
        json!({"method":"setSiteEnabled","id":"tienda","enabled":true}),
    );
    assert_eq!(start["ok"], false);
    assert_eq!(start["error"]["code"], "folder_missing");

    // A folder that is not a project is refused; the project's own folder is taken.
    let empty = temp.path().join("vacia");
    std::fs::create_dir_all(&empty).unwrap();
    let refused = call(
        &home,
        json!({"method":"relocateProject","id":"tienda","path":empty}),
    );
    assert_eq!(refused["error"]["code"], "not_a_project");
    let found = call(
        &home,
        json!({"method":"relocateProject","id":"tienda","path":moved}),
    );
    assert_eq!(found["ok"], true);
    let listed = call(&home, json!({"method":"listProjects"}))["value"].clone();
    assert!(listed[0].get("missing").is_none());
    assert_eq!(listed[0]["enabled"], true);
    assert_eq!(listed[0]["path"], json!(moved.canonicalize().unwrap()));

    // What the app sends back with the mark is saved without it.
    let mut marked = listed[0].clone();
    marked["missing"] = json!(false);
    assert_eq!(
        call(&home, json!({"method":"saveProject","project":marked}))["ok"],
        true
    );
}

#[test]
fn isolated_cli_crud_and_errors() {
    let temp = tempfile::tempdir().unwrap();
    let home = temp.path().join("store");
    assert_eq!(
        call(&home, json!({"method":"listProjects"}))["value"],
        json!([])
    );
    let project = json!({"id":"demo","name":"Demostración","path":temp.path(),"domains":["demo.test"],"https":true,"kind":"static","runtime":{},"docroot":".","services":[],"databases":[],"processes":[]});
    assert_eq!(
        call(&home, json!({"method":"saveProject","project":project}))["ok"],
        true
    );
    let listed = call(&home, json!({"method":"listProjects"}));
    assert_eq!(listed["value"].as_array().unwrap().len(), 1);
    assert_eq!(listed["value"][0]["name"], "Demostración");
    assert_eq!(
        call(&home, json!({"method":"envList","id":"../outside"}))["ok"],
        false
    );
    assert_eq!(
        call(&home, json!({"method":"stackConfig"}))["value"]["ports"]["dns"],
        53
    );
    assert_eq!(
        call(&home, json!({"method":"deleteProject","id":"demo"}))["value"],
        json!({"portDependents": []})
    );
    assert_eq!(
        call(&home, json!({"method":"listProjects"}))["value"],
        json!([])
    );
    assert_eq!(
        call(&home, json!({"method":"unknown"}))["error"]["messageKey"],
        "engine.requestFailed"
    );
}

/// A console opened in a project's folder gets its versions first on PATH (the same order the
/// supervisor gives the project's processes) and nothing of its `.env`.
#[test]
fn a_project_console_gets_its_versions_and_no_secrets() {
    let temp = tempfile::tempdir().unwrap();
    let home = temp.path().join("store");
    let folder = temp.path().join("api");
    std::fs::create_dir_all(folder.join(".venv/bin")).unwrap();
    std::fs::write(folder.join(".env"), "SECRET_TOKEN=no-se-lee\n").unwrap();
    let project = json!({"id":"api","name":"API","path":folder,"domains":["api.test"],"https":false,"kind":"fastapi","runtime":{"php":"8.3"},"docroot":".","services":[],"databases":[],"processes":[]});
    assert_eq!(
        call(&home, json!({"method":"saveProject","project":project}))["ok"],
        true
    );
    let value = call(&home, json!({"method":"siteShellEnvironment","id":"api"}))["value"].clone();
    let path = value["PATH"].as_str().unwrap();
    assert!(path.contains(".venv/bin:"), "{path}");
    assert!(path.contains("runtimes/php/8.3/bin"), "{path}");
    assert!(path.ends_with("/usr/bin:/bin:/usr/sbin:/sbin"), "{path}");
    assert!(value["VIRTUAL_ENV"]
        .as_str()
        .unwrap()
        .ends_with("api/.venv"));
    assert!(!value.to_string().contains("no-se-lee"));
    assert_eq!(
        call(
            &home,
            json!({"method":"siteShellEnvironment","id":"../fuera"})
        )["ok"],
        false
    );
}

/// P-41: a project is renamed and moved from the command line, and the app's steps stay pending.
#[test]
fn projects_are_renamed_and_moved_from_the_command_line() {
    let temp = tempfile::tempdir().unwrap();
    let home = temp.path().join("store");
    let (one, two) = (temp.path().join("uno"), temp.path().join("dos"));
    std::fs::create_dir_all(&one).unwrap();
    std::fs::create_dir_all(&two).unwrap();
    let saved = call(
        &home,
        json!({"method": "saveProject", "project": {"id": "viejo", "name": "Viejo", "path": one,
            "domains": ["viejo.test"], "https": false, "kind": "static", "runtime": {},
            "docroot": ".", "services": [], "databases": [], "processes": []}}),
    );
    assert_eq!(saved["ok"], true, "{saved}");
    let renamed = call(
        &home,
        json!({"method": "renameProject", "id": "viejo", "newId": "nuevo", "domain": true}),
    );
    assert_eq!(renamed["ok"], true, "{renamed}");
    assert_eq!(
        renamed["value"]["project"]["domains"],
        json!(["nuevo.test"])
    );
    assert_eq!(renamed["value"]["pending"], json!(["app"]));
    let pending = call(&home, json!({"method": "pendingRenames"}));
    assert_eq!(pending["value"][0]["to"], "nuevo");
    let refused = call(
        &home,
        json!({"method": "renameProject", "id": "nuevo", "newId": "nuevo"}),
    );
    assert_eq!(refused["ok"], false);
    let moved = call(
        &home,
        json!({"method": "moveProject", "id": "nuevo", "path": two}),
    );
    assert_eq!(moved["ok"], true, "{moved}");
    assert_eq!(
        moved["value"]["project"]["path"],
        json!(two.canonicalize().unwrap())
    );
    let done = call(
        &home,
        json!({"method": "renameStepDone", "from": "viejo", "to": "nuevo", "step": "app"}),
    );
    assert_eq!(done["value"], json!([]));
}
