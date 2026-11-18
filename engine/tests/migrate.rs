//! `butake-stack migrate-data` end to end, in an isolated home (BUTAKE_DEVTOOLS_HOME: no
//! launchctl, no real folder): the plan, the run and a second run that finds nothing to do.

use serde_json::Value;
use std::{fs, path::Path, process::Command};

fn migrate(home: &Path, flag: &str) -> (bool, Value) {
    let out = Command::new(env!("CARGO_BIN_EXE_butake-stack"))
        .args(["migrate-data", flag])
        .env_clear()
        .env("HOME", home)
        .env("BUTAKE_DEVTOOLS_HOME", home)
        .output()
        .unwrap();
    let value = serde_json::from_slice(&out.stdout).unwrap_or(Value::Null);
    (out.status.success(), value)
}

#[test]
fn the_data_moves_only_when_asked_and_only_once() {
    let temp = tempfile::tempdir().unwrap();
    let home = temp.path().canonicalize().unwrap();
    let support = home.join("Library/Application Support");
    let old = support.join("Butake Stack");
    fs::create_dir_all(old.join("projects")).unwrap();
    fs::create_dir_all(old.join("config/mysql")).unwrap();
    fs::write(old.join("stack.json"), "{}").unwrap();
    fs::write(
        old.join("config/mysql/my.cnf"),
        format!("datadir={}/data/mysql\n", old.display()),
    )
    .unwrap();

    let (ok, plan) = migrate(&home, "--plan");
    assert!(ok, "{plan}");
    assert_eq!(plan["state"], "ready");
    assert_eq!(plan["running"], serde_json::json!([]));
    assert!(
        old.join("stack.json").exists() && !support.join("Stack").exists(),
        "the plan moves nothing"
    );

    let (ok, done) = migrate(&home, "--confirm");
    assert!(ok && done["ok"] == true, "{done}");
    let new = support.join("Stack");
    assert!(!old.exists() && new.join("stack.json").exists());
    assert_eq!(
        fs::read_to_string(new.join("config/mysql/my.cnf")).unwrap(),
        format!("datadir={}/data/mysql\n", new.display())
    );
    assert!(
        Path::new(done["backup"].as_str().unwrap())
            .join("stack.json")
            .exists()
    );

    let (ok, again) = migrate(&home, "--confirm");
    assert!(ok && again["already"] == true, "{again}");

    // A store isolated only by BUTAKE_STACK_HOME has no folders to move.
    let out = Command::new(env!("CARGO_BIN_EXE_butake-stack"))
        .args(["migrate-data", "--plan"])
        .env_clear()
        .env("BUTAKE_STACK_HOME", home.join("qa"))
        .output()
        .unwrap();
    assert!(!out.status.success());
    assert!(String::from_utf8_lossy(&out.stderr).contains("migration_isolated"));
}
