use crate::{
    store::Store,
    supervisor::{ProcessSpec, Supervisor},
};
use anyhow::{ensure, Result};
use serde_json::{json, Value};
use std::{
    fs::{self, OpenOptions},
    os::{
        fd::AsRawFd,
        unix::fs::{OpenOptionsExt, PermissionsExt},
    },
    path::PathBuf,
    sync::Arc,
    time::Duration,
};
use tokio::{
    io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader},
    net::{UnixListener, UnixStream},
    sync::{watch, Mutex},
};

const MAX_FRAME: u64 = 1_048_576;
static WEB_FDS: std::sync::OnceLock<WebFds> = std::sync::OnceLock::new();
static LISTENER_STATUS: std::sync::OnceLock<serde_json::Map<String, Value>> =
    std::sync::OnceLock::new();

pub fn request_sync(store: &Store, method: &str, params: Value, start: bool) -> Result<Value> {
    use std::{
        io::{BufRead, Write},
        os::unix::net::UnixStream as Stream,
        process::{Command, Stdio},
    };
    let socket = store.directory("run")?.join("daemon.sock");
    if start && Stream::connect(&socket).is_err() {
        let mut child = Command::new(std::env::current_exe()?.canonicalize()?)
            .arg("daemon")
            .env_clear()
            .env("BUTAKE_STACK_HOME", store.root())
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()?;
        let deadline = std::time::Instant::now() + Duration::from_secs(5);
        while Stream::connect(&socket).is_err() {
            ensure!(
                child.try_wait()?.is_none() && std::time::Instant::now() < deadline,
                "daemon_start_failed"
            );
            std::thread::sleep(Duration::from_millis(50));
        }
    }
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
    let response: Value = serde_json::from_slice(&data)?;
    ensure!(response["ok"] == true, "daemon_request_failed");
    Ok(response["value"].clone())
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

fn real_home() -> String {
    dirs::home_dir()
        .map(|h| h.to_string_lossy().into_owned())
        .unwrap_or_else(|| "/tmp".into())
}

pub fn specs(store: &Store, fds: WebFds) -> Result<Vec<ProcessSpec>> {
    let config = store.config()?;
    // Only sites the user turned on are served and run their processes.
    let projects: Vec<_> = store.list()?.into_iter().filter(|p| p.enabled).collect();
    let mut specs = vec![];
    let home = real_home();
    // Stack services first so sites have php-fpm and Caddy before their own processes.
    for series in crate::services::series_in_use(&projects, &config) {
        if crate::runtimes::manifest(store, &series).is_err() {
            continue;
        }
        let (conf, ini) = crate::services::fpm_config(store, &series)?;
        let php = store.root().join("runtimes/php").join(&series);
        specs.push(ProcessSpec {
            id: format!("stack.php-{}", series.replace('.', "-")),
            executable: php.join("bin/php-fpm"),
            args: vec![
                "-F".into(),
                "-y".into(),
                conf.to_string_lossy().into_owned(),
                "-c".into(),
                ini.to_string_lossy().into_owned(),
            ],
            cwd: store.root().into(),
            autostart: true,
            restart_on_exit: true,
            environment: [("HOME".into(), home.clone())].into(),
            inherit: vec![],
            stop_timeout: 10,
        });
    }
    // Engines first (databases, cache, search, storage), in catalog order.
    for recipe in crate::engines::RECIPES {
        let Some(base) = crate::services::engine_dir(store, &config, recipe.id) else {
            continue;
        };
        let launch = crate::engines::launch(store, &config, recipe.id, &base)?;
        let mut environment = launch.environment;
        environment.insert("HOME".into(), home.clone());
        specs.push(ProcessSpec {
            id: format!("stack.{}", recipe.id),
            executable: launch.executable,
            args: launch.args,
            cwd: store.root().into(),
            autostart: true,
            restart_on_exit: true,
            environment,
            inherit: vec![],
            stop_timeout: recipe.stop_timeout,
        });
    }
    if let (Some(caddy), Some(http)) = (crate::services::caddy_executable(store, &config), fds.http) {
        let file = store.directory("config")?.join("Caddyfile");
        let content = crate::services::caddyfile(store, &store.list()?, &config, fds.https_udp.is_some())?;
        crate::services::write_private(&file, &content)?;
        // Caddy runs without its admin API, so it never rereads the file: a fingerprint of the
        // content in its environment makes the supervisor restart it whenever sites change.
        let fingerprint = {
            use sha2::{Digest, Sha256};
            Sha256::digest(content.as_bytes()).iter().take(8).map(|b| format!("{b:02x}")).collect::<String>()
        };
        let mut inherit = vec![http];
        // Caddy only needs the HTTPS socket when a site asks for HTTPS.
        if store.list()?.iter().any(|p| p.https) {
            if let Some(https) = fds.https {
                inherit.push(https);
                // HTTP/3 (QUIC) needs the UDP side of 443 as a third descriptor.
                if let Some(quic) = fds.https_udp {
                    inherit.push(quic);
                }
            }
        }
        specs.push(ProcessSpec {
            id: "stack.caddy".into(),
            executable: caddy,
            args: vec![
                "run".into(),
                "--config".into(),
                file.to_string_lossy().into_owned(),
                "--adapter".into(),
                "caddyfile".into(),
            ],
            cwd: store.root().into(),
            autostart: true,
            restart_on_exit: true,
            environment: [("HOME".into(), home.clone()), ("BUTAKE_CONFIG".into(), fingerprint)].into(),
            inherit,
            stop_timeout: 10,
        });
    }
    for project in projects {
        // With Production active, nothing of the site starts on its own (queues, scheduler…).
        let held = crate::envs::production_active(store, &project.id);
        let php_series = project
            .runtime
            .get("php")
            .or_else(|| config.versions.get("php"))
            .cloned()
            .unwrap_or_else(|| "8.2".into());
        let php_bin = store.root().join("runtimes/php").join(&php_series).join("bin");
        let node_wanted = project
            .runtime
            .get("node")
            .or_else(|| config.versions.get("node"))
            .cloned()
            .unwrap_or_default();
        let node_bin = crate::tools::resolve(store, "node", &node_wanted).map(|d| d.join("bin"));
        // JDK for Kotlin projects: JAVA_HOME and its bin first on PATH.
        let java_home = (project.kind == crate::model::ProjectKind::Kmp || project.runtime.contains_key("jdk"))
            .then(|| crate::tools::resolve(store, "jdk", project.runtime.get("jdk").map(String::as_str).unwrap_or(""))
                .or_else(|| crate::tools::resolve(store, "jdk", "")))
            .flatten()
            .map(|root| root.join("Contents/Home"));
        let mut path = vec![php_bin.to_string_lossy().into_owned()];
        if let Some(java) = &java_home {
            path.insert(0, java.join("bin").to_string_lossy().into_owned());
        }
        if let Some(node) = &node_bin {
            path.push(node.to_string_lossy().into_owned());
        }
        path.push("/usr/bin:/bin".into());
        // `{port}` and `{domain}` in arguments and environment.
        let port = project.upstream.map(|p| p.to_string()).unwrap_or_default();
        let domain = project.domains.first().cloned().unwrap_or_default();
        let fill = |text: &str| text.replace("{port}", &port).replace("{domain}", &domain);
        for process in project.processes {
            let (executable, mut args) = match process.program.as_str() {
                "php" => (Some(php_bin.join("php")), vec![]),
                "composer" => (
                    Some(php_bin.join("php")),
                    vec![store
                        .root()
                        .join("runtimes/php")
                        .join(&php_series)
                        .join("composer.phar")
                        .to_string_lossy()
                        .into_owned()],
                ),
                "gradlew" => (Some(project.path.join("gradlew")), vec![]),
                program => (node_bin.as_ref().map(|b| b.join(program)), vec![]),
            };
            let available = executable.as_ref().is_some_and(|e| e.exists());
            args.extend(process.args.iter().map(|a| fill(a)));
            specs.push(ProcessSpec {
                id: format!("{}.{}", project.id, process.name),
                executable: executable.unwrap_or_else(|| PathBuf::from("/nonexistent")),
                args,
                cwd: project.path.clone(),
                // A missing runtime never blocks the rest of the stack; the UI shows it stopped.
                autostart: process.autostart && available && !held,
                restart_on_exit: true,
                environment: {
                    let mut environment: std::collections::BTreeMap<String, String> = project.env.iter().map(|(k, v)| (k.clone(), fill(v))).collect();
                    environment.insert("HOME".into(), home.clone());
                    environment.insert("PATH".into(), path.join(":"));
                    // The binary's built-in php.ini path is the build machine's; point it at ours.
                    environment.insert("PHPRC".into(), store.root().join("config/php").join(&php_series).to_string_lossy().into_owned());
                    if let Some(java) = &java_home {
                        environment.insert("JAVA_HOME".into(), java.to_string_lossy().into_owned());
                    }
                    environment.into_iter().collect()
                },
                inherit: vec![],
                stop_timeout: 10,
            });
        }
    }
    Ok(specs)
}

pub async fn run() -> Result<()> {
    let store = Store::from_environment()?;
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
    let mut listeners = crate::listeners::Listeners::open(&store.config()?);
    let _ = WEB_FDS.set(listeners.fds());
    let _ = LISTENER_STATUS.set(listeners.status.clone());
    if let Some(socket) = listeners.take_dns_udp() {
        let tlds = Arc::new(store.config()?.tld);
        tokio::spawn(crate::dns::serve_udp(socket, tlds));
    }
    if let Some(listener) = listeners.take_dns_tcp() {
        let tlds = Arc::new(store.config()?.tld);
        tokio::spawn(crate::dns::serve_tcp(listener, tlds));
    }
    let mut supervisor = Supervisor::new(store.directory("logs")?);
    supervisor.reload(specs(&store, listeners.fds())?).await?;
    let supervisor = Arc::new(Mutex::new(supervisor));
    let (shutdown, mut stopped) = watch::channel(false);
    let mut term = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())?;
    let mut interrupt = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::interrupt())?;
    loop {
        tokio::select! { biased;
            _ = term.recv() => break,
            _ = interrupt.recv() => break,
            _ = stopped.changed() => break,
            connection = listener.accept() => {
                let (stream, _) = connection?;
                if !same_user(&stream)? { continue; }
                let supervisor = supervisor.clone(); let shutdown = shutdown.clone();
                tokio::spawn(async move { let _ = serve(stream, supervisor, shutdown).await; });
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
            unsafe { libc::getpeereid(stream.as_raw_fd(), &mut uid, &mut gid) } == 0,
            "peer_unavailable"
        );
        Ok(uid == unsafe { libc::geteuid() })
    }
    #[cfg(not(target_os = "macos"))]
    {
        Ok(stream.peer_cred()?.uid() == unsafe { libc::geteuid() })
    }
}

pub fn failure(id: Value, code: &str, key: &str) -> Value {
    json!({"id":id,"ok":false,"error":{"code":code,"messageKey":key}})
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
    shutdown: watch::Sender<bool>,
) -> Result<()> {
    let (read, mut writer) = stream.into_split();
    let mut reader = BufReader::new(read);
    while let Some(request) = frame(&mut reader).await? {
        let id = request.get("id").cloned().unwrap_or(Value::Null);
        if request["method"] == "subscribe" {
            let mut events = supervisor.lock().await.events.subscribe();
            let mut stopped = shutdown.subscribe();
            write(&mut writer, &json!({"id":id,"ok":true,"value":true})).await?;
            loop {
                tokio::select! {
                    _ = stopped.changed() => return Ok(()),
                    event = events.recv() => match event {
                        Ok(value) => write(&mut writer, &value).await?,
                        Err(tokio::sync::broadcast::error::RecvError::Lagged(count)) => write(&mut writer, &json!({"event":"stream.lagged","count":count})).await?,
                        Err(_) => return Ok(()),
                    }
                }
            }
        }
        let result = request_action(&request, &mut *supervisor.lock().await).await;
        let response = match result {
            Ok(value) => json!({"id":id,"ok":true,"value":value}),
            Err(_) => failure(id, "daemon_request_failed", "daemon.requestFailed"),
        };
        write(&mut writer, &response).await?;
        if request["method"] == "shutdown" && response["ok"] == true {
            let _ = shutdown.send(true);
            return Ok(());
        }
    }
    Ok(())
}
async fn request_action(request: &Value, supervisor: &mut Supervisor) -> Result<Value> {
    let key = request["params"]["id"].as_str().unwrap_or("");
    match request["method"].as_str().unwrap_or("") {
        "status" => Ok(json!(supervisor.status().await)),
        "stackStatus" => Ok(json!({
            "listeners": LISTENER_STATUS.get().cloned().unwrap_or_default(),
            "processes": supervisor.status().await,
        })),
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
        "logs" => Ok(json!(supervisor.logs(
            key,
            request["params"]["tail"].as_u64().unwrap_or(200).min(2000) as usize
        )?)),
        "reload" => {
            supervisor
                .reload(specs(&Store::from_environment()?, *WEB_FDS.get().unwrap_or(&WebFds::default()))?)
                .await?;
            Ok(json!(true))
        }
        "shutdown" => Ok(json!(true)),
        _ => anyhow::bail!("unknown_method"),
    }
}
