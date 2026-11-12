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
    assert_eq!(
        call(&home, json!({"method":"getProject","id":"demo"}))["value"]["name"],
        "Demostración"
    );
    assert_eq!(
        call(&home, json!({"method":"listProjects"}))["value"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
    assert_eq!(
        call(&home, json!({"method":"getProject","id":"../outside"}))["ok"],
        false
    );
    assert_eq!(
        call(&home, json!({"method":"stackConfig"}))["value"]["ports"]["dns"],
        53
    );
    assert_eq!(
        call(&home, json!({"method":"deleteProject","id":"demo"}))["value"],
        true
    );
    assert_eq!(
        call(&home, json!({"method":"getProject","id":"demo"}))["ok"],
        false
    );
    assert_eq!(
        call(&home, json!({"method":"unknown"}))["error"]["messageKey"],
        "engine.requestFailed"
    );
}
