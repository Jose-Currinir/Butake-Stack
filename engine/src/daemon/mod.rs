//! The supervisor daemon: its socket protocol, the processes it keeps alive, their logs, the
//! launch agent that starts it with the session and the trust of the local certificate.

mod dispatch;
pub mod launch_agent;
pub mod logs;
mod processes;
mod public;
pub mod redact;
pub mod supervisor;
pub mod trust;

pub use dispatch::dispatch;
pub use processes::*;

use crate::core::fsutil::write_private;
use crate::{
    core::store::Store,
    daemon::supervisor::{ProcessSpec, Supervisor, SupervisorReader},
};
use anyhow::{Result, ensure};
use serde_json::{Value, json};
use std::{
    fs::{self, OpenOptions},
    os::{
        fd::AsRawFd,
        unix::fs::{OpenOptionsExt, PermissionsExt},
    },
    path::{Path, PathBuf},
    sync::Arc,
    time::Duration,
};
use tokio::{
    io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader},
    net::{UnixListener, UnixStream},
    sync::{Mutex, watch},
};

const MAX_FRAME: u64 = 1_048_576;
static WEB_FDS: std::sync::OnceLock<WebFds> = std::sync::OnceLock::new();
static LISTENER_STATUS: std::sync::OnceLock<serde_json::Map<String, Value>> =
    std::sync::OnceLock::new();
/// Sites shared through a public tunnel. Memory only: a restarted daemon shares nothing.
static SHARES: std::sync::Mutex<std::collections::BTreeSet<String>> =
    std::sync::Mutex::new(std::collections::BTreeSet::new());
/// In-daemon servers (mail catcher, dump receiver): their configuration, task, or who holds the port.
type Extra = (String, Option<tokio::task::JoinHandle<()>>, Option<String>);
static EXTRAS: std::sync::Mutex<std::collections::BTreeMap<&'static str, Extra>> =
    std::sync::Mutex::new(std::collections::BTreeMap::new());

fn fingerprint(content: &str) -> String {
    use sha2::{Digest, Sha256};
    Sha256::digest(content.as_bytes())
        .iter()
        .take(8)
        .map(|b| format!("{b:02x}"))
        .collect()
}

/// Starts, restarts or stops the mail catcher and the dump receiver to match `stack.json`.
async fn sync_extras(store: &Store, events: &tokio::sync::broadcast::Sender<Value>) {
    let Ok(config) = store.config() else { return };
    let mail = config.mail.clone().unwrap_or_default();
    let dumps = config.dumps.clone().unwrap_or_default();
    let wanted: [(&'static str, Option<(u16, String)>); 2] = [
        (
            "mail",
            mail.enabled
                .then(|| (mail.port, serde_json::to_string(&mail).unwrap_or_default())),
        ),
        (
            "dumps",
            dumps.enabled.then(|| (dumps.port, dumps.port.to_string())),
        ),
    ];
    for (name, want) in wanted {
        let keep = EXTRAS.lock().ok().and_then(|extras| {
            let (signature, task, _) = extras.get(name)?;
            Some(
                want.as_ref().is_some_and(|(_, s)| s == signature)
                    && task.as_ref().is_some_and(|t| !t.is_finished()),
            )
        });
        if keep == Some(true) {
            continue;
        }
        let previous = EXTRAS.lock().ok().and_then(|mut e| e.remove(name));
        if let Some((_, Some(task), _)) = previous {
            task.abort();
            // The listener is released only when the aborted task has unwound.
            let _ = task.await;
        }
        let Some((port, signature)) = want else {
            continue;
        };
        let entry = match tokio::net::TcpListener::bind(("127.0.0.1", port)).await {
            Ok(listener) => {
                let task = if name == "mail" {
                    let Ok(dir) = store.directory("mail") else {
                        continue;
                    };
                    tokio::spawn(crate::web::tools::mail::serve(listener, dir, mail.clone()))
                } else {
                    tokio::spawn(crate::web::tools::dumps::serve(listener, events.clone()))
                };
                (signature, Some(task), None)
            }
            Err(_) => {
                // `port_owner` runs `lsof`: keep it off the async threads.
                let owner = tokio::task::spawn_blocking(move || {
                    crate::web::net::listeners::port_owner(port, false)
                })
                .await
                .ok()
                .flatten();
                (signature, None, Some(owner.unwrap_or_default()))
            }
        };
        if let Ok(mut extras) = EXTRAS.lock() {
            extras.insert(name, entry);
        }
    }
}

fn extras_status(store: &Store) -> Value {
    let config = store.config().ok();
    let mail = config
        .as_ref()
        .and_then(|c| c.mail.clone())
        .unwrap_or_default();
    let dumps = config
        .as_ref()
        .and_then(|c| c.dumps.clone())
        .unwrap_or_default();
    let state = |name: &str| -> (bool, Option<String>) {
        EXTRAS
            .lock()
            .ok()
            .and_then(|e| {
                e.get(name).map(|(_, task, busy)| {
                    (
                        task.as_ref().is_some_and(|t| !t.is_finished()),
                        busy.clone(),
                    )
                })
            })
            .unwrap_or((false, None))
    };
    let (mail_running, mail_busy) = state("mail");
    let (dumps_running, dumps_busy) = state("dumps");
    json!({
        "mail": {"enabled": mail.enabled, "port": mail.port, "running": mail_running, "busy": mail_busy,
                 "count": store.directory("mail").map(|d| crate::web::tools::mail::count(&d)).unwrap_or(0),
                 "retentionDays": mail.retention_days, "maxMessages": mail.max_messages},
        "dumps": {"enabled": dumps.enabled, "port": dumps.port, "running": dumps_running, "busy": dumps_busy,
                  "last": crate::web::tools::dumps::latest_id()},
    })
}

/// Public address cloudflared printed for a shared site, from its log.
pub fn tunnel_url(lines: &[String]) -> Option<String> {
    lines.iter().rev().find_map(|line| {
        let start = line.find("https://")?;
        let candidate: String = line[start..]
            .chars()
            .take_while(|c| c.is_ascii_alphanumeric() || matches!(c, ':' | '/' | '.' | '-'))
            .collect();
        let host = candidate.strip_prefix("https://")?;
        (host.ends_with(".trycloudflare.com")
            && host != "api.trycloudflare.com"
            && host
                .bytes()
                .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == b'.' || c == b'-'))
        .then_some(candidate)
    })
}

pub fn share_arguments(http_port: u16, domain: &str) -> Vec<String> {
    [
        "tunnel",
        "--no-autoupdate",
        "--url",
        &format!("http://127.0.0.1:{http_port}"),
        "--http-host-header",
        domain,
    ]
    .iter()
    .map(|s| s.to_string())
    .collect()
}

/// Version of the socket protocol between the CLI and the daemon. They are the same binary, but
/// the daemon is a LaunchAgent that outlives the app: after an update a new CLI may reach an old
/// daemon. Raise it when a request or an answer changes shape. Every answer carries it; one with
/// another value, or none (0.1.3 and earlier), gets the daemon restarted once.
pub const PROTOCOL: u64 = 1;

/// The daemon that answered speaks another version of the protocol (or predates it).
fn outdated(response: &Value) -> bool {
    response["protocol"].as_u64() != Some(PROTOCOL)
}

pub fn request_sync(store: &Store, method: &str, params: Value, start: bool) -> Result<Value> {
    use std::os::unix::net::UnixStream as Stream;
    let socket = store.directory("run")?.join("daemon.sock");
    if start && Stream::connect(&socket).is_err() {
        start_daemon(store, &socket)?;
    }
    let mut response = exchange(&socket, method, &params)?;
    if outdated(&response) {
        restart_outdated(store, &socket)?;
        response = exchange(&socket, method, &params)?;
        ensure!(!outdated(&response), "daemon_outdated");
    }
    if response["ok"] != true {
        // The daemon names the cause when it is a public code; anything else stays generic.
        let code = response["error"]["code"].as_str().unwrap_or_default();
        if let Some(code) = crate::PUBLIC_ERRORS.iter().find(|public| **public == code) {
            anyhow::bail!("{code}");
        }
        anyhow::bail!("daemon_request_failed");
    }
    Ok(response["value"].clone())
}

/// One request on the socket and its answer, whole.
fn exchange(socket: &Path, method: &str, params: &Value) -> Result<Value> {
    use std::{
        io::{BufRead, Write},
        os::unix::net::UnixStream as Stream,
    };
    let mut stream = Stream::connect(socket)?;
    stream.set_read_timeout(Some(Duration::from_secs(30)))?;
    stream.set_write_timeout(Some(Duration::from_secs(5)))?;
    writeln!(
        stream,
        "{}",
        json!({"id":1,"method":method,"params":params})
    )?;
    let mut data = Vec::new();
    std::io::Read::take(std::io::BufReader::new(stream), 20 * 1024 * 1024)
        .read_until(b'\n', &mut data)?;
    Ok(serde_json::from_slice(&data)?)
}

/// Starts a daemon of this same binary for `store` and waits until it listens.
fn start_daemon(store: &Store, socket: &Path) -> Result<()> {
    use std::{
        os::unix::{net::UnixStream as Stream, process::CommandExt},
        process::{Command, Stdio},
    };
    let mut child = Command::new(std::env::current_exe()?.canonicalize()?)
        .arg("daemon")
        .env_clear()
        .env("BUTAKE_STACK_HOME", store.root())
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .process_group(0)
        .spawn()?;
    let mut deadline = std::time::Instant::now() + Duration::from_secs(5);
    let mut exited = false;
    while Stream::connect(socket).is_err() {
        // A daemon that lost the race (`daemon_already_running`) leaves; the winner opens the
        // socket in a moment, so keep trying for a short while instead of failing.
        if !exited && child.try_wait()?.is_some() {
            exited = true;
            deadline = deadline.min(std::time::Instant::now() + Duration::from_secs(3));
        }
        ensure!(std::time::Instant::now() < deadline, "daemon_start_failed");
        std::thread::sleep(Duration::from_millis(50));
    }
    Ok(())
}

/// Stops a daemon of another protocol and starts the current one: through launchd when the
/// session agent serves this very store (so it stays the agent's), or as a child otherwise. Only
/// that agent is ever touched: a test or a QA store never restarts the user's daemon.
fn restart_outdated(store: &Store, socket: &Path) -> Result<()> {
    use std::os::unix::net::UnixStream as Stream;
    let _ = exchange(socket, "shutdown", &json!({}));
    let deadline = std::time::Instant::now() + Duration::from_secs(15);
    while Stream::connect(socket).is_ok() {
        ensure!(std::time::Instant::now() < deadline, "daemon_outdated");
        std::thread::sleep(Duration::from_millis(100));
    }
    if launch_agent::serves(store.root()) {
        // SAFETY: `geteuid` takes no arguments, cannot fail and touches no memory.
        let domain = format!("gui/{}/cl.butake.stack.daemon", unsafe { libc::geteuid() });
        let started = std::process::Command::new("/bin/launchctl")
            .args(["kickstart", &domain])
            .env_clear()
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .status()
            .is_ok_and(|s| s.success());
        if started {
            let deadline = std::time::Instant::now() + Duration::from_secs(10);
            while Stream::connect(socket).is_err() {
                ensure!(std::time::Instant::now() < deadline, "daemon_start_failed");
                std::thread::sleep(Duration::from_millis(50));
            }
            return Ok(());
        }
    }
    start_daemon(store, socket)
}
struct DaemonFiles {
    socket: PathBuf,
    _lock: fs::File,
}
impl Drop for DaemonFiles {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.socket);
    }
}

#[derive(Clone, Copy, Default)]
pub struct WebFds {
    pub http: Option<i32>,
    pub https: Option<i32>,
    pub https_udp: Option<i32>,
}

pub async fn run() -> Result<()> {
    let store = Store::from_environment()?;
    // A data folder halfway through being moved is not served.
    ensure!(
        !crate::app::migrate::blocks_daemon(store.root()),
        "migration_in_progress"
    );
    let run = store.directory("run")?;
    let lock = OpenOptions::new()
        .create(true)
        .truncate(false)
        .read(true)
        .write(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW)
        .open(run.join("daemon.lock"))?;
    ensure!(
        // SAFETY: `flock` takes a descriptor and flags and touches no memory; the descriptor
        // belongs to `lock`, which is open for the whole call (and stays open until `run` returns).
        unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } == 0,
        "daemon_already_running"
    );
    let socket = run.join("daemon.sock");
    if socket.symlink_metadata().is_ok() {
        use std::os::unix::fs::FileTypeExt;
        ensure!(
            socket.symlink_metadata()?.file_type().is_socket(),
            "unsafe_socket_path"
        );
        fs::remove_file(&socket)?;
    }
    let listener = UnixListener::bind(&socket)?;
    fs::set_permissions(&socket, fs::Permissions::from_mode(0o600))?;
    let _files = DaemonFiles {
        socket,
        _lock: lock,
    };
    let mut listeners = crate::web::net::listeners::Listeners::open(&store.config()?);
    let _ = WEB_FDS.set(listeners.fds());
    let _ = LISTENER_STATUS.set(listeners.status.clone());
    if let Some(socket) = listeners.take_dns_udp() {
        let tlds = Arc::new(store.config()?.tld);
        tokio::spawn(crate::web::net::dns::serve_udp(socket, tlds));
    }
    if let Some(listener) = listeners.take_dns_tcp() {
        let tlds = Arc::new(store.config()?.tld);
        tokio::spawn(crate::web::net::dns::serve_tcp(listener, tlds));
    }
    // Signals first: startup can take long (orphans, first database initialization) and must not
    // leave the processes already started behind when it is interrupted.
    let mut term = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())?;
    let mut interrupt = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::interrupt())?;
    let _ = crate::daemon::supervisor::PID_DIR.set(store.directory("run")?.join("pids"));
    crate::daemon::supervisor::reap_orphans().await;
    let mut supervisor = Supervisor::new(store.directory("logs")?);
    let started = async {
        supervisor
            .reload(blocking_specs(listeners.fds()).await?)
            .await?;
        sync_extras(&store, &supervisor.events).await;
        Ok::<(), anyhow::Error>(())
    }
    .await;
    if let Err(error) = started {
        supervisor.shutdown().await;
        return Err(error);
    }
    let observer = supervisor.reader();
    let supervisor = Arc::new(Mutex::new(supervisor));
    let (shutdown, mut stopped) = watch::channel(false);
    loop {
        tokio::select! { biased;
            _ = term.recv() => break,
            _ = interrupt.recv() => break,
            _ = stopped.changed() => break,
            connection = listener.accept() => {
                // A transient accept error (descriptors exhausted) or a client that left at once
                // must not end the daemon and orphan its processes.
                let Ok((stream, _)) = connection else {
                    tokio::time::sleep(Duration::from_millis(100)).await;
                    continue;
                };
                if !same_user(&stream).unwrap_or(false) { continue; }
                let supervisor = supervisor.clone(); let shutdown = shutdown.clone();
                let observer = observer.clone();
                tokio::spawn(async move { let _ = serve(stream, supervisor, observer, shutdown).await; });
            }
        }
    }
    let _ = shutdown.send(true);
    supervisor.lock().await.shutdown().await;
    Ok(())
}

fn same_user(stream: &UnixStream) -> Result<bool> {
    #[cfg(target_os = "macos")]
    {
        let mut uid = 0;
        let mut gid = 0;
        ensure!(
            // SAFETY: the descriptor belongs to `stream`, open for the call, and `uid` and `gid` are
            // live local integers that `getpeereid` writes once each.
            unsafe { libc::getpeereid(stream.as_raw_fd(), &mut uid, &mut gid) } == 0,
            "peer_unavailable"
        );
        // SAFETY: `geteuid` takes no arguments, cannot fail and touches no memory.
        Ok(uid == unsafe { libc::geteuid() })
    }
    #[cfg(not(target_os = "macos"))]
    {
        // SAFETY: `geteuid` takes no arguments, cannot fail and touches no memory.
        Ok(stream.peer_cred()?.uid() == unsafe { libc::geteuid() })
    }
}

/// Notes why the daemon could not run in `logs/daemon.err` (0600), and on stderr in debug mode.
pub fn record_failure(error: &anyhow::Error) {
    if std::env::var_os("BUTAKE_STACK_DEBUG").is_some() {
        eprintln!("{error:#}");
    }
    let Ok(store) = Store::from_environment() else {
        return;
    };
    let Ok(dir) = store.directory("logs") else {
        return;
    };
    if let Ok(mut file) = OpenOptions::new()
        .create(true)
        .write(true)
        .truncate(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW)
        .open(dir.join("daemon.err"))
    {
        use std::io::Write;
        let _ = writeln!(file, "{error:#}");
    }
}

pub fn failure(id: Value, code: &str, key: &str) -> Value {
    json!({"id":id,"ok":false,"error":{"code":code,"messageKey":key},"protocol":PROTOCOL})
}
async fn frame(reader: &mut BufReader<tokio::net::unix::OwnedReadHalf>) -> Result<Option<Value>> {
    let mut bytes = Vec::new();
    let count = tokio::time::timeout(
        Duration::from_secs(30),
        reader.take(MAX_FRAME + 1).read_until(b'\n', &mut bytes),
    )
    .await??;
    if count == 0 {
        return Ok(None);
    }
    ensure!(
        count as u64 <= MAX_FRAME && bytes.last() == Some(&b'\n'),
        "invalid_frame"
    );
    Ok(Some(serde_json::from_slice(&bytes)?))
}
async fn write(writer: &mut tokio::net::unix::OwnedWriteHalf, value: &Value) -> Result<()> {
    let mut data = serde_json::to_vec(value)?;
    data.push(b'\n');
    tokio::time::timeout(Duration::from_secs(5), writer.write_all(&data)).await??;
    Ok(())
}
async fn serve(
    stream: UnixStream,
    supervisor: Arc<Mutex<Supervisor>>,
    observer: SupervisorReader,
    shutdown: watch::Sender<bool>,
) -> Result<()> {
    let (read, mut writer) = stream.into_split();
    let mut reader = BufReader::new(read);
    while let Some(request) = frame(&mut reader).await? {
        let id = request.get("id").cloned().unwrap_or(Value::Null);
        if request["method"] == "subscribe" {
            let mut events = observer.events.subscribe();
            let topic = request["params"]["topic"].as_str();
            let process = request["params"]["process"].as_str();
            let mut stopped = shutdown.subscribe();
            write(
                &mut writer,
                &json!({"id":id,"ok":true,"value":true,"protocol":PROTOCOL}),
            )
            .await?;
            loop {
                tokio::select! {
                    _ = stopped.changed() => return Ok(()),
                    // A subscription is one-way after the acknowledgement. EOF closes it
                    // immediately, even when no events match this subscriber.
                    _ = reader.fill_buf() => return Ok(()),
                    event = events.recv() => match event {
                        Ok(value) if match topic {
                            Some("state") => matches!(value["event"].as_str(), Some("process.state" | "stack.changed")),
                            Some("logs") => value["event"] == "stack.changed" ||
                                (value["event"] == "log" && value["id"].as_str() == process),
                            Some("dumps") => value["event"] == "dumps.changed",
                            _ => true,
                        } => write(&mut writer, &value).await?,
                        Ok(_) => {},
                        Err(tokio::sync::broadcast::error::RecvError::Lagged(count)) => write(&mut writer, &json!({"event":"stream.lagged","count":count})).await?,
                        Err(_) => return Ok(()),
                    }
                }
            }
        }
        let result = if matches!(
            request["method"].as_str(),
            Some("status" | "stackStatus" | "logs" | "dumps")
        ) {
            request_read(&request, &observer).await
        } else {
            let mut supervisor = supervisor.lock().await;
            let result = request_action(&request, &mut supervisor).await;
            if result.is_ok()
                && matches!(
                    request["method"].as_str(),
                    Some(
                        "reload"
                            | "share"
                            | "sharePublic"
                            | "cloudflareLogin"
                            | "start"
                            | "stop"
                            | "restart"
                            | "stopAll"
                    )
                )
            {
                let _ = supervisor.events.send(json!({"event":"stack.changed"}));
            }
            result
        };
        let response = match result {
            Ok(value) => json!({"id":id,"ok":true,"value":value,"protocol":PROTOCOL}),
            Err(error) => {
                let code = error.to_string();
                match crate::PUBLIC_ERRORS.iter().find(|public| **public == code) {
                    Some(code) => failure(id, code, &format!("error.{code}")),
                    None => failure(id, "daemon_request_failed", "daemon.requestFailed"),
                }
            }
        };
        write(&mut writer, &response).await?;
        if request["method"] == "shutdown" && response["ok"] == true {
            let _ = shutdown.send(true);
            return Ok(());
        }
    }
    Ok(())
}
/// `specs` reads every project and may wait minutes (the first start of a database initializes
/// its data folder), so it runs on a thread meant for blocking work and not on one of the
/// runtime's, which also serves signals, events and the other requests.
async fn blocking_specs(fds: WebFds) -> Result<Vec<ProcessSpec>> {
    tokio::task::spawn_blocking(move || specs(&Store::from_environment()?, fds)).await?
}
async fn request_read(request: &Value, supervisor: &SupervisorReader) -> Result<Value> {
    let key = request["params"]["id"].as_str().unwrap_or("");
    match request["method"].as_str().unwrap_or("") {
        "status" => Ok(json!(supervisor.status().await)),
        "stackStatus" => {
            let shares: Vec<String> = SHARES
                .lock()
                .map(|s| s.iter().cloned().collect())
                .unwrap_or_default();
            let store = Store::from_environment()?;
            Ok(json!({
                "listeners": LISTENER_STATUS.get().cloned().unwrap_or_default(),
                "processes": supervisor.status().await,
                "extras": extras_status(&store),
                "public": public::status(&store, supervisor),
                "shares": shares.iter().map(|id| {
                    let url = supervisor.logs(&format!("share.{id}"), 400).ok().and_then(|l| tunnel_url(&l));
                    json!({"id": id, "url": url})
                }).collect::<Vec<_>>(),
            }))
        }
        "dumps" => Ok(json!(crate::web::tools::dumps::list(
            request["params"]["after"].as_u64().unwrap_or(0)
        ))),
        "logs" => Ok(json!(supervisor.logs(
            key,
            request["params"]["tail"].as_u64().unwrap_or(200).min(2000) as usize
        )?)),
        _ => anyhow::bail!("unknown_method"),
    }
}

/// The daemon's own requests. Some are asked only by the engine itself through `request_sync`,
/// never by the app: `clearDumps` (from `dumpsClear`), `sharePublic` and `cloudflareLogin` (from
/// `web/net/tunnels.rs`), `reload` (after any change of the configuration).
async fn request_action(request: &Value, supervisor: &mut Supervisor) -> Result<Value> {
    let key = request["params"]["id"].as_str().unwrap_or("");
    match request["method"].as_str().unwrap_or("") {
        "clearDumps" => {
            crate::web::tools::dumps::clear();
            let _ = supervisor.events.send(json!({"event":"dumps.changed"}));
            Ok(json!(true))
        }
        "share" => {
            let store = Store::from_environment()?;
            crate::core::model::validate_id(key)?;
            if request["params"]["on"] == true {
                // Only an existing site that is on can be shared.
                ensure!(store.get(key)?.enabled, "site_off");
                SHARES
                    .lock()
                    .map_err(|_| anyhow::anyhow!("lock"))?
                    .insert(key.to_string());
            } else {
                SHARES
                    .lock()
                    .map_err(|_| anyhow::anyhow!("lock"))?
                    .remove(key);
            }
            let fds = *WEB_FDS.get().unwrap_or(&WebFds::default());
            supervisor.reload(blocking_specs(fds).await?).await?;
            Ok(json!(true))
        }
        // A fixed address (P-35): only an existing site that is on and has one can be shared.
        "sharePublic" => {
            let store = Store::from_environment()?;
            crate::core::model::validate_id(key)?;
            let on = request["params"]["on"] == true;
            if on {
                ensure!(store.get(key)?.enabled, "site_off");
                ensure!(
                    crate::web::net::tunnels::address(&store, key).is_some(),
                    "public_address_missing"
                );
            }
            public::set_shared(key, on);
            let fds = *WEB_FDS.get().unwrap_or(&WebFds::default());
            supervisor.reload(blocking_specs(fds).await?).await?;
            Ok(json!(true))
        }
        "cloudflareLogin" => {
            public::set_login(request["params"]["on"] == true);
            let fds = *WEB_FDS.get().unwrap_or(&WebFds::default());
            supervisor.reload(blocking_specs(fds).await?).await?;
            Ok(json!(true))
        }
        "start" => {
            supervisor.start(key).await?;
            Ok(json!(true))
        }
        "stop" => {
            supervisor.stop(key).await?;
            Ok(json!(true))
        }
        "restart" => {
            supervisor.restart(key).await?;
            Ok(json!(true))
        }
        "reload" => {
            let store = Store::from_environment()?;
            // A site turned off or removed stops being shared.
            let enabled: std::collections::BTreeSet<String> = store
                .list()?
                .into_iter()
                .filter(|p| p.enabled)
                .map(|p| p.id)
                .collect();
            if let Ok(mut shares) = SHARES.lock() {
                shares.retain(|id| enabled.contains(id));
            }
            public::retain(&enabled);
            let fds = *WEB_FDS.get().unwrap_or(&WebFds::default());
            supervisor.reload(blocking_specs(fds).await?).await?;
            sync_extras(&store, &supervisor.events).await;
            Ok(json!(true))
        }
        "shutdown" => Ok(json!(true)),
        // Everything stopped in the supervisor's order, each with its own wait; the daemon stays
        // (moving the data folder boots the agent out next).
        "stopAll" => {
            supervisor.shutdown().await;
            Ok(json!(true))
        }
        _ => anyhow::bail!("unknown_method"),
    }
}

/// Probe only enabled sites, with a fixed number of concurrent subprocesses and an overall
/// budget. A skipped probe is unknown rather than a failed site.
pub fn probe_sites(store: &Store) -> Result<Value> {
    use std::{
        process::Command,
        sync::atomic::{AtomicUsize, Ordering},
        time::Instant,
    };
    let config = store.config()?;
    let projects: Vec<_> = store
        .list()?
        .into_iter()
        .filter(|project| project.enabled)
        .collect();
    let next = AtomicUsize::new(0);
    let deadline = Instant::now() + Duration::from_secs(5);
    let out = std::thread::scope(|scope| {
        let mut workers = Vec::new();
        for _ in 0..projects.len().min(8) {
            workers.push(scope.spawn(|| {
                let mut results = Vec::new();
                while Instant::now() < deadline {
                    let Some(project) = projects.get(next.fetch_add(1, Ordering::Relaxed)) else {
                        break;
                    };
                    let Some(domain) = project.domains.first() else {
                        continue;
                    };
                    let (scheme, port) = if project.https {
                        ("https", config.ports.https)
                    } else {
                        ("http", config.ports.http)
                    };
                    let timeout = deadline
                        .saturating_duration_since(Instant::now())
                        .as_secs_f64()
                        .max(0.01)
                        .to_string();
                    let output = Command::new("/usr/bin/curl")
                        .args([
                            "-s",
                            "-k",
                            "-o",
                            "/dev/null",
                            "-w",
                            "%{http_code}",
                            "--max-time",
                            &timeout,
                        ])
                        .arg(format!("{scheme}://{domain}:{port}/"))
                        .env_clear()
                        .output();
                    let code = output
                        .ok()
                        .and_then(|o| {
                            String::from_utf8_lossy(&o.stdout)
                                .trim()
                                .parse::<u16>()
                                .ok()
                        })
                        .unwrap_or(0);
                    results.push((project.id.clone(), json!(code)));
                }
                results
            }));
        }
        workers
            .into_iter()
            .flat_map(|worker| worker.join().unwrap_or_default())
            .collect()
    });
    Ok(Value::Object(out))
}

/// Streams snapshots for a single view. Subscribe before reading the first snapshot so a
/// change between opening the connection and taking the snapshot cannot be lost.
pub fn watch(store: &Store, topic: &str, process: Option<&str>) -> Result<()> {
    use std::io::{BufRead, Write};
    let (method, params) = match topic {
        "state" => ("stackStatus", json!({})),
        "logs" => {
            let id = process.ok_or_else(|| anyhow::anyhow!("invalid_process_id"))?;
            crate::daemon::supervisor::validate_process_id(id)?;
            ("logs", json!({"id": id, "tail": 500}))
        }
        "dumps" => ("dumps", json!({})),
        _ => anyhow::bail!("unknown_method"),
    };
    let socket = store.directory("run")?.join("daemon.sock");
    let mut stream = std::os::unix::net::UnixStream::connect(socket)?;
    stream.set_read_timeout(Some(Duration::from_secs(15)))?;
    stream.set_write_timeout(Some(Duration::from_secs(5)))?;
    writeln!(
        stream,
        "{}",
        json!({"id":1,"method":"subscribe","params":{"topic":topic,"process":process}})
    )?;
    let mut reader = std::io::BufReader::new(stream);
    let mut frame = String::new();
    ensure!(reader.read_line(&mut frame)? > 0, "daemon_request_failed");
    ensure!(
        serde_json::from_str::<Value>(&frame)?["ok"] == true,
        "daemon_request_failed"
    );

    let mut output = std::io::stdout().lock();
    let mut previous = None;
    loop {
        let value = request_sync(store, method, params.clone(), false)?;
        if previous.as_ref() != Some(&value) {
            writeln!(output, "{value}")?;
            output.flush()?;
            previous = Some(value);
        }
        loop {
            frame.clear();
            match reader.read_line(&mut frame) {
                Ok(0) => return Ok(()),
                Ok(_) => {
                    // Coalesce bursts and skip stale notifications before requesting a fresh snapshot.
                    std::thread::sleep(Duration::from_millis(150));
                    reader.get_ref().set_nonblocking(true)?;
                    let mut disconnected = false;
                    for _ in 0..4096 {
                        frame.clear();
                        match reader.read_line(&mut frame) {
                            Ok(0) => {
                                disconnected = true;
                                break;
                            }
                            Ok(_) => {}
                            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => break,
                            Err(error) => return Err(error.into()),
                        }
                    }
                    if disconnected {
                        return Ok(());
                    }
                    reader.get_ref().set_nonblocking(false)?;
                    break;
                }
                Err(error)
                    if matches!(
                        error.kind(),
                        std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                    ) =>
                {
                    if topic == "state" {
                        break;
                    }
                }
                Err(error) => return Err(error.into()),
            }
        }
    }
}

#[cfg(test)]
mod tests;
