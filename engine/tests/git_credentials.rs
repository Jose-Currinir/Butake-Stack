//! The token of a connected account reaches Git only for its provider's origin, through the
//! engine's askpass, and nowhere else. A made-up token and a server on this Mac's loopback
//! address that asks for Basic authentication: no provider and no real account are involved.

use serde_json::{json, Value};
use std::{
    io::{BufRead, BufReader, Write},
    net::TcpListener,
    path::{Path, PathBuf},
    process::{Command, Stdio},
    sync::{Arc, Mutex},
};

const TOKEN: &str = "ficha-inventada-3f9a";

/// Answers every request: 401 asking for Basic authentication without an `Authorization`
/// header, 404 with one. Keeps the headers it received.
fn server() -> (u16, Arc<Mutex<Vec<String>>>) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    let seen = Arc::new(Mutex::new(vec![]));
    let record = seen.clone();
    std::thread::spawn(move || {
        for stream in listener.incoming() {
            let Ok(mut stream) = stream else { continue };
            let mut reader = BufReader::new(stream.try_clone().unwrap());
            let mut authorization = None;
            loop {
                let mut line = String::new();
                if reader.read_line(&mut line).unwrap_or(0) == 0 || line.trim().is_empty() {
                    break;
                }
                if let Some(value) = line.strip_prefix("Authorization: ") {
                    authorization = Some(value.trim().to_string());
                }
            }
            let reply = match &authorization {
                None => "HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: Basic realm=\"qa\"\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
                Some(_) => "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
            };
            if let Some(value) = authorization {
                record.lock().unwrap().push(value);
            }
            let _ = stream.write_all(reply.as_bytes());
        }
    });
    (port, seen)
}

fn base64(input: &str) -> String {
    const TABLE: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::new();
    for chunk in input.as_bytes().chunks(3) {
        let n = chunk
            .iter()
            .enumerate()
            .fold(0u32, |n, (i, b)| n | (*b as u32) << (16 - 8 * i));
        for i in 0..4 {
            if i <= chunk.len() {
                out.push(TABLE[(n >> (18 - 6 * i) & 63) as usize] as char);
            } else {
                out.push('=');
            }
        }
    }
    out
}

struct Setup {
    _temp: tempfile::TempDir,
    root: PathBuf,
}

fn setup() -> Setup {
    let temp = tempfile::Builder::new().prefix("bgc").tempdir().unwrap();
    let root = temp.path().canonicalize().unwrap();
    for dir in ["home", "store/config", "clones", "tmp"] {
        std::fs::create_dir_all(root.join(dir)).unwrap();
    }
    std::fs::write(
        root.join("store/config/plugins.json"),
        r#"{"git":{"version":"1.0.0","enabled":true,"installedAt":1}}"#,
    )
    .unwrap();
    Setup { _temp: temp, root }
}

/// One request to the engine, with a private home, store and temporary folder. Returns the
/// answer and everything the engine wrote.
fn call(setup: &Setup, request: Value) -> (Value, String) {
    let mut child = Command::new(env!("CARGO_BIN_EXE_butake-stack"))
        .env("HOME", setup.root.join("home"))
        .env("BUTAKE_STACK_HOME", setup.root.join("store"))
        .env("TMPDIR", setup.root.join("tmp"))
        .env("GIT_CONFIG_GLOBAL", setup.root.join("home/.gitconfig"))
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env_remove("GIT_ASKPASS")
        .env_remove("SSH_AUTH_SOCK")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    child
        .stdin
        .take()
        .unwrap()
        .write_all(request.to_string().as_bytes())
        .unwrap();
    let output = child.wait_with_output().unwrap();
    let text = format!(
        "{}{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    let value = serde_json::from_slice(&output.stdout).unwrap_or(Value::Null);
    (value, text)
}

/// A repository whose `origin` is the local server, and the request to ask it for commits.
fn fetch_request(setup: &Setup, port: u16, credentials: Value) -> Value {
    let repository = setup.root.join("clones/app");
    if !repository.exists() {
        let git = |args: &[&str]| {
            assert!(Command::new("git")
                .args(args)
                .env("HOME", setup.root.join("home"))
                .env("GIT_CONFIG_NOSYSTEM", "1")
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .status()
                .unwrap()
                .success());
        };
        let path = repository.to_string_lossy().into_owned();
        git(&["init", "-q", "-b", "main", &path]);
        git(&[
            "-C",
            &path,
            "remote",
            "add",
            "origin",
            &format!("http://127.0.0.1:{port}/equipo/app.git"),
        ]);
    }
    json!({"method": "gitAction", "path": repository, "action": "fetch", "value": "", "credentials": credentials})
}

/// No file under `dir` holds the token.
fn clean(dir: &Path) -> bool {
    std::fs::read_dir(dir).unwrap().flatten().all(|entry| {
        let path = entry.path();
        if path.is_dir() {
            clean(&path)
        } else {
            !String::from_utf8_lossy(&std::fs::read(&path).unwrap_or_default()).contains(TOKEN)
        }
    })
}

#[test]
fn the_token_reaches_git_only_for_its_origin_and_is_kept_nowhere() {
    let setup = setup();
    let (port, seen) = server();
    let origin = format!("http://127.0.0.1:{port}");
    let (answer, text) = call(
        &setup,
        fetch_request(
            &setup,
            port,
            json!({"origin": origin, "username": "ana-qa", "password": TOKEN}),
        ),
    );
    // The server got the account's credentials (and then said there is no such repository).
    assert_eq!(
        seen.lock().unwrap().first().map(String::as_str),
        Some(format!("Basic {}", base64(&format!("ana-qa:{TOKEN}"))).as_str()),
        "{text}"
    );
    assert_eq!(answer["ok"], false, "{text}");
    // Nothing the engine answered or wrote holds the token, and no file does.
    assert!(!text.contains(TOKEN), "{text}");
    assert!(clean(&setup.root));
    // The repository's own configuration keeps the plain address.
    let config = std::fs::read_to_string(setup.root.join("clones/app/.git/config")).unwrap();
    assert!(config.contains(&format!("url = http://127.0.0.1:{port}/equipo/app.git")));
    // The askpass socket and its folder are gone.
    assert_eq!(
        std::fs::read_dir(setup.root.join("tmp")).unwrap().count(),
        0
    );
}

#[test]
fn credentials_of_another_origin_are_never_sent() {
    let setup = setup();
    let (port, seen) = server();
    for credentials in [
        // Another server, another port of this one, and the same name over another scheme.
        json!({"origin": "https://git.example.invalid", "username": "ana-qa", "password": TOKEN}),
        json!({"origin": format!("http://127.0.0.1:{}", port.wrapping_add(1).max(1)), "username": "ana-qa", "password": TOKEN}),
        json!({"origin": format!("https://127.0.0.1:{port}"), "username": "ana-qa", "password": TOKEN}),
    ] {
        let (answer, text) = call(&setup, fetch_request(&setup, port, credentials));
        assert_eq!(answer["ok"], false, "{text}");
        assert_eq!(answer["error"]["code"], "https_denied", "{text}");
        assert!(!text.contains(TOKEN), "{text}");
    }
    assert!(seen.lock().unwrap().is_empty());
    // Credentials that are not what the app sends are refused before Git runs.
    for credentials in [
        json!({"origin": "http://git.example.invalid", "username": "ana-qa", "password": TOKEN}),
        json!({"origin": "https://git.example.invalid/ruta", "username": "ana-qa", "password": TOKEN}),
        json!({"origin": "https://usuario@git.example.invalid", "username": "ana-qa", "password": TOKEN}),
        json!({"origin": format!("http://127.0.0.1:{port}"), "username": "ana qa", "password": TOKEN}),
        json!({"origin": format!("http://127.0.0.1:{port}"), "username": "ana-qa", "password": ""}),
        json!({"origin": format!("http://127.0.0.1:{port}"), "username": "ana-qa", "password": format!("{TOKEN}\notra")}),
    ] {
        let (answer, text) = call(&setup, fetch_request(&setup, port, credentials));
        assert_eq!(answer["error"]["code"], "invalid_arguments", "{text}");
        assert!(!text.contains(TOKEN), "{text}");
    }
    assert!(seen.lock().unwrap().is_empty());
}
