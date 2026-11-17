use crate::core::store::Store;
use crate::core::time::now_secs;
use crate::{
    core::model::validate_id,
    daemon::logs::{self, Logs, LOG_LIMIT},
};
use anyhow::{ensure, Result};
use serde::Serialize;
use serde_json::{json, Value};
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::os::unix::process::CommandExt;
use std::{
    collections::{BTreeMap, VecDeque},
    path::{Path, PathBuf},
    process::Stdio,
    sync::{Arc, Mutex as StdMutex},
    time::{Duration, Instant},
};
use tokio::{
    process::{Child, Command},
    sync::{broadcast, watch, Mutex},
    task::JoinHandle,
};

#[derive(Clone, PartialEq, Eq)]
pub struct ProcessSpec {
    pub id: String,
    pub executable: PathBuf,
    pub args: Vec<String>,
    pub cwd: PathBuf,
    pub autostart: bool,
    pub restart_on_exit: bool,
    pub environment: BTreeMap<String, String>,
    /// Descriptors handed to the child as 3, 4, … (sockets from launchd for Caddy).
    pub inherit: Vec<i32>,
    /// Seconds to wait after SIGTERM before SIGKILL (databases need time to flush).
    pub stop_timeout: u64,
    /// A site's active environment (the `.env` Stack wrote), read at every start, under
    /// `environment`: its values never sit in the spec, so changing environments restarts nothing
    /// until the user chooses to.
    pub env_file: Option<PathBuf>,
    /// Why the process cannot start (`unknown_port_project`…): it does not start on its own and
    /// starting it by hand fails with this code.
    pub blocked: Option<String>,
}

#[derive(Clone, Serialize)]
pub struct ProcessState {
    pub id: String,
    pub state: String,
    pub pid: Option<u32>,
    pub restarts: u32,
    pub started: Option<u64>,
}
struct Entry {
    spec: ProcessSpec,
    state: Arc<Mutex<ProcessState>>,
    logs: Arc<StdMutex<Logs>>,
    stop: Option<watch::Sender<bool>>,
    task: Option<JoinHandle<()>>,
}
#[derive(Clone, Serialize)]
struct ProcessSummary {
    id: String,
    executable: PathBuf,
    args: Vec<String>,
    autostart: bool,
}

struct ObservedProcess {
    spec: ProcessSummary,
    state: Arc<Mutex<ProcessState>>,
    logs: Arc<StdMutex<Logs>>,
}

type ProcessIndex = Arc<BTreeMap<String, ObservedProcess>>;

#[derive(Clone)]
pub struct SupervisorReader {
    entries: watch::Receiver<ProcessIndex>,
    pub events: broadcast::Sender<Value>,
}

impl SupervisorReader {
    pub async fn status(&self) -> Vec<Value> {
        let entries = Arc::clone(&self.entries.borrow());
        let mut states = Vec::with_capacity(entries.len());
        for entry in entries.values() {
            let state = entry.state.lock().await.clone();
            states.push(json!({"spec": entry.spec, "status": state}));
        }
        states
    }

    pub fn logs(&self, id: &str, tail: usize) -> Result<Vec<String>> {
        validate_process_id(id)?;
        let entries = Arc::clone(&self.entries.borrow());
        let entry = entries
            .get(id)
            .ok_or_else(|| anyhow::anyhow!("unknown_process"))?;
        let logs = entry.logs.lock().map_err(|_| anyhow::anyhow!("log_lock"))?;
        Ok(logs.tail(tail))
    }
}

pub struct Supervisor {
    entries: BTreeMap<String, Entry>,
    order: Vec<String>,
    log_dir: PathBuf,
    observed: watch::Sender<ProcessIndex>,
    pub events: broadcast::Sender<Value>,
}
pub fn validate_process_id(id: &str) -> Result<()> {
    let parts: Vec<_> = id.split('.').collect();
    ensure!(parts.len() == 2, "invalid_process_id");
    for part in parts {
        validate_id(part)?;
    }
    Ok(())
}

impl Supervisor {
    pub fn new(log_dir: PathBuf) -> Self {
        Self {
            entries: BTreeMap::new(),
            order: vec![],
            log_dir,
            observed: watch::channel(Arc::default()).0,
            events: broadcast::channel(4096).0,
        }
    }
    pub fn reader(&self) -> SupervisorReader {
        SupervisorReader {
            entries: self.observed.subscribe(),
            events: self.events.clone(),
        }
    }

    pub async fn reload(&mut self, specs: Vec<ProcessSpec>) -> Result<()> {
        let spec_order: Vec<String> = specs.iter().map(|s| s.id.clone()).collect();
        let mut ids = std::collections::HashSet::new();
        for spec in &specs {
            validate_process_id(&spec.id)?;
            ensure!(ids.insert(&spec.id), "duplicate_process");
            if spec.autostart {
                ensure!(
                    spec.executable
                        .canonicalize()
                        .is_ok_and(|path| path.is_file()),
                    "invalid_executable"
                );
                ensure!(
                    spec.cwd.canonicalize().is_ok_and(|path| path.is_dir()),
                    "invalid_path"
                );
            }
        }
        // Keep unchanged processes running; stop only what changed or disappeared, in reverse
        // start order, so editing one site never restarts the others.
        let mut keep = std::collections::HashSet::new();
        for spec in &specs {
            if let Some(entry) = self.entries.get(&spec.id) {
                if entry.spec == *spec {
                    keep.insert(spec.id.clone());
                }
            }
        }
        let interrupted: Vec<String> = specs
            .iter()
            .filter(|spec| !keep.contains(&spec.id))
            .filter(|spec| {
                self.entries
                    .get(&spec.id)
                    .is_some_and(|e| e.task.as_ref().is_some_and(|task| !task.is_finished()))
            })
            .map(|spec| spec.id.clone())
            .collect();
        // Prepare new entries first so a log-open error leaves running processes untouched.
        let mut entries = BTreeMap::new();
        for spec in specs.into_iter().filter(|spec| !keep.contains(&spec.id)) {
            let state = Arc::new(Mutex::new(ProcessState {
                id: spec.id.clone(),
                state: "stopped".into(),
                pid: None,
                restarts: 0,
                started: None,
            }));
            let logs = Arc::new(StdMutex::new(Logs::new(
                self.log_dir.join(format!("{}.log", spec.id)),
                LOG_LIMIT,
            )?));
            entries.insert(
                spec.id.clone(),
                Entry {
                    spec,
                    state,
                    logs,
                    stop: None,
                    task: None,
                },
            );
        }
        for id in self.order.clone().into_iter().rev() {
            if !keep.contains(&id) {
                let _ = self.stop(&id).await;
            }
        }
        self.order.retain(|id| keep.contains(id));
        entries.extend(
            std::mem::take(&mut self.entries)
                .into_iter()
                .filter(|(id, _)| keep.contains(id)),
        );
        self.entries = entries;
        self.observed.send_replace(Arc::new(
            self.entries
                .iter()
                .map(|(id, entry)| {
                    let spec = &entry.spec;
                    (
                        id.clone(),
                        ObservedProcess {
                            spec: ProcessSummary {
                                id: spec.id.clone(),
                                executable: spec.executable.clone(),
                                args: spec.args.clone(),
                                autostart: spec.autostart,
                            },
                            state: entry.state.clone(),
                            logs: entry.logs.clone(),
                        },
                    )
                })
                .collect(),
        ));
        // Specs arrive in dependency order (engines, php-fpm, Caddy, then sites).
        let autostart: Vec<_> = spec_order
            .into_iter()
            .filter(|id| !keep.contains(id))
            .filter(|id| {
                self.entries
                    .get(id)
                    .is_some_and(|e| e.spec.autostart && e.spec.blocked.is_none())
            })
            .collect();
        // One process that cannot start must not keep the others from starting.
        for id in &autostart {
            if let Err(error) = self.start(id).await {
                let reason = error.to_string();
                let entry = self.entries.get(id);
                if let Some(entry) = entry {
                    note(
                        &entry.logs,
                        &self.events,
                        id,
                        &format!("Stack: no se pudo iniciar ({reason})"),
                    );
                    transition(&entry.state, &self.events, "crashed", None).await;
                }
            }
        }
        // A running process whose spec changed (its `env`, arguments or the port of a project it
        // names) was stopped above: its log says why, and whether it started again.
        for id in &interrupted {
            let note = if autostart.contains(id) {
                "Stack: reiniciado porque cambió su configuración (variables, argumentos o el puerto de un proyecto referido)"
            } else {
                "Stack: detenido porque cambió su configuración; inícialo de nuevo"
            };
            if let Some(entry) = self.entries.get(id) {
                self::note(&entry.logs, &self.events, id, note);
            }
        }
        Ok(())
    }
    pub async fn start(&mut self, id: &str) -> Result<()> {
        validate_process_id(id)?;
        let entry = self
            .entries
            .get_mut(id)
            .ok_or_else(|| anyhow::anyhow!("unknown_process"))?;
        if entry.task.as_ref().is_some_and(|task| !task.is_finished()) {
            return Ok(());
        }
        if let Some(code) = &entry.spec.blocked {
            anyhow::bail!("{code}");
        }
        // The folder is resolved, not the program: `.venv/bin/python` is a link and Python finds its
        // virtual environment from the path it was started with.
        let executable = match (
            entry.spec.executable.parent(),
            entry.spec.executable.file_name(),
        ) {
            (Some(dir), Some(name)) => dir
                .canonicalize()
                .map_err(|_| anyhow::anyhow!("invalid_executable"))?
                .join(name),
            _ => anyhow::bail!("invalid_executable"),
        };
        ensure!(executable.is_file(), "invalid_executable");
        let cwd = entry
            .spec
            .cwd
            .canonicalize()
            .map_err(|_| anyhow::anyhow!("invalid_path"))?;
        ensure!(cwd.is_dir(), "invalid_path");
        let mut spec = entry.spec.clone();
        spec.executable = executable;
        spec.cwd = cwd;
        let (tx, rx) = watch::channel(false);
        entry.stop = Some(tx);
        let state = entry.state.clone();
        let logs = entry.logs.clone();
        let events = self.events.clone();
        entry.task = Some(tokio::spawn(async move {
            supervise(spec, state, logs, events, rx).await;
        }));
        self.order.retain(|key| key != id);
        self.order.push(id.into());
        Ok(())
    }
    pub async fn stop(&mut self, id: &str) -> Result<()> {
        validate_process_id(id)?;
        let entry = self
            .entries
            .get_mut(id)
            .ok_or_else(|| anyhow::anyhow!("unknown_process"))?;
        if let Some(stop) = entry.stop.take() {
            let _ = stop.send(true);
        }
        if let Some(task) = entry.task.take() {
            task.await?;
        }
        transition(&entry.state, &self.events, "stopped", None).await;
        Ok(())
    }
    pub async fn restart(&mut self, id: &str) -> Result<()> {
        self.stop(id).await?;
        self.start(id).await
    }
    pub async fn shutdown(&mut self) {
        for id in self.order.clone().into_iter().rev() {
            let _ = self.stop(&id).await;
        }
        self.order.clear();
    }
}
/// Appends one Stack-authored line to a process log and publishes it.
fn note(logs: &Arc<StdMutex<Logs>>, events: &broadcast::Sender<Value>, id: &str, text: &str) {
    if let Ok(line) = logs
        .lock()
        .map_err(|_| ())
        .and_then(|mut l| l.append(text).map_err(|_| ()))
    {
        let _ = events.send(json!({"event":"log","id":id,"line":line}));
    }
}
/// Waits for a pipe reader, but not for descendants that kept the pipe open after the group died.
async fn drain(task: JoinHandle<Result<()>>) {
    let abort = task.abort_handle();
    if tokio::time::timeout(Duration::from_secs(2), task)
        .await
        .is_err()
    {
        abort.abort();
    }
}
async fn transition(
    state: &Arc<Mutex<ProcessState>>,
    events: &broadcast::Sender<Value>,
    next: &str,
    pid: Option<u32>,
) {
    let mut state = state.lock().await;
    state.state = next.into();
    state.pid = pid;
    if next == "running" {
        state.started = Some(now_secs());
    }
    let _ = events.send(json!({"event":"process.state","value":state.clone()}));
}
/// Where the daemon notes the processes it started (`run/pids/<id>`: pid and executable image).
/// If the daemon dies without stopping them (launchd's SIGKILL on restart or update), the next one
/// finds them here and stops them before starting its own, so no stale MySQL, Caddy or php-fpm
/// keeps a port or a datadir.
pub static PID_DIR: std::sync::OnceLock<PathBuf> = std::sync::OnceLock::new();

/// Pids above 1 only: `kill(0, …)` is our own group and `kill(-1, …)` everyone's, and a pid that
/// does not fit an `i32` would wrap into one of those.
fn valid_pid(pid: u32) -> Option<i32> {
    i32::try_from(pid).ok().filter(|pid| *pid > 1)
}
fn image(pid: u32) -> Option<String> {
    let pid = valid_pid(pid)?;
    let mut buffer = vec![0u8; 4096];
    // SAFETY: the pointer is to `buffer`, alive and writable for the length passed; `proc_pidpath`
    // writes at most that many bytes and keeps no pointer.
    let length =
        unsafe { libc::proc_pidpath(pid, buffer.as_mut_ptr().cast(), buffer.len() as u32) };
    (length > 0).then(|| String::from_utf8_lossy(&buffer[..length as usize]).into_owned())
}
fn alive(pid: u32) -> bool {
    // SAFETY: `kill` with signal 0 touches no memory and sends nothing; it only reports whether
    // the process exists. `valid_pid` rules out the values that mean a group or everyone.
    valid_pid(pid).is_some_and(|pid| unsafe { libc::kill(pid, 0) } == 0)
}
/// Whether `pid` leads its own process group (the supervisor starts every child that way).
fn leads_group(pid: u32) -> bool {
    // SAFETY: `getpgid` takes an integer and touches no memory.
    valid_pid(pid).is_some_and(|pid| unsafe { libc::getpgid(pid) } == pid)
}
fn record(id: &str, pid: u32) {
    if let (Some(dir), Some(image)) = (PID_DIR.get(), image(pid)) {
        let _ = std::fs::create_dir_all(dir);
        let started = crate::core::watch::started(pid as i32).unwrap_or(0);
        let _ = std::fs::write(dir.join(id), format!("{pid}\n{image}\n{started}\n"));
    }
}
fn forget(id: &str) {
    if let Some(dir) = PID_DIR.get() {
        let _ = std::fs::remove_file(dir.join(id));
    }
}
/// What a pid file says: pid, executable image and, since the start time was added, when it began
/// (`None` for a file an older daemon wrote).
struct Recorded {
    pid: u32,
    image: String,
    started: Option<u64>,
}
fn parse_record(text: &str) -> Option<Recorded> {
    let mut lines = text.lines();
    let pid = lines.next()?.parse().ok()?;
    let image = lines.next()?.to_string();
    let started = lines.next().and_then(|line| line.parse().ok());
    Some(Recorded {
        pid,
        image,
        started,
    })
}
/// The recorded process is still the one started back then: same image, same start time and the
/// leader of its group. Pids are reused after a restart of the Mac, so the pid alone proves nothing.
fn is_recorded(recorded: &Recorded) -> bool {
    alive(recorded.pid)
        && image(recorded.pid).as_deref() == Some(recorded.image.as_str())
        && leads_group(recorded.pid)
        && recorded.started.is_none_or(|started| {
            started == 0 || crate::core::watch::started(recorded.pid as i32) == Some(started)
        })
}
/// Stops what a previous daemon left running. A pid only counts if it still is the same process
/// (see [`is_recorded`]), so a recycled pid of an unrelated program is never touched.
pub async fn reap_orphans() {
    if let Some(dir) = PID_DIR.get() {
        reap_dir(dir).await;
    }
}
async fn reap_dir(dir: &Path) {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return;
    };
    let mut orphans = vec![];
    for entry in entries.flatten() {
        let text = std::fs::read_to_string(entry.path()).unwrap_or_default();
        if let Some(recorded) = parse_record(&text).filter(is_recorded) {
            kill_group(recorded.pid, libc::SIGTERM);
            orphans.push(recorded);
        }
        let _ = std::fs::remove_file(entry.path());
    }
    // Databases flush on SIGTERM; give them the same grace as a normal stop.
    let deadline = Instant::now() + Duration::from_secs(30);
    while orphans.iter().any(is_recorded) && Instant::now() < deadline {
        tokio::time::sleep(Duration::from_millis(200)).await;
    }
    // Only those still the same process: one that left meanwhile may have had its pid reused.
    for recorded in orphans.iter().filter(|recorded| is_recorded(recorded)) {
        kill_group(recorded.pid, libc::SIGKILL);
    }
}
fn kill_group(pid: u32, signal: i32) {
    let Some(pid) = valid_pid(pid) else { return };
    // SAFETY: `kill` takes two integers and touches no memory; `valid_pid` guarantees `-pid`
    // names one process group, never our own (0) or everyone's (-1).
    unsafe {
        libc::kill(-pid, signal);
    }
}
/// Waits for a process group to empty, up to `grace`.
async fn wait_group(pid: u32, grace: Duration) {
    let deadline = Instant::now() + grace;
    while crate::core::watch::group_alive(pid as i32) && Instant::now() < deadline {
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
}
/// What is left of a group after its leader is gone: SIGTERM and up to `grace` to leave, then
/// SIGKILL. A wrapper (`npm run dev`) that exits first does not cost its children their grace.
async fn settle_group(pid: u32, grace: Duration) {
    if crate::core::watch::group_alive(pid as i32) {
        kill_group(pid, libc::SIGTERM);
        wait_group(pid, grace).await;
    }
    kill_group(pid, libc::SIGKILL);
}
async fn terminate(child: &mut Child, pid: u32, grace: u64) {
    let grace = Duration::from_secs(grace.max(1));
    kill_group(pid, libc::SIGTERM);
    let began = Instant::now();
    if tokio::time::timeout(grace, child.wait()).await.is_err() {
        kill_group(pid, libc::SIGKILL);
        let _ = child.wait().await;
    }
    // The group leader may exit while descendants still shut down (or ignore SIGTERM): they get
    // what is left of the grace period before the final SIGKILL.
    wait_group(pid, grace.saturating_sub(began.elapsed())).await;
    kill_group(pid, libc::SIGKILL);
}
/// Most descriptors a process can be handed (Caddy takes three).
const MAX_INHERIT: usize = 8;
/// Copies of `fds` at 100 and up, closed on exec, to be moved to 3, 4, 5… in the child. Moving
/// through copies keeps `dup2` from overwriting a descriptor that is still to be copied, and
/// leaves nothing open in the child above the ones it was given.
fn inherit_copies(fds: &[i32]) -> std::io::Result<Vec<OwnedFd>> {
    if fds.len() > MAX_INHERIT {
        return Err(std::io::ErrorKind::InvalidInput.into());
    }
    fds.iter()
        .map(|fd| {
            // SAFETY: `fcntl` with `F_DUPFD_CLOEXEC` takes integers and touches no memory.
            let copy = unsafe { libc::fcntl(*fd, libc::F_DUPFD_CLOEXEC, 100) };
            if copy < 0 {
                return Err(std::io::Error::last_os_error());
            }
            // SAFETY: `copy` is a new descriptor that nothing else owns.
            Ok(unsafe { OwnedFd::from_raw_fd(copy) })
        })
        .collect()
}
/// Window in which five crashes make the supervisor stop restarting a process.
const CRASH_WINDOW: Duration = Duration::from_secs(600);
async fn supervise(
    spec: ProcessSpec,
    state: Arc<Mutex<ProcessState>>,
    logs: Arc<StdMutex<Logs>>,
    events: broadcast::Sender<Value>,
    mut stop: watch::Receiver<bool>,
) {
    let mut crashes = VecDeque::new();
    let mut delay = 1;
    loop {
        if *stop.borrow() {
            break;
        }
        transition(&state, &events, "starting", None).await;
        let mut command = Command::new(&spec.executable);
        command
            .args(&spec.args)
            .current_dir(&spec.cwd)
            .env_clear()
            .env("HOME", Store::home().unwrap_or_else(|| spec.cwd.clone()))
            .env("LANG", "en_US.UTF-8")
            .env(
                "PATH",
                spec.executable
                    .parent()
                    .unwrap_or_else(|| Path::new("/usr/bin:/bin")),
            );
        // Precedence: the spec (the project's `env` with its markers, then Stack's own variables)
        // over the active environment, over the defaults above. Only a count reaches the log.
        if let Some(file) = &spec.env_file {
            let note = match crate::web::projects::envs::read_stack_dotenv(file) {
                Some(values) => {
                    let count = values.len();
                    command.envs(values);
                    format!("Stack: entorno activo con {count} variables")
                }
                None => "Stack: sin entorno activo de Stack en .env; no se pasa".to_string(),
            };
            self::note(&logs, &events, &spec.id, &note);
        }
        // The dynamic loader's variables never pass, whatever the project's `env` says.
        command
            .envs(
                spec.environment
                    .iter()
                    .filter(|(key, _)| !key.starts_with("DYLD_") && !key.starts_with("LD_")),
            )
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .kill_on_drop(true);
        command.as_std_mut().process_group(0);
        // Descriptors handed over (launchd's sockets) are duplicated here, before the fork, so the
        // child only calls `dup2` between fork and exec (no allocation, async-signal-safe).
        let copies = match inherit_copies(&spec.inherit) {
            Ok(copies) => Some(copies),
            Err(error) => {
                note(
                    &logs,
                    &events,
                    &spec.id,
                    &format!("Stack: no se pudo iniciar ({:?})", error.kind()),
                );
                None
            }
        };
        if let Some(copies) = copies.as_ref().filter(|copies| !copies.is_empty()) {
            let numbers: Vec<i32> = copies.iter().map(AsRawFd::as_raw_fd).collect();
            // SAFETY: the closure runs between fork and exec and only calls `dup2`, which is
            // async-signal-safe, on integers captured by value; it neither allocates nor locks.
            unsafe {
                command.as_std_mut().pre_exec(move || {
                    for (index, fd) in numbers.iter().enumerate() {
                        if libc::dup2(*fd, 3 + index as i32) < 0 {
                            return Err(std::io::Error::last_os_error());
                        }
                    }
                    Ok(())
                });
            }
        }
        // A child that did not start, or came without its pipes or its pid, counts as a failed start.
        let started = match copies.as_ref().map(|_| command.spawn()) {
            None => None,
            Some(Ok(mut child)) => (|| {
                let pid = child.id()?;
                let stdout = child.stdout.take()?;
                let stderr = child.stderr.take()?;
                Some((child, pid, stdout, stderr))
            })(),
            Some(Err(error)) => {
                note(
                    &logs,
                    &events,
                    &spec.id,
                    &format!("Stack: no se pudo iniciar ({:?})", error.kind()),
                );
                None
            }
        };
        // The child has its own copies now; ours (at 100 and up) are not needed.
        drop(copies);
        let mut lived = Duration::ZERO;
        if let Some((mut child, pid, stdout, stderr)) = started {
            let began = Instant::now();
            record(&spec.id, pid);
            transition(&state, &events, "running", Some(pid)).await;
            let out = tokio::spawn(logs::capture(
                stdout,
                spec.id.clone(),
                logs.clone(),
                events.clone(),
            ));
            let err = tokio::spawn(logs::capture(
                stderr,
                spec.id.clone(),
                logs.clone(),
                events.clone(),
            ));
            let (stopping, success) = tokio::select! { biased;
                _ = stop.changed() => (true, false),
                result = child.wait() => (false, result.is_ok_and(|status| status.success())),
            };
            if stopping {
                transition(&state, &events, "stopping", Some(pid)).await;
                terminate(&mut child, pid, spec.stop_timeout).await;
            } else {
                settle_group(pid, Duration::from_secs(spec.stop_timeout.max(1))).await;
            }
            forget(&spec.id);
            drain(out).await;
            drain(err).await;
            lived = began.elapsed();
            if stopping {
                break;
            }
            if !spec.restart_on_exit {
                transition(
                    &state,
                    &events,
                    if success { "stopped" } else { "crashed" },
                    None,
                )
                .await;
                return;
            }
        }
        if !spec.restart_on_exit {
            transition(&state, &events, "crashed", None).await;
            return;
        }
        let now = Instant::now();
        // A process that ran for a minute starts its backoff over.
        if lived > Duration::from_secs(60) {
            delay = 1;
        }
        crashes.push_back(now);
        while crashes
            .front()
            .is_some_and(|t| now.duration_since(*t) > CRASH_WINDOW)
        {
            crashes.pop_front();
        }
        transition(&state, &events, "crashed", None).await;
        if crashes.len() >= 5 {
            note(
                &logs,
                &events,
                &spec.id,
                "Stack: se dejó de reiniciar tras 5 caídas en 10 minutos",
            );
            return;
        }
        tokio::select! { biased;
            _ = stop.changed() => break,
            _ = tokio::time::sleep(Duration::from_secs(delay)) => {},
        }
        state.lock().await.restarts += 1;
        delay = (delay * 2).min(30);
    }
    transition(&state, &events, "stopped", None).await;
}

#[cfg(test)]
mod tests {
    use super::*;
    #[tokio::test]
    async fn one_shot_jobs_do_not_restart() {
        let temp = tempfile::tempdir().unwrap();
        let mut supervisor = Supervisor::new(temp.path().into());
        supervisor
            .reload(vec![ProcessSpec {
                id: "job.once".into(),
                executable: "/usr/bin/true".into(),
                args: vec![],
                cwd: temp.path().into(),
                autostart: true,
                restart_on_exit: false,
                environment: BTreeMap::new(),
                inherit: vec![],
                stop_timeout: 10,
                env_file: None,
                blocked: None,
            }])
            .await
            .unwrap();
        let entry = supervisor.entries.get("job.once").unwrap();
        let deadline = Instant::now() + Duration::from_secs(5);
        while !entry.task.as_ref().unwrap().is_finished() {
            assert!(Instant::now() < deadline);
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        let state = entry.state.lock().await.clone();
        assert_eq!(state.state, "stopped");
        assert_eq!(state.restarts, 0);
        supervisor.shutdown().await;
    }
    /// The active environment reaches the process under the spec's own variables, only when Stack
    /// wrote the file, and no value ever reaches the log. A blocked process never starts.
    #[tokio::test]
    async fn active_environment_reaches_the_process_without_logging_values() {
        let temp = tempfile::tempdir().unwrap();
        let mut supervisor = Supervisor::new(temp.path().into());
        let env_file = temp.path().join(".env");
        let sentinel = "centinela-7f3a9c-no-debe-aparecer";
        std::fs::write(
            &env_file,
            format!("# Entorno «Local» aplicado por Stack. Edítalo en la app.\nFROM_ENV={sentinel}\nBOTH=del-env\nREF=\"${{FROM_ENV}}-x\"\nDYLD_INSERT_LIBRARIES=/tmp/x.dylib\nLANG=es_CL.UTF-8\n"),
        )
        .unwrap();
        let out = temp.path().join("out.txt");
        let script = format!(
            "printf '%s|%s|%s|%s|%s' \"$FROM_ENV\" \"$BOTH\" \"$REF\" \
             \"${{DYLD_INSERT_LIBRARIES:-none}}\" \"$LANG\" > '{}'",
            out.display()
        );
        let job = |id: &str, file: Option<PathBuf>, blocked: Option<String>| ProcessSpec {
            id: id.into(),
            executable: "/bin/sh".into(),
            args: vec!["-c".into(), script.clone()],
            cwd: temp.path().into(),
            autostart: true,
            restart_on_exit: false,
            environment: [("BOTH".to_string(), "del-proyecto".to_string())].into(),
            inherit: vec![],
            stop_timeout: 2,
            env_file: file,
            blocked,
        };
        let wait = |supervisor: &Supervisor, id: &str| {
            supervisor
                .entries
                .get(id)
                .unwrap()
                .task
                .as_ref()
                .map(|t| t.is_finished())
        };
        supervisor
            .reload(vec![job("a.env", Some(env_file.clone()), None)])
            .await
            .unwrap();
        let deadline = Instant::now() + Duration::from_secs(5);
        while wait(&supervisor, "a.env") != Some(true) {
            assert!(Instant::now() < deadline);
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        assert_eq!(
            std::fs::read_to_string(&out).unwrap(),
            format!("{sentinel}|del-proyecto|{sentinel}-x|none|es_CL.UTF-8")
        );
        let log = std::fs::read_to_string(temp.path().join("a.env.log")).unwrap();
        assert!(
            log.contains("Stack: entorno activo con 4 variables"),
            "{log}"
        );
        assert!(!log.contains(sentinel) && !log.contains("del-env"));
        // A `.env` that Stack did not write is not passed.
        std::fs::write(&env_file, format!("FROM_ENV={sentinel}\n")).unwrap();
        supervisor.restart("a.env").await.unwrap();
        let deadline = Instant::now() + Duration::from_secs(5);
        while wait(&supervisor, "a.env") != Some(true) {
            assert!(Instant::now() < deadline);
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
        assert!(std::fs::read_to_string(&out)
            .unwrap()
            .starts_with("|del-proyecto|"));
        // Blocked: not started by reload, and a manual start says why.
        supervisor
            .reload(vec![job(
                "a.blocked",
                None,
                Some("unknown_port_project".into()),
            )])
            .await
            .unwrap();
        assert!(wait(&supervisor, "a.blocked").is_none());
        assert_eq!(
            supervisor.start("a.blocked").await.unwrap_err().to_string(),
            "unknown_port_project"
        );
        supervisor.shutdown().await;
    }
    #[tokio::test]
    async fn reload_keeps_unchanged_processes() {
        let temp = tempfile::tempdir().unwrap();
        let mut supervisor = Supervisor::new(temp.path().into());
        let spec = |id: &str, arg: &str| ProcessSpec {
            id: id.into(),
            executable: "/bin/sleep".into(),
            args: vec![arg.into()],
            cwd: temp.path().into(),
            autostart: true,
            restart_on_exit: true,
            environment: BTreeMap::new(),
            inherit: vec![],
            stop_timeout: 2,
            env_file: None,
            blocked: None,
        };
        supervisor
            .reload(vec![spec("a.one", "60"), spec("a.two", "60")])
            .await
            .unwrap();
        tokio::time::sleep(Duration::from_millis(300)).await;
        let pid = |s: &Supervisor, id: &str| {
            let state = s.entries.get(id).unwrap().state.clone();
            async move { state.lock().await.pid }
        };
        let one = pid(&supervisor, "a.one").await;
        let two = pid(&supervisor, "a.two").await;
        assert!(one.is_some() && two.is_some());
        supervisor
            .reload(vec![spec("a.one", "60"), spec("a.two", "61")])
            .await
            .unwrap();
        tokio::time::sleep(Duration::from_millis(300)).await;
        assert_eq!(
            pid(&supervisor, "a.one").await,
            one,
            "unchanged process keeps running"
        );
        assert_ne!(
            pid(&supervisor, "a.two").await,
            two,
            "changed process restarts"
        );
        // The restarted one says why in its log; the unchanged one says nothing.
        let log =
            |id: &str| std::fs::read_to_string(temp.path().join(format!("{id}.log"))).unwrap();
        assert!(log("a.two").contains("Stack: reiniciado porque cambió su configuración"));
        assert!(!log("a.one").contains("reiniciado"));
        supervisor.reload(vec![spec("a.one", "60")]).await.unwrap();
        assert!(!supervisor.entries.contains_key("a.two"));
        supervisor.shutdown().await;
    }

    fn job(script: &str, cwd: &Path, inherit: Vec<i32>) -> ProcessSpec {
        ProcessSpec {
            id: "job.fd".into(),
            executable: "/bin/sh".into(),
            args: vec!["-c".into(), script.into()],
            cwd: cwd.into(),
            autostart: true,
            restart_on_exit: false,
            environment: BTreeMap::new(),
            inherit,
            stop_timeout: 2,
            env_file: None,
            blocked: None,
        }
    }
    async fn run_to_end(supervisor: &mut Supervisor, spec: ProcessSpec) {
        supervisor.reload(vec![spec]).await.unwrap();
        let task = supervisor
            .entries
            .get("job.fd")
            .unwrap()
            .task
            .as_ref()
            .unwrap();
        let deadline = Instant::now() + Duration::from_secs(10);
        while !task.is_finished() {
            assert!(Instant::now() < deadline);
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    }
    /// A handed-over descriptor arrives as 3 (even when it already was 3 or 4 here), and the copies
    /// made to move it (100 and up) are not left open in the child.
    #[tokio::test]
    async fn inherited_descriptors_arrive_at_3_and_leave_no_copies() {
        let temp = tempfile::tempdir().unwrap();
        let (first, second) = (temp.path().join("one"), temp.path().join("two"));
        std::fs::write(&first, "uno").unwrap();
        std::fs::write(&second, "dos").unwrap();
        let (a, b) = (
            std::fs::File::open(&first).unwrap(),
            std::fs::File::open(&second).unwrap(),
        );
        let out = temp.path().join("out.txt");
        let script = format!(
            "cat <&3 > '{0}'; cat <&4 >> '{0}'; (: <&100) 2>/dev/null && echo copy-left >> '{0}'; (: <&101) 2>/dev/null && echo copy-left >> '{0}'",
            out.display()
        );
        let mut supervisor = Supervisor::new(temp.path().into());
        run_to_end(
            &mut supervisor,
            job(&script, temp.path(), vec![b.as_raw_fd(), a.as_raw_fd()]),
        )
        .await;
        assert_eq!(std::fs::read_to_string(out).unwrap(), "dosuno");
        supervisor.shutdown().await;
    }
    #[tokio::test]
    async fn too_many_descriptors_is_a_failed_start() {
        let temp = tempfile::tempdir().unwrap();
        let file = std::fs::File::open(temp.path()).unwrap();
        let fds = vec![file.as_raw_fd(); MAX_INHERIT + 1];
        let mut supervisor = Supervisor::new(temp.path().into());
        run_to_end(&mut supervisor, job("exit 0", temp.path(), fds)).await;
        let state = supervisor
            .entries
            .get("job.fd")
            .unwrap()
            .state
            .lock()
            .await
            .clone();
        assert_eq!(state.state, "crashed");
        supervisor.shutdown().await;
    }
    #[test]
    fn pid_files_parse_and_wrong_pids_never_match() {
        let old = parse_record("123\n/bin/sleep\n").unwrap();
        assert_eq!((old.pid, old.started), (123, None));
        let new = parse_record("123\n/bin/sleep\n456\n").unwrap();
        assert_eq!(new.started, Some(456));
        assert!(parse_record("x\n/bin/sleep\n").is_none());
        for pid in [0u32, 1, u32::MAX, i32::MAX as u32 + 1] {
            assert!(valid_pid(pid).is_none(), "{pid}");
            assert!(!alive(pid));
        }
        assert!(valid_pid(2).is_some());
    }
    /// Only the process that was recorded is stopped: same image, same start time, group leader.
    #[tokio::test]
    async fn orphans_are_reaped_only_when_it_is_the_same_process() {
        let temp = tempfile::tempdir().unwrap();
        let dir = temp.path().join("pids");
        std::fs::create_dir_all(&dir).unwrap();
        let spawn = || {
            let mut command = std::process::Command::new("/bin/sleep");
            command.arg("60").process_group(0);
            command.spawn().unwrap()
        };
        let (mut same, mut reused) = (spawn(), spawn());
        // Not a group leader: it shares the group of this test, so it is never ours to stop.
        let mut follower = std::process::Command::new("/bin/sleep");
        let mut follower = follower.arg("60").spawn().unwrap();
        let write = |name: &str, child: &std::process::Child, started: u64| {
            let image = image(child.id()).unwrap();
            std::fs::write(
                dir.join(name),
                format!("{}\n{image}\n{started}\n", child.id()),
            )
            .unwrap();
        };
        let real =
            |child: &std::process::Child| crate::core::watch::started(child.id() as i32).unwrap();
        write("same", &same, real(&same));
        // A pid reused by another process: same image, another start time.
        write("reused", &reused, real(&reused) + 1_000_000);
        write("follower", &follower, real(&follower));
        reap_dir(&dir).await;
        assert!(same.wait().is_ok_and(|status| !status.success()));
        assert!(reused.try_wait().unwrap().is_none());
        assert!(follower.try_wait().unwrap().is_none());
        assert_eq!(std::fs::read_dir(&dir).unwrap().count(), 0);
        let _ = reused.kill();
        let _ = follower.kill();
        let _ = reused.wait();
        let _ = follower.wait();
    }
    /// A wrapper that exits at once does not take the grace of its children with it.
    #[tokio::test]
    async fn children_of_a_wrapper_that_left_get_their_grace() {
        let temp = tempfile::tempdir().unwrap();
        let done = temp.path().join("done");
        let script = format!(
            "(trap 'sleep 1; echo graceful > {}; exit 0' TERM; while :; do sleep 0.1; done) & exit 0",
            done.display()
        );
        let mut command = tokio::process::Command::new("/bin/sh");
        command.args(["-c", &script]).process_group(0);
        let mut child = command.spawn().unwrap();
        let pid = child.id().unwrap();
        child.wait().await.unwrap();
        settle_group(pid, Duration::from_secs(10)).await;
        assert_eq!(std::fs::read_to_string(&done).unwrap().trim(), "graceful");
        assert!(!crate::core::watch::group_alive(pid as i32));
    }
}
