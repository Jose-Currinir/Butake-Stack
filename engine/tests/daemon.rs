use serde_json::{json, Value};
use std::{
    fs,
    io::{BufRead, BufReader, Write},
    os::unix::{fs::PermissionsExt, net::UnixStream},
    path::Path,
    process::{Child, Command, Stdio},
    thread,
    time::{Duration, Instant},
};

struct Daemon(Child);
impl Drop for Daemon {
    fn drop(&mut self) {
        unsafe {
            libc::kill(self.0.id() as i32, libc::SIGTERM);
        }
        for _ in 0..150 {
            if self.0.try_wait().ok().flatten().is_some() {
                return;
            }
            thread::sleep(Duration::from_millis(100));
        }
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}
fn call(socket: &Path, method: &str, id: &str) -> Value {
    let mut stream = UnixStream::connect(socket).unwrap();
    stream
        .set_read_timeout(Some(Duration::from_secs(15)))
        .unwrap();
    writeln!(
        stream,
        "{}",
        json!({"id":7,"method":method,"params":{"id":id,"tail":2000}})
    )
    .unwrap();
    let mut line = String::new();
    BufReader::new(stream).read_line(&mut line).unwrap();
    serde_json::from_str(&line).unwrap()
}
fn wait_for(mut condition: impl FnMut() -> bool, seconds: u64) {
    let deadline = Instant::now() + Duration::from_secs(seconds);
    while !condition() {
        assert!(Instant::now() < deadline, "condition timed out");
        thread::sleep(Duration::from_millis(50));
    }
}
fn status(socket: &Path, id: &str) -> Value {
    call(socket, "status", "")["value"]
        .as_array()
        .unwrap()
        .iter()
        .find(|entry| entry["status"]["id"] == id)
        .unwrap()["status"]
        .clone()
}
fn alive(pid: u32) -> bool {
    unsafe { libc::kill(pid as i32, 0) == 0 }
}

#[test]
fn daemon_lifecycle_backoff_events_and_rotation() {
    let temp = tempfile::tempdir_in("/tmp").unwrap();
    let home = temp.path().join("stack");
    fs::create_dir_all(home.join("projects")).unwrap();
    let runtime = home.join("runtimes/php/8.2/bin");
    fs::create_dir_all(&runtime).unwrap();
    let source = temp.path().join("probe.rs");
    fs::write(&source, include_str!("fixtures/process.rs")).unwrap();
    let rustc = dirs::home_dir().unwrap().join(".cargo/bin/rustc");
    assert!(Command::new(rustc)
        .arg(&source)
        .args(["--edition=2021", "-o"])
        .arg(runtime.join("php"))
        .status()
        .unwrap()
        .success());
    let processes: Vec<_> = ["sleep", "fail", "tree", "flood"]
        .iter()
        .map(|name| json!({"name":name,"program":"php","args":[name],"autostart":false}))
        .collect();
    fs::write(home.join("projects/demo.json"), serde_json::to_vec(&json!({"id":"demo","name":"Demo","path":temp.path(),"domains":["demo.test"],"https":false,"kind":"php","runtime":{"php":"8.2"},"docroot":".","services":[],"databases":[],"processes":processes,"enabled":true})).unwrap()).unwrap();
    let mut daemon = Daemon(
        Command::new(env!("CARGO_BIN_EXE_butake-stack"))
            .arg("daemon")
            .env("BUTAKE_STACK_HOME", &home)
            .stdout(Stdio::null())
            .spawn()
            .unwrap(),
    );
    let socket = home.join("run/daemon.sock");
    wait_for(|| socket.exists(), 10);
    assert_eq!(
        fs::metadata(&socket).unwrap().permissions().mode() & 0o777,
        0o600
    );
    assert_eq!(
        call(&socket, "status", "")["value"]
            .as_array()
            .unwrap()
            .len(),
        4
    );
    let duplicate = Command::new(env!("CARGO_BIN_EXE_butake-stack"))
        .arg("daemon")
        .env("BUTAKE_STACK_HOME", &home)
        .output()
        .unwrap();
    assert!(!duplicate.status.success());
    assert_eq!(
        serde_json::from_slice::<Value>(&duplicate.stdout).unwrap()["error"]["code"],
        "daemon_already_running"
    );
    assert_eq!(call(&socket, "start", "../bad")["ok"], false);

    let mut subscription = UnixStream::connect(&socket).unwrap();
    subscription
        .set_read_timeout(Some(Duration::from_secs(10)))
        .unwrap();
    writeln!(subscription, "{}", json!({"id":1,"method":"subscribe"})).unwrap();
    let mut events = BufReader::new(subscription);
    let mut line = String::new();
    events.read_line(&mut line).unwrap();
    assert_eq!(serde_json::from_str::<Value>(&line).unwrap()["ok"], true);
    assert_eq!(call(&socket, "start", "demo.sleep")["ok"], true);
    wait_for(|| status(&socket, "demo.sleep")["state"] == "running", 5);
    let original = status(&socket, "demo.sleep")["pid"].as_u64().unwrap() as u32;
    line.clear();
    events.read_line(&mut line).unwrap();
    assert_eq!(
        serde_json::from_str::<Value>(&line).unwrap()["event"],
        "process.state"
    );
    assert_eq!(call(&socket, "restart", "demo.sleep")["ok"], true);
    wait_for(|| status(&socket, "demo.sleep")["state"] == "running", 5);
    assert!(!alive(original));
    let restarted = status(&socket, "demo.sleep")["pid"].as_u64().unwrap() as u32;
    assert_ne!(original, restarted);
    unsafe {
        libc::kill(restarted as i32, libc::SIGKILL);
    }
    wait_for(
        || {
            status(&socket, "demo.sleep")["restarts"].as_u64().unwrap() >= 1
                && status(&socket, "demo.sleep")["state"] == "running"
        },
        5,
    );
    let recovered = status(&socket, "demo.sleep")["pid"].as_u64().unwrap() as u32;
    assert_eq!(call(&socket, "stop", "demo.sleep")["ok"], true);
    assert!(!alive(recovered));
    assert_eq!(status(&socket, "demo.sleep")["state"], "stopped");

    assert_eq!(call(&socket, "start", "demo.fail")["ok"], true);
    wait_for(
        || {
            status(&socket, "demo.fail")["restarts"] == 4
                && status(&socket, "demo.fail")["state"] == "crashed"
        },
        25,
    );
    thread::sleep(Duration::from_millis(1200));
    assert_eq!(status(&socket, "demo.fail")["restarts"], 4);

    assert_eq!(call(&socket, "start", "demo.flood")["ok"], true);
    wait_for(|| home.join("logs/demo.flood.log.3").exists(), 15);
    assert!(
        fs::metadata(home.join("logs/demo.flood.log"))
            .unwrap()
            .len()
            <= 5 * 1024 * 1024
    );
    let tail = call(&socket, "logs", "demo.flood");
    assert!(tail["value"].as_array().unwrap().len() <= 2000);
    for entry in fs::read_dir(home.join("logs")).unwrap() {
        assert!(!fs::read_to_string(entry.unwrap().path())
            .unwrap()
            .contains("synthetic-test-value"));
    }
    let flood_pid = status(&socket, "demo.flood")["pid"].as_u64().unwrap() as u32;
    assert_eq!(call(&socket, "start", "demo.tree")["ok"], true);
    wait_for(
        || {
            call(&socket, "logs", "demo.tree")["value"]
                .as_array()
                .unwrap()
                .iter()
                .any(|line| line.as_str().unwrap().starts_with("child:"))
        },
        5,
    );
    let tree_pid = status(&socket, "demo.tree")["pid"].as_u64().unwrap() as u32;
    let child_pid: u32 = call(&socket, "logs", "demo.tree")["value"]
        .as_array()
        .unwrap()
        .iter()
        .find_map(|line| line.as_str()?.strip_prefix("child:")?.parse().ok())
        .unwrap();
    // SIGTERM verifies signal handling and cleanup in reverse start order.
    unsafe {
        libc::kill(daemon.0.id() as i32, libc::SIGTERM);
    }
    wait_for(|| daemon.0.try_wait().unwrap().is_some(), 15);
    wait_for(
        || !alive(tree_pid) && !alive(child_pid) && !alive(flood_pid),
        5,
    );
    assert!(!socket.exists());
    for pid in [
        original, restarted, recovered, tree_pid, child_pid, flood_pid,
    ] {
        let output = Command::new("/usr/bin/pgrep")
            .args(["-x", "-P", &pid.to_string(), "php"])
            .output()
            .unwrap();
        assert!(!output.status.success());
        assert!(output.stdout.is_empty());
    }
}

#[test]
fn isolated_agent_preview_cannot_apply() {
    let temp = tempfile::tempdir_in("/tmp").unwrap();
    for request in [
        json!({"method":"installAgent","preview":true}),
        json!({"method":"installAgent","confirmed":true}),
    ] {
        let mut child = Command::new(env!("CARGO_BIN_EXE_butake-stack"))
            .env("BUTAKE_STACK_HOME", temp.path())
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
        let response: Value =
            serde_json::from_slice(&child.wait_with_output().unwrap().stdout).unwrap();
        if request["preview"] == true {
            let plist = response["value"]["plist"].as_str().unwrap();
            assert!(
                plist.contains("RunAtLoad")
                    && plist.contains("KeepAlive")
                    && plist.contains("daemon")
            );
            let path = temp.path().join("preview.plist");
            fs::write(&path, plist).unwrap();
            assert!(Command::new("/usr/bin/plutil")
                .arg("-lint")
                .arg(path)
                .status()
                .unwrap()
                .success());
        } else {
            assert_eq!(response["ok"], false);
        }
    }
}
