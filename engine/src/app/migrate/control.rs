//! Stopping and starting what uses the data folder: the supervised processes, the daemon and its
//! LaunchAgent, and the check that nothing else keeps a file open there.

use anyhow::{Result, bail, ensure};
use serde_json::{Value, json};
use std::{
    io::{BufRead, Write},
    os::unix::{net::UnixStream, process::CommandExt},
    path::Path,
    process::{Command, Stdio},
    time::{Duration, Instant},
};

const LABEL: &str = "cl.butake.stack.daemon";

/// The programs (`name (pid)`) that `lsof -F pcn` says keep a file open, leaving out the lock the
/// migration itself holds (`lock`): it is closed after the move, not something to wait for.
pub(super) fn holders(report: &str, lock: &Path) -> Vec<String> {
    let lock = lock.to_string_lossy();
    let (mut pid, mut command) = (String::new(), String::new());
    let mut found: Vec<String> = vec![];
    for line in report.lines() {
        if let Some(value) = line.strip_prefix('p') {
            pid = value.to_string();
        } else if let Some(value) = line.strip_prefix('c') {
            command = value.to_string();
        } else if let Some(name) = line.strip_prefix('n') {
            let holder = format!("{command} ({pid})");
            if name != lock && !found.contains(&holder) {
                found.push(holder);
            }
        }
    }
    found
}

/// What the migration needs from the running system. Tests use a fake; the app and the CLI use
/// [`Live`].
pub trait Control {
    /// Ids of the supervised processes running on the data in `root` (to start them again).
    fn running(&self, root: &Path) -> Vec<String>;
    /// Whether the LaunchAgent is loaded (and so must be booted out and in again).
    fn agent_loaded(&self) -> bool;
    /// Stops every process of `root`, then the daemon (booting the agent out when `agent`); returns
    /// once no daemon holds the folder.
    fn stop(&self, root: &Path, agent: bool) -> Result<()>;
    /// Processes that still have a file open under `root` (`name (pid)`).
    fn open_files(&self, root: &Path) -> Result<Vec<String>>;
    /// Starts the daemon on `root` (through the agent's `plist` when `agent`), starts again what
    /// was `running` and checks that each one runs and answers. One line per process.
    fn start(
        &self,
        root: &Path,
        agent: bool,
        plist: &Path,
        running: &[String],
    ) -> Result<Vec<Value>>;
}

/// The real system. `launchd: false` (an isolated home, `BUTAKE_DEVTOOLS_HOME`) never calls
/// launchctl: the daemon, if any, is the one started by hand on that folder.
pub struct Live {
    pub launchd: bool,
}

fn domain() -> String {
    // SAFETY: `geteuid` takes no arguments, cannot fail and touches no memory.
    format!("gui/{}", unsafe { libc::geteuid() })
}

/// One request to the daemon of `root` over its socket.
fn request(root: &Path, method: &str, params: Value, wait: Duration) -> Result<Value> {
    let mut stream = UnixStream::connect(root.join("run/daemon.sock"))?;
    stream.set_read_timeout(Some(wait))?;
    stream.set_write_timeout(Some(Duration::from_secs(5)))?;
    writeln!(
        stream,
        "{}",
        json!({"id": 1, "method": method, "params": params})
    )?;
    let mut data = Vec::new();
    std::io::Read::take(std::io::BufReader::new(stream), 20 * 1024 * 1024)
        .read_until(b'\n', &mut data)?;
    let response: Value = serde_json::from_slice(&data)?;
    ensure!(response["ok"] == true, "daemon_request_failed");
    Ok(response["value"].clone())
}

fn states(root: &Path) -> Vec<(String, String)> {
    request(root, "stackStatus", json!({}), Duration::from_secs(30))
        .ok()
        .and_then(|v| v["processes"].as_array().cloned())
        .unwrap_or_default()
        .iter()
        .filter_map(|p| {
            Some((
                p["spec"]["id"].as_str()?.to_string(),
                p["status"]["state"].as_str()?.to_string(),
            ))
        })
        .collect()
}

/// Whether a daemon holds `root` (its lock is taken).
pub fn daemon_holds(root: &Path) -> bool {
    use std::os::fd::AsRawFd;
    let Ok(lock) = std::fs::OpenOptions::new()
        .read(true)
        .open(root.join("run/daemon.lock"))
    else {
        return false;
    };
    // SAFETY: `flock` takes a descriptor and flags and touches no memory; the descriptor belongs
    // to `lock`, which is open until the end of this function.
    let free = unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } == 0;
    // SAFETY: same descriptor as above, still open.
    free.then(|| unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_UN) });
    !free
}

/// Answers on `port`: MySQL and MariaDB greet first, Redis and Valkey answer PING, the rest
/// accept the connection.
fn answers(engine: &str, port: u16) -> bool {
    let Ok(mut stream) = std::net::TcpStream::connect_timeout(
        &([127, 0, 0, 1], port).into(),
        Duration::from_secs(2),
    ) else {
        return false;
    };
    let _ = stream.set_read_timeout(Some(Duration::from_secs(5)));
    let mut buffer = [0u8; 64];
    match engine {
        "mysql" | "mariadb" => {
            matches!(std::io::Read::read(&mut stream, &mut buffer), Ok(n) if n > 0)
        }
        "redis" | "valkey" => {
            stream.write_all(b"PING\r\n").is_ok()
                && matches!(std::io::Read::read(&mut stream, &mut buffer), Ok(n) if n > 0 && (buffer[0] == b'+' || buffer[0] == b'-'))
        }
        _ => true,
    }
}

impl Control for Live {
    fn running(&self, root: &Path) -> Vec<String> {
        states(root)
            .into_iter()
            .filter(|(_, s)| s == "running")
            .map(|(id, _)| id)
            .collect()
    }

    fn agent_loaded(&self) -> bool {
        self.launchd
            && Command::new("/bin/launchctl")
                .args(["print", &format!("{}/{LABEL}", domain())])
                .env_clear()
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .status()
                .is_ok_and(|s| s.success())
    }

    fn stop(&self, root: &Path, agent: bool) -> Result<()> {
        if root.join("run/daemon.sock").exists() {
            // In the supervisor's own order, each with its wait (MySQL up to 120 s); the daemon stays.
            let _ = request(root, "stopAll", json!({}), Duration::from_secs(400));
        }
        if agent && self.launchd {
            let status = Command::new("/bin/launchctl")
                .args(["bootout", &format!("{}/{LABEL}", domain())])
                .env_clear()
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .status()?;
            ensure!(
                status.success() || !self.agent_loaded(),
                "migration_daemon_running"
            );
        } else if root.join("run/daemon.sock").exists() {
            let _ = request(root, "shutdown", json!({}), Duration::from_secs(30));
        }
        let deadline = Instant::now() + Duration::from_secs(60);
        while daemon_holds(root) {
            ensure!(Instant::now() < deadline, "migration_daemon_running");
            std::thread::sleep(Duration::from_millis(200));
        }
        Ok(())
    }

    fn open_files(&self, root: &Path) -> Result<Vec<String>> {
        let mut command = Command::new("/usr/sbin/lsof");
        command
            .args(["-n", "-P", "-F", "pcn", "+D"])
            .arg(root)
            .env_clear();
        // `lsof` leaves with 1 when nothing is open, so that is no failure; but a run that was cut
        // short, passed its time or could not start proves nothing and must not read as "all closed".
        let output = crate::core::process::capture_watched(
            command,
            64 << 20,
            Duration::from_secs(300),
            "migration_failed",
            None,
        )?;
        ensure!(
            !(output.timed_out || output.cancelled || output.cut)
                && matches!(output.code, Some(0 | 1)),
            "migration_failed"
        );
        Ok(holders(&output.stdout, &root.join(super::LOCK)))
    }

    fn start(
        &self,
        root: &Path,
        agent: bool,
        plist: &Path,
        running: &[String],
    ) -> Result<Vec<Value>> {
        if agent && self.launchd {
            let status = Command::new("/bin/launchctl")
                .args(["bootstrap", &domain()])
                .arg(plist)
                .env_clear()
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .status()?;
            ensure!(status.success(), "migration_start_failed");
        } else if !running.is_empty() {
            // Its own process group, like `request_sync`: closing the one that ran this command
            // (^C, SIGHUP) must not take the new daemon with it.
            Command::new(std::env::current_exe()?.canonicalize()?)
                .arg("daemon")
                .process_group(0)
                .env_clear()
                .env("BUTAKE_STACK_HOME", root)
                .stdin(Stdio::null())
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .spawn()?;
        } else {
            return Ok(vec![]);
        }
        let deadline = Instant::now() + Duration::from_secs(30);
        while UnixStream::connect(root.join("run/daemon.sock")).is_err() {
            ensure!(Instant::now() < deadline, "migration_start_failed");
            std::thread::sleep(Duration::from_millis(200));
        }
        for (id, state) in states(root) {
            if running.contains(&id) && state != "running" {
                let _ = request(root, "start", json!({"id": id}), Duration::from_secs(120));
            }
        }
        // Each one running, then each service answering on its port.
        let deadline = Instant::now() + Duration::from_secs(120);
        let missing = loop {
            let now = states(root);
            let missing: Vec<&String> = running
                .iter()
                .filter(|id| !now.iter().any(|(i, s)| i == *id && s == "running"))
                .collect();
            if missing.is_empty() || Instant::now() > deadline {
                break missing.into_iter().cloned().collect::<Vec<_>>();
            }
            std::thread::sleep(Duration::from_millis(500));
        };
        let config = crate::core::store::Store::new(root.to_path_buf())?.config()?;
        let mut report = vec![];
        let mut failed = !missing.is_empty();
        for id in running {
            let engine = id.strip_prefix("stack.").filter(|e| {
                crate::web::services::engines::recipe(e).is_some() || ["mysql", "redis"].contains(e)
            });
            let port = engine.map(|e| crate::web::services::engines::port(&config, e));
            let started = !missing.contains(id);
            let answered = match (engine, port) {
                (Some(engine), Some(port)) if started && port > 0 => {
                    let deadline = Instant::now() + Duration::from_secs(60);
                    loop {
                        if answers(engine, port) {
                            break true;
                        }
                        if Instant::now() > deadline {
                            break false;
                        }
                        std::thread::sleep(Duration::from_millis(500));
                    }
                }
                _ => started,
            };
            failed |= !answered;
            report.push(json!({"id": id, "running": started, "port": port, "answers": answered}));
        }
        if failed {
            bail!("migration_start_failed:{}", serde_json::to_string(&report)?);
        }
        Ok(report)
    }
}
