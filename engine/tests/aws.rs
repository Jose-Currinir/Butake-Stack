//! The AWS tool end to end, with made-up files and a fake `aws` in a temporary home (never the
//! owner's `~/.aws` nor AWS itself).

use serde_json::{json, Value};
use std::{
    fs,
    io::Write,
    os::unix::fs::PermissionsExt,
    path::{Path, PathBuf},
    process::{Command, Stdio},
    time::{Duration, Instant},
};

struct Setup {
    _temp: tempfile::TempDir,
    store: PathBuf,
    home: PathBuf,
    config: PathBuf,
    credentials: PathBuf,
}

const FAKE_AWS: &str = r#"#!/bin/sh
[ -n "$AWS_ACCESS_KEY_ID$AWS_PROFILE" ] && { echo leaked >&2; exit 9; }
[ -f "$AWS_CONFIG_FILE" ] && [ -f "$AWS_SHARED_CREDENTIALS_FILE" ] || { echo no files >&2; exit 9; }
case "$1 $2 $4" in
  'sso login acme-dev')
    case "$(cat "$HOME/modo" 2>/dev/null)" in
      bien) mkdir -p "$HOME/.aws/sso/cache"
            echo '{"accessToken": "TOKEN-FALSO", "expiresAt": "2030-01-01T00:00:00Z"}' > "$HOME/.aws/sso/cache/293abb6b76d7791c0732cc517d38c4b5c734b87f.json" ;;
      *) /bin/sleep 600 & echo $$ $! > "$HOME/pids.tmp"; mv "$HOME/pids.tmp" "$HOME/pids"; wait ;;
    esac ;;
  'sts get-caller-identity acme-dev') echo '{"UserId": "AROAEJEMPLO:ana", "Account": "111122223333", "Arn": "arn:aws:sts::111122223333:assumed-role/Desarrollo/ana"}' ;;
  'sts get-caller-identity default') echo 'An error occurred (InvalidClientTokenId) when calling the GetCallerIdentity operation' >&2; exit 254 ;;
  *) echo 'Error when retrieving token from sso: Token has expired and refresh failed' >&2; exit 255 ;;
esac
"#;

fn setup() -> Setup {
    let temp = tempfile::Builder::new().prefix("bsa").tempdir().unwrap();
    let home = temp.path().join("home");
    let aws = home.join(".local/bin/aws");
    fs::create_dir_all(aws.parent().unwrap()).unwrap();
    fs::create_dir_all(home.join("archivos")).unwrap();
    let config = home.join("archivos/config");
    let credentials = home.join("archivos/credentials");
    fs::write(&config, "[profile acme-dev]\nsso_session = acme\nsso_account_id = 111122223333\nsso_role_name = Desarrollo\n\n[sso-session acme]\nsso_start_url = https://acme.awsapps.com/start\nsso_region = us-east-1\n").unwrap();
    fs::write(&credentials, "[default]\naws_access_key_id = AKIAIOSFODNN7EXAMPLE\naws_secret_access_key = wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY\n").unwrap();
    // The fake fails (exit 9) when the caller's AWS variables reach it or the files are not named.
    fs::write(&aws, FAKE_AWS).unwrap();
    fs::set_permissions(&aws, fs::Permissions::from_mode(0o755)).unwrap();
    Setup {
        store: temp.path().join("store"),
        home,
        config,
        credentials,
        _temp: temp,
    }
}

fn request(setup: &Setup, body: Value) -> Value {
    let child = start(setup, body);
    serde_json::from_slice(&child.wait_with_output().unwrap().stdout).unwrap()
}

/// The engine with a request on its way (its answer comes when it exits).
fn start(setup: &Setup, body: Value) -> std::process::Child {
    let mut child = Command::new(env!("CARGO_BIN_EXE_butake-stack"))
        .env("BUTAKE_STACK_HOME", &setup.store)
        .env("BUTAKE_DEVTOOLS_HOME", &setup.home)
        .env("AWS_CONFIG_FILE", &setup.config)
        .env("AWS_SHARED_CREDENTIALS_FILE", &setup.credentials)
        .env("AWS_ACCESS_KEY_ID", "AKIADELLLAMADOR0001")
        .env("AWS_PROFILE", "otro")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
    child
        .stdin
        .take()
        .unwrap()
        .write_all(body.to_string().as_bytes())
        .unwrap();
    child
}

fn helper(setup: &Setup, profile: &str, config: &Path) -> std::process::Output {
    Command::new(env!("CARGO_BIN_EXE_butake-stack"))
        .args(["aws-credential", profile])
        .env("BUTAKE_STACK_HOME", &setup.store)
        .env("BUTAKE_DEVTOOLS_HOME", &setup.home)
        .env("AWS_CONFIG_FILE", config)
        .output()
        .unwrap()
}

/// The tool is gated, no secret reaches a response, the CLI gets the files Stack shows and none
/// of the caller's AWS variables, and its errors become fixed codes.
#[test]
fn aws_profiles_never_return_secrets_and_the_cli_gets_a_clean_environment() {
    let setup = setup();
    assert_eq!(
        request(&setup, json!({"method": "awsProfiles"}))["error"]["code"],
        "plugin_disabled"
    );
    request(
        &setup,
        json!({"method": "pluginSetEnabled", "id": "aws", "enabled": true}),
    );
    let list = request(&setup, json!({"method": "awsProfiles"}));
    assert_eq!(list["ok"], true, "{list}");
    let value = &list["value"];
    assert_eq!(value["cli"]["installed"], true);
    let names: Vec<_> = value["profiles"]
        .as_array()
        .unwrap()
        .iter()
        .map(|p| p["name"].as_str().unwrap())
        .collect();
    assert_eq!(names, ["acme-dev", "default"]);
    assert_eq!(value["profiles"][1]["keySuffix"], "MPLE");
    let text = list.to_string();
    assert!(!text.contains("wJalrXUtnFEMI") && !text.contains("AKIAIOSFODNN7EXA"));

    let identity = request(&setup, json!({"method": "awsCheck", "name": "acme-dev"}));
    assert_eq!(identity["value"]["account"], "111122223333", "{identity}");
    assert_eq!(
        request(&setup, json!({"method": "awsCheck", "name": "default"}))["error"]["code"],
        "aws_invalid_credentials"
    );
    let expired = request(&setup, json!({"method": "awsCheck", "name": "otro"}));
    assert_eq!(expired["error"]["code"], "aws_session_expired");
    assert!(!expired.to_string().contains("refresh failed"));
    assert_eq!(
        request(&setup, json!({"method": "awsCheck", "name": "--debug"}))["error"]["code"],
        "aws_invalid_profile"
    );
    assert_eq!(
        request(
            &setup,
            json!({"method": "awsDeleteProfile", "name": "acme-dev"})
        )["error"]["code"],
        "confirmation_required"
    );
    // A confirmed edit keeps the rest of the file and leaves a backup in the store.
    let saved = request(
        &setup,
        json!({"method": "awsUpdateProfile", "name": "acme-dev", "confirmed": true,
               "profile": {"name": "acme-dev", "region": "sa-east-1", "accountId": "111122223333", "roleName": "Desarrollo"}}),
    );
    assert_eq!(saved["ok"], true, "{saved}");
    assert!(fs::read_to_string(&setup.config)
        .unwrap()
        .contains("sso_role_name = Desarrollo\nregion = sa-east-1\n\n[sso-session acme]"));
    assert_eq!(
        fs::read_dir(setup.store.join("aws-backups"))
            .unwrap()
            .count(),
        1
    );
}

/// The credential process prints nothing for a profile that does not point at it, and its error
/// says no more than which step failed.
#[test]
fn the_credential_process_answers_only_for_its_own_profiles() {
    let setup = setup();
    for profile in ["default", "acme-dev", "", "../x"] {
        let out = helper(&setup, profile, &setup.config);
        assert!(!out.status.success() && out.stdout.is_empty(), "{profile}");
        assert!(String::from_utf8_lossy(&out.stderr).starts_with("Stack: "));
    }
}

/// The pids the fake `aws sso login` wrote while it waits: its own and its child's.
fn waiting_pids(setup: &Setup) -> Vec<i32> {
    let file = setup.home.join("pids");
    let deadline = Instant::now() + Duration::from_secs(10);
    while !file.exists() {
        assert!(Instant::now() < deadline, "the fake never started");
        std::thread::sleep(Duration::from_millis(20));
    }
    let pids: Vec<i32> = fs::read_to_string(&file)
        .unwrap()
        .split_whitespace()
        .map(|p| p.parse().unwrap())
        .collect();
    fs::remove_file(file).unwrap();
    assert_eq!(pids.len(), 2);
    pids
}

/// A process that exists and is not a zombie (`ps` prints nothing for a pid that is gone).
fn alive(pid: i32) -> bool {
    let out = Command::new("/bin/ps")
        .args(["-o", "stat=", "-p", &pid.to_string()])
        .output()
        .expect("ps was checked before the test started");
    let state = String::from_utf8_lossy(&out.stdout);
    !state.trim().is_empty() && !state.trim().starts_with('Z')
}

/// Whether `ps` can see processes here (sandboxes may forbid running it or hide pids). The test
/// below proves processes are gone by pid, so without `ps` it cannot check anything.
fn ps_works() -> bool {
    Command::new("/bin/ps")
        .args(["-o", "stat=", "-p", &std::process::id().to_string()])
        .output()
        .map(|o| o.status.success() && !String::from_utf8_lossy(&o.stdout).trim().is_empty())
        .unwrap_or(false)
}

fn all_gone(pids: &[i32]) -> bool {
    let deadline = Instant::now() + Duration::from_secs(5);
    while pids.iter().any(|p| alive(*p)) {
        if Instant::now() > deadline {
            return false;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    true
}

fn signal(pid: u32, signal: &str) {
    assert!(Command::new("/bin/kill")
        .args([signal, &pid.to_string()])
        .status()
        .unwrap()
        .success());
}

/// «Iniciar sesión…» never leaves AWS CLI behind: the app's stop (SIGTERM), the time limit, the
/// app dying and the engine itself killed all end the fake and its child, checked by pid.
#[test]
fn signing_in_can_be_stopped_and_never_leaves_aws_cli_running() {
    if !ps_works() {
        eprintln!("skipped: /bin/ps cannot inspect processes here");
        return;
    }
    let setup = setup();
    request(
        &setup,
        json!({"method": "pluginSetEnabled", "id": "aws", "enabled": true}),
    );
    let login = json!({"method": "awsSsoLogin", "name": "acme-dev"});

    // Cancelled by the app: SIGTERM to the engine it started.
    let engine = start(&setup, login.clone());
    let pids = waiting_pids(&setup);
    assert!(pids.iter().all(|p| alive(*p)));
    signal(engine.id(), "-TERM");
    let answer: Value = serde_json::from_slice(&engine.wait_with_output().unwrap().stdout).unwrap();
    assert_eq!(answer["error"]["code"], "aws_cancelled", "{answer}");
    assert!(all_gone(&pids), "{pids:?}");
    // The session shown does not change.
    let list = request(&setup, json!({"method": "awsProfiles"}));
    assert!(
        list["value"]["profiles"][0]["session"]["expiresAt"].is_null(),
        "{list}"
    );

    // The time limit: its own code, nothing left.
    let mut engine = Command::new(env!("CARGO_BIN_EXE_butake-stack"));
    let started = Instant::now();
    let out = {
        let mut child = engine
            .env("BUTAKE_STACK_HOME", &setup.store)
            .env("BUTAKE_DEVTOOLS_HOME", &setup.home)
            .env("AWS_CONFIG_FILE", &setup.config)
            .env("AWS_SHARED_CREDENTIALS_FILE", &setup.credentials)
            .env("BUTAKE_QA_AWS_SIGN_IN_LIMIT", "2")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        child
            .stdin
            .take()
            .unwrap()
            .write_all(login.to_string().as_bytes())
            .unwrap();
        child.wait_with_output().unwrap()
    };
    let answer: Value = serde_json::from_slice(&out.stdout).unwrap();
    assert_eq!(answer["error"]["code"], "aws_login_timeout", "{answer}");
    assert!(started.elapsed() < Duration::from_secs(10));
    assert!(all_gone(&waiting_pids(&setup)));

    // The app dies (its engine is handed to launchd): the engine ends the run on its own.
    let request_file = setup.home.join("login.json");
    fs::write(&request_file, login.to_string()).unwrap();
    let app = Command::new("/bin/sh")
        .args([
            "-c",
            &format!(
                "'{}' < '{}' > /dev/null & echo $! > '{}'; wait",
                env!("CARGO_BIN_EXE_butake-stack"),
                request_file.display(),
                setup.home.join("engine.pid").display()
            ),
        ])
        .env("BUTAKE_STACK_HOME", &setup.store)
        .env("BUTAKE_DEVTOOLS_HOME", &setup.home)
        .env("AWS_CONFIG_FILE", &setup.config)
        .env("AWS_SHARED_CREDENTIALS_FILE", &setup.credentials)
        .spawn()
        .unwrap();
    let pids = waiting_pids(&setup);
    let engine_pid: i32 = fs::read_to_string(setup.home.join("engine.pid"))
        .unwrap()
        .trim()
        .parse()
        .unwrap();
    signal(app.id(), "-KILL");
    let mut app = app;
    app.wait().unwrap();
    assert!(all_gone(&pids) && all_gone(&[engine_pid]), "{pids:?}");

    // The engine killed outright: the next request ends what it left.
    let engine = start(&setup, login.clone());
    let pids = waiting_pids(&setup);
    signal(engine.id(), "-KILL");
    engine.wait_with_output().unwrap();
    assert!(
        pids.iter().all(|p| alive(*p)),
        "the fake should outlive a killed engine"
    );
    request(&setup, json!({"method": "awsProfiles"}));
    assert!(all_gone(&pids), "{pids:?}");
    assert_eq!(
        fs::read_dir(setup.store.join("aws-runs")).unwrap().count(),
        0
    );

    // Finished in the browser: the profile shows the new expiry, never the token.
    fs::write(setup.home.join("modo"), "bien").unwrap();
    let done = request(&setup, login);
    assert_eq!(
        done["value"]["profiles"][0]["session"]["valid"], true,
        "{done}"
    );
    assert!(!done.to_string().contains("TOKEN-FALSO"));
}
